import AppKit

enum PanelOpacityPreset: String, CaseIterable {
    case clear
    case balanced
    case solid

    var title: String {
        switch self {
        case .clear: "Clear"
        case .balanced: "Balanced"
        case .solid: "Solid"
        }
    }

    /// A dark tint placed above the system material and behind panel content.
    var tintAlpha: CGFloat {
        switch self {
        case .clear: 0.04
        case .balanced: 0.20
        case .solid: 0.58
        }
    }
}

enum ShortcutPreset: String, CaseIterable {
    case commandLetters
    case controlOptionNumbers

    var title: String {
        switch self {
        case .commandLetters: "⌘R / ⌘F / ⌘D"
        case .controlOptionNumbers: "⌃⌥1 / ⌃⌥2 / ⌃⌥3"
        }
    }
}

enum AppPreferenceKey {
    static let panelOpacity = "panelOpacityPreset"
    static let terminalFontSize = "terminalFontSize"
    static let terminalWorkingDirectory = "terminalWorkingDirectory"
    static let agentWorkingDirectory = "agentWorkingDirectory"
    static let codexVisible = "codexPanelVisible"
    static let codexThreadID = "codexThreadID"
    static let shortcutPreset = "shortcutPreset"
}

enum AppPreferences {
    static var opacity: PanelOpacityPreset {
        get {
            UserDefaults.standard.string(forKey: AppPreferenceKey.panelOpacity)
                .flatMap(PanelOpacityPreset.init(rawValue:)) ?? .clear
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.panelOpacity) }
    }

    static var terminalFontSize: Double {
        get {
            let value = UserDefaults.standard.double(forKey: AppPreferenceKey.terminalFontSize)
            return value == 0 ? 14 : min(max(value, 9), 28)
        }
        set { UserDefaults.standard.set(min(max(newValue, 9), 28), forKey: AppPreferenceKey.terminalFontSize) }
    }

    static var terminalWorkingDirectory: String {
        get { validDirectory(for: AppPreferenceKey.terminalWorkingDirectory) ?? NSHomeDirectory() }
        set { UserDefaults.standard.set(newValue, forKey: AppPreferenceKey.terminalWorkingDirectory) }
    }

    static var agentWorkingDirectory: String {
        get { validDirectory(for: AppPreferenceKey.agentWorkingDirectory) ?? NSHomeDirectory() }
        set { UserDefaults.standard.set(newValue, forKey: AppPreferenceKey.agentWorkingDirectory) }
    }

    static var shortcutPreset: ShortcutPreset {
        get {
            UserDefaults.standard.string(forKey: AppPreferenceKey.shortcutPreset)
                .flatMap(ShortcutPreset.init(rawValue:)) ?? .commandLetters
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.shortcutPreset) }
    }

    private static func validDirectory(for key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory) && isDirectory.boolValue
            ? value : nil
    }
}

extension Notification.Name {
    static let wowIDEPreferencesChanged = Notification.Name("WoWIDEPreferencesChanged")
    static let wowIDEResetLayout = Notification.Name("WoWIDEResetLayout")
    static let wowIDEChooseTarget = Notification.Name("WoWIDEChooseTarget")
}

@MainActor
func applyPanelAppearance(to view: NSVisualEffectView) {
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(AppPreferences.opacity.tintAlpha).cgColor
}
