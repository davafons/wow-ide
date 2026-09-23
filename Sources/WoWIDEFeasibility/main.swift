import AppKit
import Carbon
import CefKit
import Darwin
import ServiceManagement
import UniformTypeIdentifiers

private enum PreferenceKey {
    static let targetPath = "targetBundlePath"
    static let targetBundleID = "targetBundleIdentifier"
    static let targetName = "targetDisplayName"
    static let browserVisible = "chromiumBrowserVisible"
    static let terminalVisible = "terminalPanelVisible"
}

enum PanelMode: String {
    case activating = "Activating"
    case nonactivating = "Non-activating"
}

final class ProbePanel: NSPanel {
    var allowsMainWindow = true
    var allowsTextFocus = false
    weak var focusTextField: NSTextField?
    var onTextMouseDown: (() -> Void)?
    var onNonTextMouseDown: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { allowsMainWindow || allowsTextFocus }
    override var canBecomeMain: Bool { allowsMainWindow }

    override func sendEvent(_ event: NSEvent) {
        var clickedTextField: NSTextField?
        if !allowsMainWindow, event.type == .leftMouseDown {
            let field = focusTextField
            let textClick = field.map { $0.convert($0.bounds, to: nil).contains(event.locationInWindow) } ?? false
            if textClick, let field {
                clickedTextField = field
                if field.currentEditor() == nil { onTextMouseDown?() }
                allowsTextFocus = true
                makeKey()
                makeFirstResponder(field)
            } else {
                // Close the gate before AppKit dispatches buttons or title-bar drags.
                allowsTextFocus = false
                if field?.currentEditor() != nil { makeFirstResponder(nil) }
                onNonTextMouseDown?(event)
            }
        }
        super.sendEvent(event)
        if let clickedTextField, clickedTextField.currentEditor() == nil {
            allowsTextFocus = false
            if isKeyWindow {
                orderOut(nil)
                orderFrontRegardless()
            }
        }
    }
}

final class ProbeTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
}

final class ProbeButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class DragHeaderView: NSView {
    private var pointerAtMouseDown: NSPoint?
    private var originAtMouseDown: NSPoint?
    var onDragEnd: (() -> Void)?
    var titleText = "WoW IDE" { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let title = titleText as NSString
        let font = NSFont.boldSystemFont(ofSize: 15)
        title.draw(at: NSPoint(x: 4, y: (bounds.height - font.pointSize) / 2 - 2),
                   withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    override func mouseDown(with event: NSEvent) {
        pointerAtMouseDown = NSEvent.mouseLocation
        originAtMouseDown = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let pointerAtMouseDown, let originAtMouseDown else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: originAtMouseDown.x + pointer.x - pointerAtMouseDown.x,
            y: originAtMouseDown.y + pointer.y - pointerAtMouseDown.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        pointerAtMouseDown = nil
        originAtMouseDown = nil
        onDragEnd?()
    }
}

final class ResizeHandleView: NSView {
    private var pointerAtMouseDown: NSPoint?
    private var frameAtMouseDown: NSRect?
    var onResizeEnd: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lines = NSBezierPath()
        for offset: CGFloat in [0, 5, 10] {
            lines.move(to: NSPoint(x: bounds.maxX - 4 - offset, y: 4))
            lines.line(to: NSPoint(x: bounds.maxX - 4, y: 4 + offset))
        }
        lines.lineWidth = 1
        NSColor.secondaryLabelColor.setStroke()
        lines.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        pointerAtMouseDown = NSEvent.mouseLocation
        frameAtMouseDown = window?.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let pointerAtMouseDown, let frameAtMouseDown else { return }
        let pointer = NSEvent.mouseLocation
        let width = max(window.minSize.width, frameAtMouseDown.width + pointer.x - pointerAtMouseDown.x)
        let height = max(window.minSize.height, frameAtMouseDown.height - pointer.y + pointerAtMouseDown.y)
        window.setFrame(NSRect(x: frameAtMouseDown.minX, y: frameAtMouseDown.maxY - height,
                               width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        pointerAtMouseDown = nil
        frameAtMouseDown = nil
        onResizeEnd?()
    }
}

/// A nonactivating, independently draggable restore control. A short click
/// restores its panel; a drag moves only the icon and never enters AppKit's
/// system title-bar tracking loop.
final class DraggableRestoreView: NSView {
    var symbol = "B" { didSet { needsDisplay = true } }
    var onRestore: (() -> Void)?
    var onDragEnd: (() -> Void)?
    private var downPointer: NSPoint?
    private var downOrigin: NSPoint?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let border = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: border, xRadius: 12, yRadius: 12)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.27, alpha: 0.96),
                   ending: NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.15, alpha: 0.96))?
            .draw(in: path, angle: 90)
        path.lineWidth = 2
        NSColor(calibratedRed: 0.54, green: 0.75, blue: 0.83, alpha: 0.9).setStroke()
        path.stroke()
        let font = NSFont.monospacedSystemFont(ofSize: symbol == "B" ? 27 : 20, weight: .bold)
        let label = symbol as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2),
                   withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        downPointer = NSEvent.mouseLocation
        downOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPointer, let downOrigin, let window else { return }
        let pointer = NSEvent.mouseLocation
        let dx = pointer.x - downPointer.x
        let dy = pointer.y - downPointer.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() }
        else { onRestore?() }
        downPointer = nil
        downOrigin = nil
        dragged = false
    }
}

private func hotKeyCallback(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }
    let delegate = Unmanaged<OverlayAppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { delegate.handleHotKey(identifier.id) }
    return noErr
}

@MainActor
private final class OverlayAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var browserController: ChromiumPanelController?
    private var terminalController: TerminalPanelController?
    private var codexController: CodexPanelController?
    private let settingsController = SettingsWindowController()
    private var browserRequestedVisible = true
    private var terminalRequestedVisible = false
    private var codexRequestedVisible = false
    private var manuallyHidden = false
    private var workspaceVisible = true
    private var targetBundlePath: String?
    private var targetBundleID: String?
    private var targetName: String?
    private var targetProcessID: pid_t?
    private var targetWindowID: Int?
    private var targetWorkspace: String?
    private var windowPollInFlight = false
    private let mode: PanelMode = .nonactivating
    private var visibilityItem: NSMenuItem!
    private var targetStatusItem: NSMenuItem!
    private var clearTargetItem: NSMenuItem!
    private var browserItem: NSMenuItem!
    private var terminalItem: NSMenuItem!
    private var codexItem: NSMenuItem!
    private var clearBrowserDataItem: NSMenuItem!
    private var shortcutItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func findRunningTarget() -> NSRunningApplication? {
        guard let targetBundlePath else { return nil }
        let candidates = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let selectedPath = normalizedPath(URL(fileURLWithPath: targetBundlePath))
        if let exact = candidates.first(where: { app in
            app.bundleURL.map { normalizedPath($0) == selectedPath } ?? false
        }) { return exact }
        guard !FileManager.default.fileExists(atPath: targetBundlePath),
              let targetBundleID, !targetBundleID.isEmpty else { return nil }
        let matches = candidates.filter { $0.bundleIdentifier == targetBundleID }
        return matches.count == 1 ? matches[0] : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        targetBundlePath = defaults.string(forKey: PreferenceKey.targetPath)
        targetBundleID = defaults.string(forKey: PreferenceKey.targetBundleID)
        targetName = defaults.string(forKey: PreferenceKey.targetName)
        browserRequestedVisible = defaults.object(forKey: PreferenceKey.browserVisible) == nil
            ? true : defaults.bool(forKey: PreferenceKey.browserVisible)
        terminalRequestedVisible = defaults.bool(forKey: PreferenceKey.terminalVisible)
        codexRequestedVisible = defaults.bool(forKey: AppPreferenceKey.codexVisible)

        if CefRuntime.shared.isInitialized {
            browserController = ChromiumPanelController(
                targetProvider: { [weak self] in self?.findRunningTarget() },
                onClose: { [weak self] in self?.setBrowserVisible(false) }
            )
        }
        terminalController = TerminalPanelController(
            targetProvider: { [weak self] in self?.findRunningTarget() },
            onClose: { [weak self] in self?.setTerminalVisible(false) }
        )
        codexController = CodexPanelController(
            targetProvider: { [weak self] in self?.findRunningTarget() },
            onClose: { [weak self] in self?.setCodexVisible(false) }
        )
        configureMenu()
        registerGlobalHotKeys()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceCenter.addObserver(self, selector: #selector(workspaceApplicationChanged(_:)),
                                        name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetPanelLayout),
            name: .wowIDEResetLayout, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(chooseTargetApp),
            name: .wowIDEChooseTarget, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .wowIDEPreferencesChanged, object: nil
        )
        Timer.scheduledTimer(timeInterval: 2, target: self,
                             selector: #selector(reconcileTargetState), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 0.75, target: self,
                             selector: #selector(pollTargetWindow), userInfo: nil, repeats: true)
        reconcileTargetState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        browserController?.shutdown()
        terminalController?.shutdown()
        codexController?.shutdown()
        for hotKeyRef in hotKeyRefs { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    @objc private func workspaceApplicationChanged(_ notification: Notification) {
        reconcileTargetState()
    }

    @objc private func reconcileTargetState() {
        let running = findRunningTarget()
        let newPID = running?.processIdentifier
        if newPID != targetProcessID {
            targetProcessID = newPID
            targetWindowID = nil
            targetWorkspace = nil
            if targetBundlePath != nil { workspaceVisible = false }
        }
        if targetBundlePath == nil {
            workspaceVisible = true
            browserController?.detachTarget()
            terminalController?.detachTarget()
            codexController?.detachTarget()
        } else if running == nil {
            // Keep the workspace usable for web/terminal debugging while WoW
            // is closed. Reattach and apply workspace gating when it launches.
            workspaceVisible = true
            browserController?.detachTarget()
            terminalController?.detachTarget()
            codexController?.detachTarget()
        } else {
            pollTargetWindow()
        }
        updatePanelVisibility()
        updateMenu()
    }

    @objc private func pollTargetWindow() {
        guard let processID = targetProcessID, !windowPollInFlight else { return }
        windowPollInFlight = true
        let preferredID = targetWindowID
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                TargetWindowTracker.snapshot(processID: processID, preferredWindowID: preferredID)
            }.value
            self?.apply(snapshot, for: processID)
        }
    }

    private func apply(_ snapshot: TrackedTargetWindow?, for processID: pid_t) {
        windowPollInFlight = false
        guard targetProcessID == processID else { return }
        guard let snapshot else {
            workspaceVisible = false
            updatePanelVisibility()
            updateMenu()
            return
        }
        targetWindowID = snapshot.id
        targetWorkspace = snapshot.workspace
        workspaceVisible = snapshot.workspaceVisible
        updatePanelVisibility()
        if workspaceVisible {
            // CGWindow bounds use a top-left origin; AppKit uses bottom-left.
            let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
            let rect = NSRect(x: snapshot.cgBounds.minX,
                              y: mainTop - snapshot.cgBounds.maxY,
                              width: snapshot.cgBounds.width,
                              height: snapshot.cgBounds.height)
            browserController?.follow(targetFrame: rect)
            terminalController?.follow(targetFrame: rect)
            codexController?.follow(targetFrame: rect)
        }
        updateMenu()
    }

    private func updatePanelVisibility() {
        let shouldShow = !manuallyHidden && workspaceVisible
        if shouldShow && browserRequestedVisible {
            if browserController?.isVisible != true { browserController?.show(mode: mode) }
        } else if browserController?.isVisible == true {
            browserController?.hide()
        }
        if shouldShow && terminalRequestedVisible {
            if terminalController?.isVisible != true { terminalController?.show(mode: mode) }
        } else if terminalController?.isVisible == true {
            terminalController?.hide()
        }
        if shouldShow && codexRequestedVisible {
            if codexController?.isVisible != true { codexController?.show(mode: mode) }
        } else if codexController?.isVisible == true {
            codexController?.hide()
        }
    }

    private func configureMenu() {
        statusItem.button?.title = "WoW IDE"
        statusItem.button?.toolTip = "WoW IDE overlay"
        visibilityItem = NSMenuItem(title: "Hide Panels", action: #selector(toggleAllPanels), keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose WoW App…", action: #selector(chooseTargetApp), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        targetStatusItem = NSMenuItem(title: "Target: none", action: nil, keyEquivalent: "")
        targetStatusItem.isEnabled = false
        menu.addItem(targetStatusItem)
        clearTargetItem = NSMenuItem(title: "Clear Target", action: #selector(clearTarget), keyEquivalent: "")
        clearTargetItem.target = self
        menu.addItem(clearTargetItem)
        menu.addItem(.separator())
        browserItem = NSMenuItem(title: "Show Chromium Browser", action: #selector(toggleBrowser), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)
        terminalItem = NSMenuItem(title: "Show Ghostty Terminal", action: #selector(toggleTerminal), keyEquivalent: "")
        terminalItem.target = self
        menu.addItem(terminalItem)
        codexItem = NSMenuItem(title: "Show Codex", action: #selector(toggleCodex), keyEquivalent: "")
        codexItem.target = self
        menu.addItem(codexItem)
        clearBrowserDataItem = NSMenuItem(title: "Clear Chromium Data on Next Launch",
                                          action: #selector(toggleClearBrowserData), keyEquivalent: "")
        clearBrowserDataItem.target = self
        menu.addItem(clearBrowserDataItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        shortcutItem = NSMenuItem(title: "Global shortcuts: registering…", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)
        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateMenu()
    }

    private func updateMenu() {
        guard visibilityItem != nil else { return }
        visibilityItem.title = manuallyHidden ? "Show Panels" : "Hide Panels"
        let status = targetBundlePath == nil ? "no target selected" :
            targetProcessID == nil ? "not running · standalone" :
            targetWorkspace.map { "workspace \($0)\(workspaceVisible ? " visible" : " hidden")" }
                ?? (workspaceVisible ? "visible" : "window unavailable")
        targetStatusItem.title = "Target: \(targetName ?? "none") (\(status))"
        targetStatusItem.toolTip = targetBundlePath
        clearTargetItem.isEnabled = targetBundlePath != nil
        browserItem.title = browserController?.isVisible == true ? "Hide Chromium Browser" : "Show Chromium Browser"
        browserItem.isEnabled = browserController != nil
        terminalItem.title = terminalController?.isVisible == true ? "Hide Ghostty Terminal" : "Show Ghostty Terminal"
        codexItem.title = codexController?.isVisible == true ? "Hide Codex" : "Show Codex"
        clearBrowserDataItem.state = UserDefaults.standard.bool(forKey: BrowserStorage.clearOnLaunchKey) ? .on : .off
        let bundled = Bundle.main.bundleURL.pathExtension.lowercased() == "app" && Bundle.main.bundleIdentifier != nil
        loginItem.isEnabled = bundled
        if bundled {
            switch SMAppService.mainApp.status {
            case .enabled:
                loginItem.title = "Start at Login"
                loginItem.state = .on
            case .requiresApproval:
                loginItem.title = "Start at Login (needs System Settings approval)"
                loginItem.state = .on
            default:
                loginItem.title = "Start at Login"
                loginItem.state = .off
            }
        } else {
            loginItem.title = "Start at Login (packaged app only)"
            loginItem.state = .off
        }
    }

    private func registerGlobalHotKeys() {
        if eventHandlerRef == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let handler = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1,
                                              &type, Unmanaged.passUnretained(self).toOpaque(),
                                              &eventHandlerRef)
            guard handler == noErr else {
                shortcutItem.title = "Global shortcuts unavailable (use menu)"
                return
            }
        }

        for reference in hotKeyRefs { UnregisterEventHotKey(reference) }
        hotKeyRefs.removeAll()
        let keys: [(UInt32, UInt32)]
        let modifiers: UInt32
        let description: String
        switch AppPreferences.shortcutPreset {
        case .commandLetters:
            keys = [(UInt32(kVK_ANSI_R), 1), (UInt32(kVK_ANSI_F), 2), (UInt32(kVK_ANSI_D), 3)]
            modifiers = UInt32(cmdKey)
            description = "⌘R browser · ⌘F terminal · ⌘D Codex"
        case .controlOptionNumbers:
            keys = [(UInt32(kVK_ANSI_1), 1), (UInt32(kVK_ANSI_2), 2), (UInt32(kVK_ANSI_3), 3)]
            modifiers = UInt32(controlKey | optionKey)
            description = "⌃⌥1 browser · ⌃⌥2 terminal · ⌃⌥3 Codex"
        }
        let results = keys.map { registerHotKey(keyCode: $0.0, modifiers: modifiers, id: $0.1) }
        let browserRegistered = results[0]
        let terminalRegistered = results[1]
        let codexRegistered = results[2]
        shortcutItem.title = browserRegistered && terminalRegistered && codexRegistered
            ? "Shortcuts: \(description)"
            : "Some global shortcuts are unavailable (use menu)"
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        let identifier = EventHotKeyID(signature: 0x574F5749, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, identifier,
            GetApplicationEventTarget(), 0, &reference
        )
        if status == noErr, let reference {
            hotKeyRefs.append(reference)
            return true
        }
        return false
    }

    @objc private func toggleAllPanels() {
        manuallyHidden.toggle()
        updatePanelVisibility()
        updateMenu()
    }

    func handleHotKey(_ id: UInt32) {
        switch id {
        case 1: cycleBrowserFromHotKey()
        case 2: cycleTerminalFromHotKey()
        case 3: cycleCodexFromHotKey()
        default: break
        }
    }

    private func cycleBrowserFromHotKey() {
        guard let browserController else { return }
        if manuallyHidden || !browserRequestedVisible || !browserController.isVisible {
            browserController.prepareExpanded()
            setBrowserVisible(true)
        } else {
            browserController.toggleMinimized()
            updateMenu()
        }
    }

    private func cycleTerminalFromHotKey() {
        guard let terminalController else { return }
        if manuallyHidden || !terminalRequestedVisible || !terminalController.isVisible {
            terminalController.prepareExpanded()
            setTerminalVisible(true)
        } else {
            terminalController.toggleMinimized()
            updateMenu()
        }
    }

    private func cycleCodexFromHotKey() {
        guard let codexController else { return }
        if manuallyHidden || !codexRequestedVisible || !codexController.isVisible {
            codexController.prepareExpanded()
            setCodexVisible(true)
        } else {
            codexController.toggleMinimized()
            updateMenu()
        }
    }

    private func setBrowserVisible(_ visible: Bool) {
        browserRequestedVisible = visible
        UserDefaults.standard.set(visible, forKey: PreferenceKey.browserVisible)
        if visible { manuallyHidden = false }
        updatePanelVisibility()
        updateMenu()
    }

    private func setTerminalVisible(_ visible: Bool) {
        terminalRequestedVisible = visible
        UserDefaults.standard.set(visible, forKey: PreferenceKey.terminalVisible)
        if visible { manuallyHidden = false }
        updatePanelVisibility()
        updateMenu()
    }

    private func setCodexVisible(_ visible: Bool) {
        codexRequestedVisible = visible
        UserDefaults.standard.set(visible, forKey: AppPreferenceKey.codexVisible)
        if visible { manuallyHidden = false }
        updatePanelVisibility()
        updateMenu()
    }

    @objc private func toggleBrowser() { setBrowserVisible(!browserRequestedVisible) }
    @objc private func toggleTerminal() { setTerminalVisible(!terminalRequestedVisible) }
    @objc private func toggleCodex() { setCodexVisible(!codexRequestedVisible) }
    @objc private func showSettings() { settingsController.show() }

    @objc private func resetPanelLayout() {
        browserController?.resetLayout()
        terminalController?.resetLayout()
        codexController?.resetLayout()
    }

    @objc private func preferencesChanged() {
        registerGlobalHotKeys()
        updateMenu()
    }

    @objc private func toggleClearBrowserData() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: BrowserStorage.clearOnLaunchKey),
                     forKey: BrowserStorage.clearOnLaunchKey)
        updateMenu()
    }

    @objc private func chooseTargetApp() {
        let picker = NSOpenPanel()
        picker.title = "Choose the WoW application"
        picker.message = "Select the exact .app bundle to follow."
        picker.prompt = "Watch App"
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.allowedContentTypes = [.applicationBundle]
        picker.allowsMultipleSelection = false
        if let targetBundlePath {
            picker.directoryURL = URL(fileURLWithPath: targetBundlePath).deletingLastPathComponent()
        }
        guard picker.runModal() == .OK, let url = picker.url,
              url.pathExtension.lowercased() == "app" else { return }
        let bundle = Bundle(url: url)
        targetBundlePath = normalizedPath(url)
        targetBundleID = bundle?.bundleIdentifier
        targetName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let defaults = UserDefaults.standard
        defaults.set(targetBundlePath, forKey: PreferenceKey.targetPath)
        defaults.set(targetBundleID, forKey: PreferenceKey.targetBundleID)
        defaults.set(targetName, forKey: PreferenceKey.targetName)
        manuallyHidden = false
        reconcileTargetState()
    }

    @objc private func clearTarget() {
        targetBundlePath = nil
        targetBundleID = nil
        targetName = nil
        targetProcessID = nil
        targetWindowID = nil
        targetWorkspace = nil
        for key in [PreferenceKey.targetPath, PreferenceKey.targetBundleID, PreferenceKey.targetName] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        reconcileTargetState()
    }

    @objc private func toggleStartAtLogin() {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              Bundle.main.bundleIdentifier != nil else { return }
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("WoW IDE: Start at Login failed: %@", error.localizedDescription)
        }
        updateMenu()
    }

    @objc private func quit() {
        // CefRuntime owns the asynchronous browser-closing sequence and
        // re-enters terminate after CEF has released every browser.
        NSApp.terminate(nil)
    }
}

@MainActor
private func availableLoopbackPort() -> Int? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return nil }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &size)
        }
    }
    guard named == 0 else { return nil }
    return Int(UInt16(bigEndian: address.sin_port))
}

@MainActor
private func runApplication() {
    BrowserStorage.clearIfScheduled()
    var cefConfiguration = CefConfiguration.default
    cefConfiguration.rootCachePath = BrowserStorage.root
    cefConfiguration.cachePath = BrowserStorage.profile
    // CefSwift 0.1.0 chooses the real macOS Keychain in release builds,
    // including this ad-hoc-signed localhost probe. That can block startup
    // before AppKit shows the menu. Keep this internal build independent of
    // the user's Chrome/Brave Keychain items; use a real signing identity and
    // Keychain policy before supporting broader or sensitive browsing.
    cefConfiguration.safeStorage = .mockKeychain
    cefConfiguration.persistSessionCookies = true
    // CEF's native DevTools popup traps when parented to an NSView on macOS.
    // Its embedded inspector connects to this loopback CDP endpoint. Chromium
    // checks the exact WebSocket Origin, so choose the port before initialize
    // and allow only our own inspector URL, never a wildcard.
    if let port = availableLoopbackPort() {
        BrowserStorage.configuredDebuggingPort = port
        cefConfiguration.remoteDebuggingPort = port
        cefConfiguration.extraCommandLineSwitches["remote-allow-origins"] =
            "http://127.0.0.1:\(port)"
    } else {
        NSLog("WoW IDE: Could not reserve a loopback port for DevTools")
    }
    do {
        try CefRuntime.shared.initialize(configuration: cefConfiguration)
    } catch {
        NSLog("WoW IDE: Chromium unavailable: %@", String(describing: error))
    }
    let app = NSApplication.shared
    let delegate = OverlayAppDelegate()
    app.delegate = delegate
    app.run()
}

MainActor.assumeIsolated { runApplication() }
