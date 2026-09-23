import AppKit
import CefKit

@MainActor
enum BrowserStorage {
    static let clearOnLaunchKey = "clearChromiumDataOnNextLaunch"
    static let lastURLKey = "chromiumLastURL"
    static let frameKey = "chromiumPanelFrame"
    static var configuredDebuggingPort: Int?

    static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WoWIDEFeasibility/Chromium", isDirectory: true)
    }

    static var profile: URL { root.appendingPathComponent("Profile", isDirectory: true) }

    static func debuggingPort() -> Int? {
        // Fixed-port CEF runs may leave a stale DevToolsActivePort from a
        // previous ephemeral-port run. Trust only this process's selection.
        configuredDebuggingPort
    }

    static func clearIfScheduled() {
        guard UserDefaults.standard.bool(forKey: clearOnLaunchKey) else { return }
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            UserDefaults.standard.removeObject(forKey: clearOnLaunchKey)
        } catch {
            NSLog("WoW IDE: Could not clear Chromium data at %@: %@", root.path, String(describing: error))
        }
    }
}

private struct PageFocusMessage: Decodable, Sendable {
    let editable: Bool
    let browserID: Int32
}

private struct DebugTarget: Decodable, Sendable {
    let id: String
    let type: String
    let url: String
}

/// CEF adds its own native child view after browser creation. Keep that child
/// sized to the host when the panel or its DevTools split changes size.
private final class BrowserHostView: NSView {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        for subview in subviews { subview.frame = bounds }
    }
}

@MainActor
private final class BrowserTab {
    let id = UUID()
    let host: BrowserHostView
    let devToolsHost: BrowserHostView
    let browser: CefBrowser
    var inspector: CefBrowser?
    var title = "New tab"

    init(host: BrowserHostView, devToolsHost: BrowserHostView, browser: CefBrowser) {
        self.host = host
        self.devToolsHost = devToolsHost
        self.browser = browser
    }
}

private enum BrowserViewport: Int {
    case desktop = 0
    case responsive = 1
    case phone = 2
    case tablet = 3
}

@MainActor
final class ChromiumPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate, CefBrowserDelegate {
    private let targetProvider: @MainActor () -> NSRunningApplication?
    private let onClose: @MainActor () -> Void
    private var panel: ProbePanel?
    private var minimizedLauncher: ProbePanel?
    private weak var panelMaterial: NSVisualEffectView?
    private var isMinimized = false
    private let anchor = TargetWindowAnchor(defaultsKey: "browserTargetOffset")
    private let launcherAnchor = TargetWindowAnchor(defaultsKey: "browserLauncherTargetOffset")
    private let launcherOriginKey = "browserLauncherOrigin"
    private var lastTargetFrame: NSRect?
    private var tabs: [BrowserTab] = []
    private var activeTabID: UUID?
    private var webContainer: BrowserHostView?
    private var devToolsContainer: BrowserHostView?
    private var tabStrip: NSStackView?
    private var addressField: ProbeTextField?
    private var backButton: ProbeButton?
    private var forwardButton: ProbeButton?
    private var toolsButton: ProbeButton?
    private var focusToolsButton: ProbeButton?
    private var viewportPicker: NSPopUpButton?
    private var statusLabel: NSTextField?
    private var fullWidthConstraint: NSLayoutConstraint?
    private var splitWidthConstraint: NSLayoutConstraint?
    private var mode: PanelMode = .nonactivating
    private var viewport: BrowserViewport = .desktop
    private var devToolsVisible = false
    private var devToolsKeyboardFocus = false
    private var keyboardReturnProcessID: pid_t?
    private var pageTextEditing = false
    private var pendingPageFocusClick: TimeInterval?
    private var outsideMouseMonitor: Any?

    private var activeTab: BrowserTab? { tabs.first { $0.id == activeTabID } }
    var isVisible: Bool { panel?.isVisible == true || minimizedLauncher?.isVisible == true }
    var frame: NSRect? { panel?.frame }

    private static let startURL: URL = {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;background:#171b24;color:#edf2fa;
        margin:0;padding:8vh 8%;line-height:1.5}main{max-width:560px;margin:auto}h1{font-size:24px}
        kbd,code{background:#303849;padding:3px 6px;border-radius:5px}a{color:#8ecaff}</style></head>
        <body><main><h1>Chromium preview</h1><p>Enter a URL above to open a site or local web app.</p>
        <p>For a Vite app, start its development server and open <code>http://localhost:5173</code>.
        Live updates use the app's normal WebSocket connection.</p>
        <p>Use the viewport menu for responsive previews and <kbd>DevTools</kbd> for an in-panel inspector.</p>
        </main></body></html>
        """
        return URL(string: "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString())!
    }()

    init(targetProvider: @escaping @MainActor () -> NSRunningApplication?,
         onClose: @escaping @MainActor () -> Void) {
        self.targetProvider = targetProvider
        self.onClose = onClose
        super.init()
        CefRuntime.shared.bridge.register("wowIDEPageFocus") { [weak self] (message: PageFocusMessage) async throws -> Bool in
            await MainActor.run { self?.receivePageFocus(message) }
            return true
        }
        // A nonactivating panel can be key while another app is frontmost.
        // Clicking that already-frontmost app need not produce an application
        // activation notification, so observe outside clicks directly.
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.releaseKeyboardForExternalClick() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .wowIDEPreferencesChanged, object: nil
        )
    }

    func show(mode: PanelMode) {
        if panel == nil || self.mode != mode { rebuild(mode: mode) }
        if isMinimized { showLauncher() }
        else if mode == .activating {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else { panel?.orderFrontRegardless() }
    }

    func hide() {
        releaseBrowserFocus()
        panel?.allowsTextFocus = false
        panel?.orderOut(nil)
        minimizedLauncher?.orderOut(nil)
    }

    func follow(targetFrame: NSRect) {
        lastTargetFrame = targetFrame
        guard let panel else { return }
        anchor.follow(targetFrame, window: panel) { frame, window in
            NSPoint(x: max(16, frame.width - window.frame.width - 16), y: 30)
        }
        followLauncher(targetFrame)
    }

    func detachTarget() {
        lastTargetFrame = nil
        anchor.detach()
        launcherAnchor.detach()
    }

    func setMode(_ mode: PanelMode) {
        if panel == nil { self.mode = mode }
        else if self.mode != mode { rebuild(mode: mode) }
    }

    private func rebuild(mode: PanelMode) {
        let previousFrame = panel?.frame
        let wasVisible = isVisible
        let urls = tabs.map { tab in
            Self.isStartPage(tab.browser.url) ? Self.startURL : (tab.browser.url ?? Self.startURL)
        }
        let selectedIndex = tabs.firstIndex { $0.id == activeTabID } ?? 0
        let reopenTools = devToolsVisible
        for tab in tabs {
            tab.inspector?.close(force: true)
            tab.browser.close(force: true)
        }
        tabs.removeAll()
        activeTabID = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        self.mode = mode
        devToolsVisible = false
        createPanel(frame: previousFrame)
        for url in urls.dropFirst() { addTab(url: url, select: false) }
        if !urls.isEmpty, let first = tabs.first, urls[0] != Self.startURL { first.browser.load(urls[0]) }
        if tabs.indices.contains(selectedIndex) { activateTab(tabs[selectedIndex].id) }
        if reopenTools { toggleDevTools() }
        if wasVisible {
            if isMinimized { showLauncher() }
            else { panel?.orderFrontRegardless() }
        }
    }

    private func savedFrame() -> NSRect? {
        guard let value = UserDefaults.standard.string(forKey: BrowserStorage.frameKey) else { return nil }
        let rect = NSRectFromString(value)
        guard rect.width >= 620, rect.height >= 430,
              NSScreen.screens.contains(where: { NSIntersectsRect($0.visibleFrame, rect) }) else { return nil }
        return rect
    }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: BrowserStorage.frameKey)
        anchor.recordMove(of: panel)
    }

    private static func httpURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let text: String
        if value.contains("://") { text = value }
        else if value.lowercased().hasPrefix("localhost") || value.hasPrefix("127.") || value.hasPrefix("[::1]") {
            text = "http://" + value
        } else { text = "https://" + value }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    private static func isStartPage(_ url: URL?) -> Bool { url == startURL }

    private func createPanel(frame: NSRect?) {
        let initialRect = NSRect(x: 180, y: 180, width: 900, height: 600)
        var mask: NSWindow.StyleMask = [.borderless, .utilityWindow]
        if mode == .nonactivating { mask.insert(.nonactivatingPanel) }
        let newPanel = ProbePanel(contentRect: initialRect, styleMask: mask,
                                  backing: .buffered, defer: false)
        newPanel.allowsMainWindow = mode == .activating
        newPanel.becomesKeyOnlyIfNeeded = mode == .nonactivating
        newPanel.title = "WoW IDE Chromium Browser"
        newPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        newPanel.collectionBehavior = [.fullScreenAuxiliary]
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.isMovableByWindowBackground = false
        newPanel.minSize = NSSize(width: 620, height: 430)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.delegate = self
        newPanel.onTextMouseDown = { [weak self] in self?.captureReturnTarget() }
        newPanel.onNonTextMouseDown = { [weak self] event in self?.leavePageTextEditing(on: event) }

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: initialRect.size))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        applyPanelAppearance(to: content)
        panelMaterial = content

        let header = DragHeaderView()
        header.titleText = "WoW IDE  ·  Chromium Browser"
        header.translatesAutoresizingMaskIntoConstraints = false
        header.onDragEnd = { [weak self] in self?.saveFrame() }
        let collapse = ProbeButton(title: "−", target: self, action: #selector(minimizePanel))
        collapse.toolTip = "Minimize this browser to a small restore button"
        let close = ProbeButton(title: "×", target: self, action: #selector(closePanel))
        for button in [collapse, close] { button.translatesAutoresizingMaskIntoConstraints = false }
        let grip = ResizeHandleView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.onResizeEnd = { [weak self] in self?.saveFrame() }

        let back = ProbeButton(title: "‹", target: self, action: #selector(goBack))
        let forward = ProbeButton(title: "›", target: self, action: #selector(goForward))
        let reload = ProbeButton(title: "↻", target: self, action: #selector(reloadPage))
        let tools = ProbeButton(title: "DevTools", target: self, action: #selector(toggleDevToolsAction))
        let focusTools = ProbeButton(title: "Focus Tools", target: self, action: #selector(focusDevTools))
        focusTools.isHidden = true
        backButton = back
        forwardButton = forward
        toolsButton = tools
        focusToolsButton = focusTools
        back.isEnabled = false
        forward.isEnabled = false
        let address = ProbeTextField(string: UserDefaults.standard.string(forKey: BrowserStorage.lastURLKey) ?? "")
        address.placeholderString = "https://example.com or localhost:5173"
        address.delegate = self
        address.target = self
        address.action = #selector(openAddress)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressField = address
        newPanel.focusTextField = address
        let viewportMenu = NSPopUpButton()
        viewportMenu.addItems(withTitles: ["Desktop", "Responsive", "Phone 390", "Tablet 768"])
        viewportMenu.selectItem(at: viewport.rawValue)
        viewportMenu.target = self
        viewportMenu.action = #selector(changeViewport)
        viewportPicker = viewportMenu
        let toolbar = NSStackView(views: [back, forward, reload, address, viewportMenu, tools, focusTools])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 5
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 3
        strip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip = strip
        let web = BrowserHostView()
        web.translatesAutoresizingMaskIntoConstraints = false
        webContainer = web
        let dev = BrowserHostView()
        dev.translatesAutoresizingMaskIntoConstraints = false
        dev.isHidden = true
        devToolsContainer = dev
        let status = NSTextField(labelWithString: "Enter a URL to begin")
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = status

        for view in [header, collapse, close, toolbar, strip, web, dev, status, grip] { content.addSubview(view) }
        let full = web.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12)
        let split = web.trailingAnchor.constraint(equalTo: dev.leadingAnchor, constant: -6)
        fullWidthConstraint = full
        splitWidthConstraint = split
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: collapse.leadingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            header.heightAnchor.constraint(equalToConstant: 30),
            collapse.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            collapse.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            collapse.widthAnchor.constraint(equalToConstant: 26),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 26),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            address.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            strip.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            strip.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            strip.heightAnchor.constraint(equalToConstant: 25),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            web.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 6),
            web.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -5),
            full,
            dev.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            dev.topAnchor.constraint(equalTo: web.topAnchor),
            dev.bottomAnchor.constraint(equalTo: web.bottomAnchor),
            dev.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.42),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
            grip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            grip.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            grip.widthAnchor.constraint(equalToConstant: 20),
            grip.heightAnchor.constraint(equalToConstant: 20)
        ])
        newPanel.contentView = content
        if let frame = frame ?? savedFrame() { newPanel.setFrame(frame, display: false) }
        panel = newPanel
        content.layoutSubtreeIfNeeded()
        addTab(url: Self.startURL, select: true)
    }

    private func addTab(url: URL, select: Bool) {
        guard tabs.count < 8, let webContainer, let devToolsContainer else { return }
        let host = BrowserHostView(frame: webContainer.bounds)
        host.autoresizingMask = [.width, .height]
        let devHost = BrowserHostView(frame: devToolsContainer.bounds)
        devHost.autoresizingMask = [.width, .height]
        webContainer.addSubview(host)
        devToolsContainer.addSubview(devHost)
        let browser = CefBrowser.createBrowser(parentView: host, bounds: host.bounds,
                                               url: url, delegate: self)
        let tab = BrowserTab(host: host, devToolsHost: devHost, browser: browser)
        tabs.append(tab)
        if select || activeTabID == nil { activateTab(tab.id) }
        else { host.isHidden = true; devHost.isHidden = true }
        if browser.id < 0 { statusLabel?.stringValue = "Chromium browser creation failed" }
    }

    private func activateTab(_ id: UUID) {
        guard let selected = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        for tab in tabs {
            tab.host.isHidden = tab.id != id
            tab.devToolsHost.isHidden = tab.id != id
        }
        if devToolsVisible { openDockedDevTools(for: selected) }
        if let url = selected.browser.url, !Self.isStartPage(url) {
            addressField?.stringValue = url.absoluteString
        } else { addressField?.stringValue = "" }
        backButton?.isEnabled = selected.browser.canGoBack
        forwardButton?.isEnabled = selected.browser.canGoForward
        statusLabel?.stringValue = Self.isStartPage(selected.browser.url) ? "Enter a URL to begin" : "Chromium"
        rebuildTabStrip()
        applyViewport(to: selected)
    }

    private func rebuildTabStrip() {
        guard let tabStrip else { return }
        for view in tabStrip.arrangedSubviews { tabStrip.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let choose = ProbeButton(title: String(tab.title.prefix(14)), target: self, action: #selector(selectTabAction(_:)))
            choose.tag = index
            choose.font = .systemFont(ofSize: 11, weight: tab.id == activeTabID ? .semibold : .regular)
            choose.toolTip = tab.browser.url?.absoluteString
            let close = ProbeButton(title: "×", target: self, action: #selector(closeTabAction(_:)))
            close.tag = index
            let pair = NSStackView(views: [choose, close])
            pair.orientation = .horizontal
            pair.spacing = 0
            tabStrip.addArrangedSubview(pair)
        }
        let add = ProbeButton(title: "+", target: self, action: #selector(newTabAction))
        add.toolTip = "New tab"
        add.isEnabled = tabs.count < 8
        tabStrip.addArrangedSubview(add)
    }

    private func openDockedDevTools(for tab: BrowserTab) {
        guard devToolsVisible, tab.inspector == nil else { return }
        statusLabel?.stringValue = "Connecting DevTools…"
        Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            for _ in 0..<20 {
                if let port = BrowserStorage.debuggingPort(),
                   let url = await self.inspectorURL(for: tab, port: port) {
                    guard self.devToolsVisible, self.tabs.contains(where: { $0 === tab }),
                          tab.inspector == nil else { return }
                    tab.devToolsHost.layoutSubtreeIfNeeded()
                    let inspector = CefBrowser.createBrowser(
                        parentView: tab.devToolsHost, bounds: tab.devToolsHost.bounds,
                        url: url, delegate: nil
                    )
                    tab.inspector = inspector
                    self.statusLabel?.stringValue = inspector.id < 0
                        ? "Could not create DevTools view" : "Chromium · DevTools docked"
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if self.devToolsVisible, self.activeTabID == tab.id {
                self.statusLabel?.stringValue = "DevTools endpoint unavailable"
            }
        }
    }

    private func inspectorURL(for tab: BrowserTab, port: Int) async -> URL? {
        guard let pageURL = tab.browser.url?.absoluteString,
              let endpoint = URL(string: "http://127.0.0.1:\(port)/json/list"),
              let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let targets = try? JSONDecoder().decode([DebugTarget].self, from: data) else { return nil }
        let matches = targets.filter { $0.type == "page" && $0.url == pageURL }
        // CEF's HTTP target list has no CefBrowser identifier. Avoid
        // inspecting the wrong tab when two pages have the same URL.
        guard matches.count == 1, let id = matches.first?.id,
              id.range(of: "^[A-Fa-f0-9]+$", options: .regularExpression) != nil else { return nil }
        // CEF 148 advertises an external frontend URL in /json/list, but it
        // also serves its bundled inspector and scripts at /devtools/.
        // Loading that local frontend keeps DevTools inside this CEF view and
        // avoids a network dependency on Google's hosted frontend.
        return URL(string: "http://127.0.0.1:\(port)/devtools/inspector.html?ws=127.0.0.1:\(port)/devtools/page/\(id)")
    }

    private func toggleDevTools() {
        guard let devToolsContainer else { return }
        devToolsVisible.toggle()
        fullWidthConstraint?.isActive = !devToolsVisible
        splitWidthConstraint?.isActive = devToolsVisible
        devToolsContainer.isHidden = !devToolsVisible
        focusToolsButton?.isHidden = !devToolsVisible
        toolsButton?.title = devToolsVisible ? "Hide Tools" : "DevTools"
        panel?.contentView?.layoutSubtreeIfNeeded()
        if devToolsVisible, let activeTab { openDockedDevTools(for: activeTab) }
        if !devToolsVisible { returnToGame() }
    }

    private func applyViewport(to tab: BrowserTab) {
        switch viewport {
        case .desktop:
            tab.browser.sendDevToolsCommand("Emulation.clearDeviceMetricsOverride")
            tab.browser.sendDevToolsCommand("Emulation.setTouchEmulationEnabled", params: ["enabled": false])
        case .responsive:
            let width = max(1, Int(webContainer?.bounds.width ?? 800))
            let height = max(1, Int(webContainer?.bounds.height ?? 600))
            tab.browser.sendDevToolsCommand("Emulation.setDeviceMetricsOverride", params: [
                "width": width, "height": height, "deviceScaleFactor": 1, "mobile": false
            ])
            tab.browser.sendDevToolsCommand("Emulation.setTouchEmulationEnabled", params: ["enabled": false])
        case .phone, .tablet:
            let width = viewport == .phone ? 390 : 768
            let height = viewport == .phone ? 844 : 1024
            let scale = viewport == .phone ? 3 : 2
            tab.browser.sendDevToolsCommand("Emulation.setDeviceMetricsOverride", params: [
                "width": width, "height": height, "deviceScaleFactor": scale, "mobile": true,
                "screenWidth": width, "screenHeight": height
            ])
            tab.browser.sendDevToolsCommand("Emulation.setTouchEmulationEnabled", params: ["enabled": true])
        }
    }

    private func captureReturnTarget() {
        let target = targetProvider()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        keyboardReturnProcessID = frontmost == target?.processIdentifier ? frontmost : nil
    }

    private func scheduleReturnToTarget() {
        guard let processID = keyboardReturnProcessID else { return }
        DispatchQueue.main.async { [weak self] in self?.restoreTargetKeyboard(processID) }
    }

    private func restoreTargetKeyboard(_ processID: pid_t) {
        guard mode == .nonactivating, !pageTextEditing, !devToolsKeyboardFocus,
              addressField?.currentEditor() == nil,
              let panel, let target = targetProvider(),
              keyboardReturnProcessID == processID,
              target.processIdentifier == processID else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreTargetKeyboard(processID)
            }
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmost == processID || frontmost == NSRunningApplication.current.processIdentifier else { return }
        if panel.isKeyWindow {
            let wasVisible = panel.isVisible
            panel.orderOut(nil)
            if wasVisible { panel.orderFrontRegardless() }
        }
        panel.allowsTextFocus = false
        if NSApp.isActive { NSApp.yieldActivation(to: target) }
        _ = target.activate(options: [])
        keyboardReturnProcessID = nil
    }

    private func receivePageFocus(_ message: PageFocusMessage) {
        guard mode == .nonactivating, let panel, panel.isVisible,
              activeTab?.browser.id == message.browserID else { return }
        if message.editable {
            guard !pageTextEditing else { return }
            // Only a recent click in this browser may move keyboard focus to
            // the panel. A queued JS focusin after an outside click is ignored.
            guard let click = pendingPageFocusClick,
                  ProcessInfo.processInfo.systemUptime - click < 1.5 else { return }
            pendingPageFocusClick = nil
            if keyboardReturnProcessID == nil { captureReturnTarget() }
            pageTextEditing = true
            panel.allowsTextFocus = true
            panel.makeKey()
            activeTab?.browser.setFocus(true)
        } else if pageTextEditing {
            pageTextEditing = false
            pendingPageFocusClick = nil
            panel.allowsTextFocus = false
            scheduleReturnToTarget()
        }
    }

    private func leavePageTextEditing(on event: NSEvent) {
        guard let panel else { return }
        if let webContainer, webContainer.convert(webContainer.bounds, to: nil).contains(event.locationInWindow) {
            pendingPageFocusClick = ProcessInfo.processInfo.systemUptime
            if !pageTextEditing { captureReturnTarget() }
            return
        }
        pendingPageFocusClick = nil
        if let devToolsContainer, devToolsVisible,
           devToolsContainer.convert(devToolsContainer.bounds, to: nil).contains(event.locationInWindow) {
            if keyboardReturnProcessID == nil { captureReturnTarget() }
            panel.allowsTextFocus = devToolsKeyboardFocus
            return
        }
        if pageTextEditing || devToolsKeyboardFocus {
            pageTextEditing = false
            devToolsKeyboardFocus = false
            activeTab?.browser.setFocus(false)
            scheduleReturnToTarget()
        }
    }

    private func releaseBrowserFocus() {
        pendingPageFocusClick = nil
        pageTextEditing = false
        devToolsKeyboardFocus = false
        keyboardReturnProcessID = nil
        panel?.allowsTextFocus = false
        activeTab?.browser.setFocus(false)
        activeTab?.inspector?.setFocus(false)
    }

    private func releaseKeyboardForExternalClick() {
        guard mode == .nonactivating, let panel, panel.isVisible else { return }
        releaseBrowserFocus()
        if panel.isKeyWindow {
            // Preserve the floating panel while giving the clicked app its
            // keyboard. orderFrontRegardless never makes a window key.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    private static func focusScript(for browser: CefBrowser) -> String {
        """
        (() => {
          if (window.__wowIDEFocusInstalled) return;
          window.__wowIDEFocusInstalled = true;
          const report = () => {
            const node = document.activeElement;
            const editable = !!node && (node.isContentEditable ||
              node.matches?.('input:not([type=button]):not([type=checkbox]):not([type=radio]), textarea, select'));
            if (window.cefSwift) {
              window.cefSwift.invoke('wowIDEPageFocus', {editable: !!editable, browserID: \(browser.id)}).catch(() => {});
            } else { setTimeout(report, 50); }
          };
          document.addEventListener('focusin', report, true);
          document.addEventListener('focusout', () => setTimeout(report, 0), true);
          report();
        })();
        """
    }

    @objc private func closePanel() { onClose() }
    @objc private func preferencesChanged() { panelMaterial.map(applyPanelAppearance) }

    func resetLayout() {
        UserDefaults.standard.removeObject(forKey: BrowserStorage.frameKey)
        anchor.detach()
        panel?.setFrame(NSRect(x: 180, y: 180, width: 900, height: 600), display: true)
        saveFrame()
    }

    func shutdown() {
        releaseBrowserFocus()
        for tab in tabs {
            tab.inspector?.close(force: true)
            tab.browser.close(force: true)
        }
        tabs.removeAll()
        panel?.orderOut(nil)
        minimizedLauncher?.orderOut(nil)
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
            launcher.title = "WoW IDE Browser Restore"
            launcher.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            launcher.collectionBehavior = [.fullScreenAuxiliary]
            launcher.hidesOnDeactivate = false
            launcher.isOpaque = false
            launcher.backgroundColor = .clear
            launcher.hasShadow = true
            let control = DraggableRestoreView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
            control.symbol = "B"
            control.toolTip = "Click to restore browser; drag to move"
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
        releaseBrowserFocus()
        isMinimized = true
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
        isMinimized = false
        minimizedLauncher?.orderOut(nil)
    }

    func toggleMinimized() {
        if isMinimized { restore() }
        else { minimizePanel() }
    }
    @objc private func goBack() { activeTab?.browser.goBack() }
    @objc private func goForward() { activeTab?.browser.goForward() }
    @objc private func reloadPage() { activeTab?.browser.reload(ignoreCache: true) }
    @objc private func toggleDevToolsAction() { toggleDevTools() }
    @objc private func focusDevTools() {
        guard devToolsVisible, let panel, let tab = activeTab else { return }
        if keyboardReturnProcessID == nil { captureReturnTarget() }
        devToolsKeyboardFocus = true
        panel.allowsTextFocus = true
        panel.makeKey()
        if let native = tab.devToolsHost.subviews.first {
            panel.makeFirstResponder(native)
        }
    }
    @objc private func returnToGame() {
        pageTextEditing = false
        devToolsKeyboardFocus = false
        panel?.allowsTextFocus = false
        scheduleReturnToTarget()
    }
    @objc private func openAddress() {
        guard let addressField else { return }
        guard let url = Self.httpURL(addressField.stringValue) else {
            statusLabel?.stringValue = "Enter an HTTP or HTTPS URL"
            return
        }
        addressField.stringValue = url.absoluteString
        activeTab?.browser.load(url)
        panel?.makeFirstResponder(nil)
    }
    @objc private func changeViewport() {
        viewport = BrowserViewport(rawValue: viewportPicker?.indexOfSelectedItem ?? 0) ?? .desktop
        if let activeTab { applyViewport(to: activeTab) }
    }
    @objc private func newTabAction() { addTab(url: Self.startURL, select: true) }
    @objc private func selectTabAction(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        activateTab(tabs[sender.tag].id)
    }
    @objc private func closeTabAction(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        let tab = tabs.remove(at: sender.tag)
        tab.inspector?.close(force: true)
        tab.browser.close(force: true)
        tab.host.removeFromSuperview()
        tab.devToolsHost.removeFromSuperview()
        if tabs.isEmpty { addTab(url: Self.startURL, select: true) }
        else if tab.id == activeTabID { activateTab(tabs[min(sender.tag, tabs.count - 1)].id) }
        else { rebuildTabStrip() }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        panel?.allowsTextFocus = true
        if keyboardReturnProcessID == nil { captureReturnTarget() }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        panel?.allowsTextFocus = false
        scheduleReturnToTarget()
    }

    func browser(_ b: CefBrowser, didChangeURL url: URL?) {
        guard let url, let tab = tabs.first(where: { $0.browser === b }) else { return }
        if tab.id == activeTabID, addressField?.currentEditor() == nil {
            addressField?.stringValue = Self.isStartPage(url) ? "" : url.absoluteString
        }
        if Self.httpURL(url.absoluteString) != nil, url.scheme == "http" || url.scheme == "https" {
            UserDefaults.standard.set(url.absoluteString, forKey: BrowserStorage.lastURLKey)
        }
    }
    func browser(_ b: CefBrowser, didChangeTitle title: String) {
        guard let tab = tabs.first(where: { $0.browser === b }) else { return }
        tab.title = Self.isStartPage(b.url) ? "New tab" : (title.isEmpty ? (b.url?.host ?? "Tab") : title)
        rebuildTabStrip()
    }
    func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool,
                 canGoBack: Bool, canGoForward: Bool) {
        guard let tab = tabs.first(where: { $0.browser === b }) else { return }
        if tab.id == activeTabID {
            backButton?.isEnabled = canGoBack
            forwardButton?.isEnabled = canGoForward
            statusLabel?.stringValue = isLoading ? "Loading…" : (Self.isStartPage(b.url) ? "Enter a URL to begin" : "Chromium")
        }
        if !isLoading {
            b.executeJavaScript(Self.focusScript(for: b))
            applyViewport(to: tab)
        }
    }
    func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {
        if b === activeTab?.browser { statusLabel?.stringValue = "Load failed (\(code)): \(errorText)" }
    }
    func browser(_ b: CefBrowser, decidePolicyForNavigation url: URL?,
                 isRedirect: Bool, userGesture: Bool) -> CefNavigationDecision {
        guard let url else { return .cancel }
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "about" ||
            url.scheme == "blob" || url.scheme == "data" { return .allow }
        return .cancel
    }
    func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        guard let url = request.targetURL,
              url.scheme == "http" || url.scheme == "https" else { return .deny }
        if tabs.count < 8 {
            DispatchQueue.main.async { [weak self] in self?.addTab(url: url, select: true) }
        }
        else { b.load(url) }
        return .handled
    }
    func browserDidClose(_ b: CefBrowser) { /* Tab lifecycle is owned by this controller. */ }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
        if viewport == .responsive, let activeTab { applyViewport(to: activeTab) }
    }
    func windowDidResignKey(_ notification: Notification) {
        releaseBrowserFocus()
    }
}
