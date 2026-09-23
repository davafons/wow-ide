import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private weak var opacityPicker: NSPopUpButton?
    private weak var fontField: NSTextField?
    private weak var terminalDirectoryField: NSTextField?
    private weak var agentDirectoryField: NSTextField?
    private weak var shortcutPicker: NSPopUpButton?
    private weak var loginCheckbox: NSButton?

    func show() {
        if window == nil { createWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WoW IDE Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.xPlacement = .fill

        let opacity = NSPopUpButton()
        opacity.addItems(withTitles: PanelOpacityPreset.allCases.map(\.title))
        opacity.selectItem(at: PanelOpacityPreset.allCases.firstIndex(of: AppPreferences.opacity) ?? 0)
        opacity.target = self
        opacity.action = #selector(opacityChanged)
        opacityPicker = opacity

        let font = NSTextField(string: String(format: "%.0f", AppPreferences.terminalFontSize))
        font.delegate = self
        fontField = font

        let terminalDirectory = NSTextField(string: AppPreferences.terminalWorkingDirectory)
        terminalDirectory.delegate = self
        terminalDirectoryField = terminalDirectory
        let terminalChoose = NSButton(title: "Choose…", target: self, action: #selector(chooseTerminalDirectory))

        let agentDirectory = NSTextField(string: AppPreferences.agentWorkingDirectory)
        agentDirectory.delegate = self
        agentDirectoryField = agentDirectory
        let agentChoose = NSButton(title: "Choose…", target: self, action: #selector(chooseAgentDirectory))

        let shortcuts = NSPopUpButton()
        shortcuts.addItems(withTitles: ShortcutPreset.allCases.map(\.title))
        shortcuts.selectItem(at: ShortcutPreset.allCases.firstIndex(of: AppPreferences.shortcutPreset) ?? 0)
        shortcuts.target = self
        shortcuts.action = #selector(shortcutsChanged)
        shortcutPicker = shortcuts

        let targetButton = NSButton(title: "Choose…", target: self, action: #selector(chooseTarget))
        let login = NSButton(checkboxWithTitle: "Launch WoW IDE when I log in", target: self,
                             action: #selector(toggleStartAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginCheckbox = login

        grid.addRow(with: [label("Panel appearance"), opacity])
        grid.addRow(with: [label("Terminal font size"), font])
        grid.addRow(with: [label("Terminal directory"), directoryRow(terminalDirectory, terminalChoose)])
        grid.addRow(with: [label("Codex directory"), directoryRow(agentDirectory, agentChoose)])
        grid.addRow(with: [label("Target application"), targetButton])
        grid.addRow(with: [label("Global shortcuts"), shortcuts])
        grid.addRow(with: [label("Startup"), login])

        let reset = NSButton(title: "Reset Panel Layout", target: self, action: #selector(resetLayout))
        reset.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(reset)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            reset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            reset.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 24)
        ])
        window.contentView = content
        self.window = window
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .left
        return field
    }

    private func directoryRow(_ field: NSTextField, _ button: NSButton) -> NSView {
        let row = NSStackView(views: [field, button])
        row.orientation = .horizontal
        row.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func opacityChanged() {
        guard let index = opacityPicker?.indexOfSelectedItem,
              PanelOpacityPreset.allCases.indices.contains(index) else { return }
        AppPreferences.opacity = PanelOpacityPreset.allCases[index]
        notifyChange()
    }

    @objc private func shortcutsChanged() {
        guard let index = shortcutPicker?.indexOfSelectedItem,
              ShortcutPreset.allCases.indices.contains(index) else { return }
        AppPreferences.shortcutPreset = ShortcutPreset.allCases[index]
        notifyChange()
    }

    @objc private func chooseTarget() {
        NotificationCenter.default.post(name: .wowIDEChooseTarget, object: nil)
    }

    @objc private func toggleStartAtLogin() {
        do {
            if loginCheckbox?.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginCheckbox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSLog("WoW IDE: Start at Login failed: %@", error.localizedDescription)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === fontField {
            AppPreferences.terminalFontSize = fontField?.doubleValue ?? 14
            fontField?.stringValue = String(format: "%.0f", AppPreferences.terminalFontSize)
        } else if notification.object as? NSTextField === terminalDirectoryField {
            AppPreferences.terminalWorkingDirectory = terminalDirectoryField?.stringValue ?? NSHomeDirectory()
        } else if notification.object as? NSTextField === agentDirectoryField {
            AppPreferences.agentWorkingDirectory = agentDirectoryField?.stringValue ?? NSHomeDirectory()
        }
        notifyChange()
    }

    @objc private func chooseTerminalDirectory() { chooseDirectory(for: terminalDirectoryField, terminal: true) }
    @objc private func chooseAgentDirectory() { chooseDirectory(for: agentDirectoryField, terminal: false) }

    private func chooseDirectory(for field: NSTextField?, terminal: Bool) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = URL(fileURLWithPath: field?.stringValue ?? NSHomeDirectory())
        guard picker.runModal() == .OK, let path = picker.url?.path else { return }
        field?.stringValue = path
        if terminal { AppPreferences.terminalWorkingDirectory = path }
        else { AppPreferences.agentWorkingDirectory = path }
        notifyChange()
    }

    @objc private func resetLayout() {
        NotificationCenter.default.post(name: .wowIDEResetLayout, object: nil)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .wowIDEPreferencesChanged, object: nil)
    }
}
