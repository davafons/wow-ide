import AppKit

@MainActor
private final class CodexAppServerClient {
    enum State: Equatable {
        case stopped
        case connecting
        case ready
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onNotification: ((String, [String: Any]) -> Void)?
    var onServerRequest: ((Int, String, [String: Any]) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var responses: [Int: (Result<[String: Any], Error>) -> Void] = [:]

    private(set) var state: State = .stopped {
        didSet { onStateChange?(state) }
    }

    func start() {
        guard process == nil else { return }
        guard let executable = Self.codexExecutable() else {
            state = .failed("Codex CLI was not found in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin.")
            return
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = URL(fileURLWithPath: AppPreferences.agentWorkingDirectory)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        state = .connecting

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.onNotification?("client/stderr", ["text": text])
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.input = nil
                self.output = nil
                if self.state != .stopped {
                    self.state = .failed("Codex app-server exited with code \(process.terminationStatus).")
                }
            }
        }

        do {
            try process.run()
            request(
                method: "initialize",
                params: [
                    "clientInfo": ["name": "wow-ide", "title": "WoW IDE", "version": "0.1.0"],
                    "capabilities": ["experimentalApi": false]
                ]
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.notify(method: "initialized", params: [:])
                    self.state = .ready
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        } catch {
            self.process = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        state = .stopped
        output?.readabilityHandler = nil
        process?.terminate()
        process = nil
        input = nil
        output = nil
        responses.removeAll()
    }

    @discardableResult
    func request(
        method: String,
        params: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) -> Int {
        let id = nextID
        nextID += 1
        responses[id] = completion
        send(["id": id, "method": method, "params": params])
        return id
    }

    func notify(method: String, params: [String: Any]) {
        send(["method": method, "params": params])
    }

    func respond(id: Int, result: [String: Any]) {
        send(["id": id, "result": result])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do { try input?.write(contentsOf: data) }
        catch { state = .failed(error.localizedDescription) }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = Self.integerID(object["id"]), object["method"] == nil {
            guard let completion = responses.removeValue(forKey: id) else { return }
            if let result = object["result"] as? [String: Any] {
                completion(.success(result))
            } else {
                let errorObject = object["error"] as? [String: Any]
                let message = errorObject?["message"] as? String ?? "Codex returned an unknown error."
                completion(.failure(NSError(domain: "CodexAppServer", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: message])))
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        if let id = Self.integerID(object["id"]) {
            onServerRequest?(id, method, params)
        } else {
            onNotification?(method, params)
        }
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func codexExecutable() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
}

@MainActor
final class CodexPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let targetProvider: @MainActor () -> NSRunningApplication?
    private let onClose: @MainActor () -> Void
    private let client = CodexAppServerClient()
    private var panel: ProbePanel?
    private var minimizedLauncher: ProbePanel?
    private weak var panelMaterial: NSVisualEffectView?
    private weak var transcript: NSTextView?
    private weak var promptField: ProbeTextField?
    private weak var statusLabel: NSTextField?
    private weak var sendButton: NSButton?
    private weak var stopButton: NSButton?
    private weak var approveButton: NSButton?
    private weak var denyButton: NSButton?
    private weak var approvalLabel: NSTextField?
    private weak var threadPicker: NSPopUpButton?
    private var threadIDs: [String] = []
    private var threadID: String?
    private var turnID: String?
    private var pendingPrompt: String?
    private var pendingApproval: (id: Int, method: String)?
    private var mode: PanelMode = .nonactivating
    private var isMinimized = false
    private var lastTargetFrame: NSRect?
    private let frameKey = "codexPanelFrame"
    private let launcherOriginKey = "codexLauncherOrigin"
    private let anchor = TargetWindowAnchor(defaultsKey: "codexTargetOffset")
    private let launcherAnchor = TargetWindowAnchor(defaultsKey: "codexLauncherTargetOffset")

    var isVisible: Bool { panel?.isVisible == true || minimizedLauncher?.isVisible == true }

    init(targetProvider: @escaping @MainActor () -> NSRunningApplication?,
         onClose: @escaping @MainActor () -> Void) {
        self.targetProvider = targetProvider
        self.onClose = onClose
        super.init()
        client.onStateChange = { [weak self] state in self?.clientStateChanged(state) }
        client.onNotification = { [weak self] method, params in self?.receive(method: method, params: params) }
        client.onServerRequest = { [weak self] id, method, params in
            self?.receiveRequest(id: id, method: method, params: params)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .wowIDEPreferencesChanged, object: nil
        )
    }

    func show(mode: PanelMode) {
        if panel == nil || self.mode != mode { createPanel(mode: mode) }
        if isMinimized { showLauncher() }
        else { panel?.orderFrontRegardless() }
        client.start()
    }

    func hide() {
        panel?.orderOut(nil)
        minimizedLauncher?.orderOut(nil)
    }

    func follow(targetFrame: NSRect) {
        lastTargetFrame = targetFrame
        guard let panel else { return }
        anchor.follow(targetFrame, window: panel) { frame, window in
            NSPoint(x: max(16, (frame.width - window.frame.width) / 2), y: 42)
        }
        if let launcher = minimizedLauncher {
            launcherAnchor.follow(targetFrame, window: launcher) { frame, _ in
                NSPoint(x: panel.frame.minX - frame.minX + 8, y: frame.maxY - panel.frame.maxY + 8)
            }
        }
    }

    func detachTarget() {
        lastTargetFrame = nil
        anchor.detach()
        launcherAnchor.detach()
    }

    func prepareExpanded() {
        isMinimized = false
        minimizedLauncher?.orderOut(nil)
    }

    func toggleMinimized() { isMinimized ? restore() : minimizePanel() }

    func resetLayout() {
        UserDefaults.standard.removeObject(forKey: frameKey)
        anchor.detach()
        panel?.setFrame(NSRect(x: 340, y: 180, width: 680, height: 620), display: true)
        saveFrame()
    }

    func shutdown() {
        client.stop()
        panel?.orderOut(nil)
        minimizedLauncher?.orderOut(nil)
    }

    private func createPanel(mode: PanelMode) {
        let previousFrame = panel?.frame
        panel?.orderOut(nil)
        panel = nil
        self.mode = mode

        let initial = NSRect(x: 340, y: 180, width: 680, height: 620)
        var mask: NSWindow.StyleMask = [.borderless, .utilityWindow]
        if mode == .nonactivating { mask.insert(.nonactivatingPanel) }
        let window = ProbePanel(contentRect: initial, styleMask: mask, backing: .buffered, defer: false)
        window.allowsMainWindow = mode == .activating
        window.becomesKeyOnlyIfNeeded = mode == .nonactivating
        window.title = "WoW IDE Codex"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 420)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.delegate = self

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: initial.size))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        applyPanelAppearance(to: content)
        panelMaterial = content

        let header = DragHeaderView()
        header.titleText = "WoW IDE  ·  Codex"
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onDragEnd = { [weak self] in self?.saveFrame() }
        let minimize = ProbeButton(title: "−", target: self, action: #selector(minimizePanel))
        let close = ProbeButton(title: "×", target: self, action: #selector(closePanel))
        for button in [minimize, close] { button.translatesAutoresizingMaskIntoConstraints = false }

        let newThread = ProbeButton(title: "New", target: self, action: #selector(newThreadAction))
        let refresh = ProbeButton(title: "↻", target: self, action: #selector(refreshThreads))
        let threads = NSPopUpButton()
        threads.addItem(withTitle: "Current thread")
        threads.target = self
        threads.action = #selector(selectThread)
        threads.setContentHuggingPriority(.defaultLow, for: .horizontal)
        threadPicker = threads
        let status = NSTextField(labelWithString: "Codex is stopped")
        status.textColor = .secondaryLabelColor
        statusLabel = status
        let toolbar = NSStackView(views: [newThread, refresh, threads, status])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textColor = .labelColor
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        transcript = text
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let approval = NSTextField(labelWithString: "")
        approval.lineBreakMode = .byTruncatingMiddle
        approvalLabel = approval
        let approve = ProbeButton(title: "Approve", target: self, action: #selector(approveRequest))
        let deny = ProbeButton(title: "Deny", target: self, action: #selector(denyRequest))
        approve.isHidden = true
        deny.isHidden = true
        approveButton = approve
        denyButton = deny
        let approvalBar = NSStackView(views: [approval, approve, deny])
        approvalBar.orientation = .horizontal
        approvalBar.spacing = 6
        approvalBar.translatesAutoresizingMaskIntoConstraints = false
        approval.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let prompt = ProbeTextField(string: "")
        prompt.placeholderString = "Ask Codex to work in \(AppPreferences.agentWorkingDirectory)"
        prompt.target = self
        prompt.action = #selector(sendPrompt)
        prompt.delegate = self
        prompt.setContentHuggingPriority(.defaultLow, for: .horizontal)
        promptField = prompt
        window.focusTextField = prompt
        let send = ProbeButton(title: "Send", target: self, action: #selector(sendPrompt))
        let stop = ProbeButton(title: "Stop", target: self, action: #selector(stopTurn))
        stop.isEnabled = false
        sendButton = send
        stopButton = stop
        let composer = NSStackView(views: [prompt, send, stop])
        composer.orientation = .horizontal
        composer.spacing = 6
        composer.translatesAutoresizingMaskIntoConstraints = false

        let grip = ResizeHandleView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.onResizeEnd = { [weak self] in self?.saveFrame() }
        for item in [header, minimize, close, toolbar, scroll, approvalBar, composer, grip] {
            content.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: minimize.leadingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 30),
            minimize.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            minimize.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            toolbar.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: approvalBar.topAnchor, constant: -6),
            approvalBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            approvalBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            approvalBar.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -6),
            approvalBar.heightAnchor.constraint(equalToConstant: 28),
            composer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            composer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            composer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            composer.heightAnchor.constraint(equalToConstant: 30),
            grip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            grip.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            grip.widthAnchor.constraint(equalToConstant: 20),
            grip.heightAnchor.constraint(equalToConstant: 20)
        ])
        window.contentView = content
        if let frame = previousFrame ?? savedFrame() { window.setFrame(frame, display: false) }
        panel = window
    }

    private func clientStateChanged(_ state: CodexAppServerClient.State) {
        switch state {
        case .stopped:
            statusLabel?.stringValue = "Stopped"
        case .connecting:
            statusLabel?.stringValue = "Connecting…"
        case .ready:
            statusLabel?.stringValue = "Ready"
            resumeSavedThreadOrCreate()
            refreshThreads()
        case .failed(let message):
            statusLabel?.stringValue = "Unavailable"
            append("\nCodex error: \(message)\n")
        }
        sendButton?.isEnabled = state == .ready
    }

    private func resumeSavedThreadOrCreate() {
        guard threadID == nil else { return }
        if let saved = UserDefaults.standard.string(forKey: AppPreferenceKey.codexThreadID) {
            resume(thread: saved, fallbackToNew: true)
        } else {
            createThread()
        }
    }

    private func createThread() {
        client.request(method: "thread/start", params: [
            "cwd": AppPreferences.agentWorkingDirectory,
            "approvalPolicy": "on-request"
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload): self.acceptThread(from: payload, message: "Started a new Codex thread.")
            case .failure(let error): self.append("\nCould not start thread: \(error.localizedDescription)\n")
            }
        }
    }

    private func resume(thread id: String, fallbackToNew: Bool = false) {
        client.request(method: "thread/resume", params: [
            "threadId": id,
            "cwd": AppPreferences.agentWorkingDirectory,
            "approvalPolicy": "on-request",
            "excludeTurns": true
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload): self.acceptThread(from: payload, message: "Resumed Codex thread \(id).")
            case .failure(let error):
                if fallbackToNew { self.createThread() }
                else { self.append("\nCould not resume thread: \(error.localizedDescription)\n") }
            }
        }
    }

    private func acceptThread(from payload: [String: Any], message: String) {
        guard let thread = payload["thread"] as? [String: Any], let id = thread["id"] as? String else { return }
        threadID = id
        UserDefaults.standard.set(id, forKey: AppPreferenceKey.codexThreadID)
        append("\n\(message)\n")
        if let pendingPrompt {
            self.pendingPrompt = nil
            startTurn(prompt: pendingPrompt)
        }
    }

    @objc private func sendPrompt() {
        let prompt = promptField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { return }
        promptField?.stringValue = ""
        append("\nYou:\n\(prompt)\n\nCodex:\n")
        guard threadID != nil else { pendingPrompt = prompt; createThread(); return }
        startTurn(prompt: prompt)
    }

    private func startTurn(prompt: String) {
        guard let threadID else { return }
        sendButton?.isEnabled = false
        stopButton?.isEnabled = true
        client.request(method: "turn/start", params: [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt]],
            "approvalPolicy": "on-request"
        ]) { [weak self] result in
            guard let self else { return }
            if case .success(let payload) = result,
               let turn = payload["turn"] as? [String: Any] {
                self.turnID = turn["id"] as? String
            } else if case .failure(let error) = result {
                self.append("\nCould not start turn: \(error.localizedDescription)\n")
                self.turnFinished()
            }
        }
    }

    private func receive(method: String, params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String { append(delta) }
        case "turn/started":
            if let turn = params["turn"] as? [String: Any] { turnID = turn["id"] as? String }
        case "turn/completed":
            append("\n")
            turnFinished()
            refreshThreads()
        case "error":
            let message = params["message"] as? String ?? "Unknown Codex error"
            append("\nError: \(message)\n")
        case "client/stderr":
            if let text = params["text"] as? String, text.lowercased().contains("error") {
                append("\n\(text)")
            }
        default:
            break
        }
    }

    private func receiveRequest(id: Int, method: String, params: [String: Any]) {
        if method == "item/tool/requestUserInput" {
            client.respond(id: id, result: ["answers": [:]])
            append("\nCodex asked for additional input. The request was left unanswered; send the answer as a new message.\n")
            return
        }
        guard method == "item/commandExecution/requestApproval"
                || method == "item/fileChange/requestApproval" else {
            client.respond(id: id, result: ["decision": "decline"])
            return
        }
        pendingApproval = (id, method)
        let reason = params["reason"] as? String
        let command = params["command"] as? String
        approvalLabel?.stringValue = reason ?? command ?? (method.contains("fileChange")
            ? "Codex requests permission to change files."
            : "Codex requests permission to run a command.")
        approveButton?.isHidden = false
        denyButton?.isHidden = false
        append("\nApproval requested: \(approvalLabel?.stringValue ?? "action")\n")
    }

    @objc private func approveRequest() { answerApproval("accept") }
    @objc private func denyRequest() { answerApproval("decline") }

    private func answerApproval(_ decision: String) {
        guard let approval = pendingApproval else { return }
        client.respond(id: approval.id, result: ["decision": decision])
        pendingApproval = nil
        approvalLabel?.stringValue = ""
        approveButton?.isHidden = true
        denyButton?.isHidden = true
    }

    @objc private func stopTurn() {
        guard let threadID, let turnID else { return }
        client.request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) { _ in }
    }

    private func turnFinished() {
        turnID = nil
        sendButton?.isEnabled = true
        stopButton?.isEnabled = false
    }

    @objc private func newThreadAction() {
        threadID = nil
        turnID = nil
        UserDefaults.standard.removeObject(forKey: AppPreferenceKey.codexThreadID)
        transcript?.string = ""
        createThread()
    }

    @objc private func refreshThreads() {
        guard client.state == .ready else { return }
        client.request(method: "thread/list", params: [
            "limit": 20,
            "cwd": AppPreferences.agentWorkingDirectory,
            "sortKey": "updated_at",
            "sortDirection": "desc"
        ]) { [weak self] result in
            guard let self, case .success(let payload) = result,
                  let threads = payload["data"] as? [[String: Any]] else { return }
            self.threadIDs = threads.compactMap { $0["id"] as? String }
            self.threadPicker?.removeAllItems()
            for thread in threads {
                let preview = (thread["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.threadPicker?.addItem(withTitle: preview?.isEmpty == false ? preview! : "Untitled thread")
            }
            if let current = self.threadID, let index = self.threadIDs.firstIndex(of: current) {
                self.threadPicker?.selectItem(at: index)
            }
        }
    }

    @objc private func selectThread() {
        let index = threadPicker?.indexOfSelectedItem ?? -1
        guard threadIDs.indices.contains(index) else { return }
        let selected = threadIDs[index]
        guard selected != threadID else { return }
        transcript?.string = ""
        resume(thread: selected)
    }

    private func append(_ string: String) {
        guard let transcript else { return }
        transcript.textStorage?.append(NSAttributedString(
            string: string,
            attributes: [.foregroundColor: NSColor.labelColor,
                         .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]
        ))
        transcript.scrollToEndOfDocument(nil)
    }

    private func savedFrame() -> NSRect? {
        guard let value = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let rect = NSRectFromString(value)
        guard rect.width >= 520, rect.height >= 420,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else { return nil }
        return rect
    }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
        anchor.recordMove(of: panel)
    }

    @objc private func preferencesChanged() {
        panelMaterial.map(applyPanelAppearance)
        promptField?.placeholderString = "Ask Codex to work in \(AppPreferences.agentWorkingDirectory)"
    }

    @objc private func closePanel() { onClose() }

    @objc private func minimizePanel() {
        isMinimized = true
        panel?.orderOut(nil)
        showLauncher()
    }

    private func restore() {
        prepareExpanded()
        panel?.orderFrontRegardless()
    }

    private func showLauncher() {
        if minimizedLauncher == nil {
            let launcher = ProbePanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            launcher.allowsMainWindow = false
            launcher.title = "WoW IDE Codex Restore"
            launcher.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            launcher.collectionBehavior = [.fullScreenAuxiliary]
            launcher.hidesOnDeactivate = false
            launcher.isOpaque = false
            launcher.backgroundColor = .clear
            launcher.hasShadow = true
            let control = DraggableRestoreView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
            control.symbol = "C"
            control.toolTip = "Click to restore Codex; drag to move"
            control.onRestore = { [weak self] in self?.restore() }
            control.onDragEnd = { [weak self] in self?.saveLauncherOrigin() }
            launcher.contentView = control
            if let saved = UserDefaults.standard.string(forKey: launcherOriginKey) {
                launcher.setFrameOrigin(NSPointFromString(saved))
            } else if let panel {
                launcher.setFrameOrigin(NSPoint(x: panel.frame.minX + 8, y: panel.frame.maxY - 68))
            }
            minimizedLauncher = launcher
        }
        if let lastTargetFrame { follow(targetFrame: lastTargetFrame) }
        minimizedLauncher?.orderFrontRegardless()
    }

    private func saveLauncherOrigin() {
        guard let launcher = minimizedLauncher else { return }
        UserDefaults.standard.set(NSStringFromPoint(launcher.frame.origin), forKey: launcherOriginKey)
        launcherAnchor.recordMove(of: launcher)
    }

    func controlTextDidBeginEditing(_ notification: Notification) { panel?.allowsTextFocus = true }
    func controlTextDidEndEditing(_ notification: Notification) { panel?.allowsTextFocus = false }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
}
