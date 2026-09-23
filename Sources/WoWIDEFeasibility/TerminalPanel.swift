import AppKit
import SwiftUI
import Termini

@MainActor
final class TerminalPanelController: NSObject, NSWindowDelegate {
    @MainActor
    private final class TerminalSession {
        let name: String
        let workspace: TerminiLocalPTYWorkspace
        let host: NSHostingView<TerminiTerminalView>

        init(name: String, workspace: TerminiLocalPTYWorkspace, appearance: TerminiTerminalAppearance) {
            self.name = name
            self.workspace = workspace
            self.host = NSHostingView(rootView: TerminiTerminalView(
                controller: workspace.controller,
                appearance: appearance
            ))
        }
    }

    private let targetProvider: @MainActor () -> NSRunningApplication?
    private let onClose: @MainActor () -> Void
    private var panel: ProbePanel?
    private var minimizedLauncher: ProbePanel?
    private weak var panelMaterial: NSVisualEffectView?
    private weak var terminalContainer: NSView?
    private weak var sessionPicker: NSPopUpButton?
    private var sessions: [TerminalSession] = []
    private var activeSessionIndex = 0
    private var mode: PanelMode = .nonactivating
    private var keyboardReturnProcessID: pid_t?
    private var terminalHasKeyboard = false
    private var outsideMouseMonitor: Any?
    private let frameKey = "terminalPanelFrame"
    private let launcherOriginKey = "terminalLauncherOrigin"
    private let anchor = TargetWindowAnchor(defaultsKey: "terminalTargetOffset")
    private let launcherAnchor = TargetWindowAnchor(defaultsKey: "terminalLauncherTargetOffset")
    private var lastTargetFrame: NSRect?

    private var activeSession: TerminalSession? {
        sessions.indices.contains(activeSessionIndex) ? sessions[activeSessionIndex] : nil
    }
    private var hostedTerminal: NSHostingView<TerminiTerminalView>? { activeSession?.host }
    private var workspace: TerminiLocalPTYWorkspace? { activeSession?.workspace }

    var isVisible: Bool { panel?.isVisible == true || minimizedLauncher?.isVisible == true }
    var frame: NSRect? { panel?.frame }

    private var minimized = false

    init(targetProvider: @escaping @MainActor () -> NSRunningApplication?,
         onClose: @escaping @MainActor () -> Void) {
        self.targetProvider = targetProvider
        self.onClose = onClose
        super.init()
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.releaseForExternalClick() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .wowIDEPreferencesChanged, object: nil
        )
    }

    func show(mode: PanelMode) {
        if panel == nil || self.mode != mode { createPanel(mode: mode) }
        if minimized { showLauncher() }
        else if mode == .activating {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else { panel?.orderFrontRegardless() }
        if workspace?.isRunning == false { workspace?.start() }
    }

    func hide() {
        releaseKeyboard()
        panel?.orderOut(nil)
        minimizedLauncher?.orderOut(nil)
    }

    func setMode(_ mode: PanelMode) {
        guard panel != nil else { self.mode = mode; return }
        if self.mode != mode { createPanel(mode: mode) }
    }

    func follow(targetFrame: NSRect) {
        lastTargetFrame = targetFrame
        guard let panel else { return }
        anchor.follow(targetFrame, window: panel) { frame, window in
            NSPoint(x: 16, y: max(18, min(64, frame.height - window.frame.height)))
        }
        followLauncher(targetFrame)
    }

    func detachTarget() {
        lastTargetFrame = nil
        anchor.detach()
        launcherAnchor.detach()
    }

    private func savedFrame() -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let rect = NSRectFromString(text)
        guard rect.width >= 480, rect.height >= 300,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else { return nil }
        return rect
    }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
        anchor.recordMove(of: panel)
    }

    private static let transparentGhosttyConfigPath: String? = {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let directory = applicationSupport.appendingPathComponent(
            "WoWIDEFeasibility",
            isDirectory: true
        )
        let configURL = directory.appendingPathComponent("transparent-terminal.conf")
        let config = "background-opacity = 0\n"

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? String(contentsOf: configURL, encoding: .utf8)) != config {
                try config.write(to: configURL, atomically: true, encoding: .utf8)
            }
            return configURL.path
        } catch {
            NSLog("Could not prepare the transparent Ghostty config: %@", error.localizedDescription)
            return nil
        }
    }()

    private static func ghosttyAppearance() -> TerminiTerminalAppearance {
        TerminiTerminalAppearance(
            theme: TerminiTerminalTheme(
            id: "wow-ide-ghostty-profile",
            name: "Ghostty Solarized Dark",
            colorScheme: .dark,
            background: .init(hex: 0x002B36),
            foreground: .init(hex: 0x839496),
            cursor: .init(hex: 0x839496),
            ansiPalette: [
                .init(hex: 0x073642), .init(hex: 0xDC322F), .init(hex: 0x859900), .init(hex: 0xB58900),
                .init(hex: 0x268BD2), .init(hex: 0xD33682), .init(hex: 0x2AA198), .init(hex: 0xEEE8D5),
                .init(hex: 0x586E75), .init(hex: 0xCB4B16), .init(hex: 0x586E75), .init(hex: 0x657B83),
                .init(hex: 0x839496), .init(hex: 0x6C71C4), .init(hex: 0x93A1A1), .init(hex: 0xFDF6E3)
            ]
            ),
            fontSize: AppPreferences.terminalFontSize,
            fontFamily: "SauceCodePro Nerd Font Mono",
            drawsBackground: false,
            extraConfigFilePaths: [transparentGhosttyConfigPath].compactMap { $0 }
        )
    }

    private func makeSession() -> TerminalSession {
        let spec = TerminiProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-l"],
            environment: ["TERM_PROGRAM": "ghostty", "TERM": "xterm-256color"],
            workingDirectoryURL: URL(fileURLWithPath: AppPreferences.terminalWorkingDirectory)
        )
        let workspace = TerminiLocalPTYWorkspace(processSpec: spec)
        return TerminalSession(
            name: "Shell \(sessions.count + 1)",
            workspace: workspace,
            appearance: Self.ghosttyAppearance()
        )
    }

    private func createPanel(mode: PanelMode) {
        let previousFrame = panel?.frame
        let wasVisible = isVisible
        releaseKeyboard()
        sessions.forEach { $0.host.removeFromSuperview() }
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        self.mode = mode

        let initial = NSRect(x: 260, y: 220, width: 760, height: 480)
        var mask: NSWindow.StyleMask = [.borderless, .utilityWindow]
        if mode == .nonactivating { mask.insert(.nonactivatingPanel) }
        let window = ProbePanel(contentRect: initial, styleMask: mask,
                                backing: .buffered, defer: false)
        window.allowsMainWindow = mode == .activating
        window.becomesKeyOnlyIfNeeded = mode == .nonactivating
        window.title = "WoW IDE Terminal"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 480, height: 300)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.delegate = self
        window.onNonTextMouseDown = { [weak self] event in self?.handleMouseDown(event) }

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
        header.titleText = "WoW IDE  ·  Ghostty Terminal"
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onDragEnd = { [weak self] in self?.saveFrame() }
        let minimize = ProbeButton(title: "−", target: self, action: #selector(minimizePanel))
        minimize.toolTip = "Minimize this terminal to a small restore button"
        let close = ProbeButton(title: "×", target: self, action: #selector(closePanel))
        for button in [minimize, close] { button.translatesAutoresizingMaskIntoConstraints = false }

        if sessions.isEmpty { sessions.append(makeSession()) }
        let picker = NSPopUpButton()
        picker.addItems(withTitles: sessions.map(\.name))
        picker.selectItem(at: activeSessionIndex)
        picker.target = self
        picker.action = #selector(selectSession)
        picker.translatesAutoresizingMaskIntoConstraints = false
        sessionPicker = picker
        let addSession = ProbeButton(title: "+", target: self, action: #selector(newSession))
        addSession.toolTip = "Open another shell"
        let restartSession = ProbeButton(title: "↻", target: self, action: #selector(restartSession))
        restartSession.toolTip = "Restart this shell in the configured directory"
        let closeSession = ProbeButton(title: "×", target: self, action: #selector(closeSession))
        closeSession.toolTip = "Close this shell"
        for button in [addSession, restartSession, closeSession] {
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        let sessionBar = NSStackView(views: [picker, addSession, restartSession, closeSession])
        sessionBar.orientation = .horizontal
        sessionBar.spacing = 6
        sessionBar.translatesAutoresizingMaskIntoConstraints = false
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let terminal = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.wantsLayer = true
        terminal.layer?.cornerRadius = 6
        terminal.layer?.masksToBounds = true
        terminalContainer = terminal
        installActiveTerminal()

        let grip = ResizeHandleView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.onResizeEnd = { [weak self] in self?.saveFrame() }
        for item in [header, minimize, close, sessionBar, terminal, grip] { content.addSubview(item) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: minimize.leadingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 30),
            minimize.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            minimize.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            minimize.widthAnchor.constraint(equalToConstant: 26),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 26),
            sessionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            sessionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            sessionBar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            sessionBar.heightAnchor.constraint(equalToConstant: 28),
            terminal.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            terminal.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            terminal.topAnchor.constraint(equalTo: sessionBar.bottomAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            grip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            grip.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            grip.widthAnchor.constraint(equalToConstant: 20),
            grip.heightAnchor.constraint(equalToConstant: 20)
        ])
        window.contentView = content
        if let frame = previousFrame ?? savedFrame() { window.setFrame(frame, display: false) }
        panel = window
        if wasVisible {
            if minimized { showLauncher() }
            else { window.orderFrontRegardless() }
        }
    }

    private func installActiveTerminal() {
        guard let terminalContainer, let host = hostedTerminal else { return }
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        host.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            host.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            host.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor)
        ])
        if !activeSession!.workspace.isRunning { activeSession!.workspace.start() }
    }

    private func rebuildSessionPicker() {
        sessionPicker?.removeAllItems()
        sessionPicker?.addItems(withTitles: sessions.map(\.name))
        sessionPicker?.selectItem(at: activeSessionIndex)
    }

    @objc private func selectSession() {
        releaseKeyboard()
        activeSessionIndex = max(0, sessionPicker?.indexOfSelectedItem ?? 0)
        installActiveTerminal()
    }

    @objc private func newSession() {
        releaseKeyboard()
        sessions.append(makeSession())
        activeSessionIndex = sessions.count - 1
        rebuildSessionPicker()
        installActiveTerminal()
    }

    @objc private func restartSession() {
        releaseKeyboard()
        guard let session = activeSession else { return }
        session.workspace.processSpec.workingDirectoryURL = URL(
            fileURLWithPath: AppPreferences.terminalWorkingDirectory
        )
        session.workspace.start()
    }

    @objc private func closeSession() {
        guard !sessions.isEmpty else { return }
        releaseKeyboard()
        let session = sessions.remove(at: activeSessionIndex)
        session.workspace.stop()
        session.host.removeFromSuperview()
        if sessions.isEmpty { sessions.append(makeSession()) }
        activeSessionIndex = min(activeSessionIndex, sessions.count - 1)
        rebuildSessionPicker()
        installActiveTerminal()
    }

    @objc private func preferencesChanged() {
        panelMaterial.map(applyPanelAppearance)
        let appearance = Self.ghosttyAppearance()
        for session in sessions {
            session.host.rootView = TerminiTerminalView(
                controller: session.workspace.controller,
                appearance: appearance
            )
        }
    }

    func resetLayout() {
        UserDefaults.standard.removeObject(forKey: frameKey)
        anchor.detach()
        panel?.setFrame(NSRect(x: 260, y: 220, width: 760, height: 480), display: true)
        saveFrame()
    }

    func shutdown() {
        releaseKeyboard()
        sessions.forEach { $0.workspace.stop() }
        panel?.orderOut(nil)
        minimizedLauncher?.orderOut(nil)
    }

    private func terminalSurface(in root: NSView) -> SurfaceContainerView? {
        if let surface = root as? SurfaceContainerView { return surface }
        for child in root.subviews {
            if let surface = terminalSurface(in: child) { return surface }
        }
        return nil
    }

    private func captureReturnTarget() {
        let target = targetProvider()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        keyboardReturnProcessID = frontmost == target?.processIdentifier ? frontmost : nil
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard mode == .nonactivating, let panel, let hostedTerminal else { return }
        if hostedTerminal.convert(hostedTerminal.bounds, to: nil).contains(event.locationInWindow) {
            if !terminalHasKeyboard { captureReturnTarget() }
            terminalHasKeyboard = true
            panel.allowsTextFocus = true
            panel.makeKey()
            if let surface = terminalSurface(in: hostedTerminal) {
                panel.makeFirstResponder(surface)
            }
        } else if terminalHasKeyboard {
            releaseKeyboard(keepReturnTarget: true)
            scheduleReturnToTarget()
        }
    }

    private func releaseKeyboard(keepReturnTarget: Bool = false) {
        terminalHasKeyboard = false
        panel?.allowsTextFocus = false
        if let panel, let hostedTerminal,
           let surface = terminalSurface(in: hostedTerminal), panel.firstResponder === surface {
            panel.makeFirstResponder(nil)
        }
        workspace?.controller.blur()
        if !keepReturnTarget { keyboardReturnProcessID = nil }
    }

    private func releaseForExternalClick() {
        guard mode == .nonactivating, let panel, panel.isVisible else { return }
        releaseKeyboard()
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private func scheduleReturnToTarget() {
        guard let pid = keyboardReturnProcessID else { return }
        DispatchQueue.main.async { [weak self] in self?.restoreTargetKeyboard(pid) }
    }

    private func restoreTargetKeyboard(_ pid: pid_t) {
        guard mode == .nonactivating, !terminalHasKeyboard,
              keyboardReturnProcessID == pid,
              let panel, let target = targetProvider(), target.processIdentifier == pid else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreTargetKeyboard(pid)
            }
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmost == pid || frontmost == NSRunningApplication.current.processIdentifier else { return }
        if panel.isKeyWindow {
            let visible = panel.isVisible
            panel.orderOut(nil)
            if visible { panel.orderFrontRegardless() }
        }
        if NSApp.isActive { NSApp.yieldActivation(to: target) }
        _ = target.activate(options: [])
        keyboardReturnProcessID = nil
    }

    private func followLauncher(_ targetFrame: NSRect) {
        guard let panel, let launcher = minimizedLauncher else { return }
        launcherAnchor.follow(targetFrame, window: launcher) { frame, _ in
            NSPoint(x: panel.frame.minX - frame.minX + 8,
                    y: frame.maxY - panel.frame.maxY + 8)
        }
    }

    private func saveLauncherOrigin() {
        guard let launcher = minimizedLauncher else { return }
        UserDefaults.standard.set(NSStringFromPoint(launcher.frame.origin), forKey: launcherOriginKey)
        launcherAnchor.recordMove(of: launcher)
    }

    private func showLauncher() {
        if minimizedLauncher == nil {
            let launcher = ProbePanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            launcher.allowsMainWindow = false
            launcher.title = "WoW IDE Terminal Restore"
            launcher.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            launcher.collectionBehavior = [.fullScreenAuxiliary]
            launcher.hidesOnDeactivate = false
            launcher.isOpaque = false
            launcher.backgroundColor = .clear
            launcher.hasShadow = true
            let control = DraggableRestoreView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
            control.symbol = ">_"
            control.toolTip = "Click to restore terminal; drag to move"
            control.onRestore = { [weak self] in self?.restorePanel() }
            control.onDragEnd = { [weak self] in self?.saveLauncherOrigin() }
            launcher.contentView = control
            if let saved = UserDefaults.standard.string(forKey: launcherOriginKey) {
                launcher.setFrameOrigin(NSPointFromString(saved))
            } else if let panel {
                launcher.setFrameOrigin(NSPoint(x: panel.frame.minX + 8, y: panel.frame.maxY - 68))
            }
            minimizedLauncher = launcher
        }
        if let lastTargetFrame { followLauncher(lastTargetFrame) }
        minimizedLauncher?.orderFrontRegardless()
    }

    @objc private func minimizePanel() {
        releaseKeyboard()
        minimized = true
        panel?.orderOut(nil)
        showLauncher()
    }

    @objc private func restorePanel() {
        restore()
    }

    func restore() {
        prepareExpanded()
        panel?.orderFrontRegardless()
    }

    func prepareExpanded() {
        minimized = false
        minimizedLauncher?.orderOut(nil)
    }

    func toggleMinimized() {
        if minimized { restore() }
        else { minimizePanel() }
    }

    @objc private func closePanel() { onClose() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidResignKey(_ notification: Notification) { releaseKeyboard() }
}
