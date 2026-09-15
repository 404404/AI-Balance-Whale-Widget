import Foundation

final class AppPreferences {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let codexPath = "codexExecutablePath"
        static let codexHome = "codexHome"
        static let scale = "whaleScale"
        static let sound = "soundEnabled"
        static let mousePassthrough = "mousePassthrough"
        static let alwaysOnTop = "alwaysOnTop"
        static let allSpaces = "allSpaces"
        static let launchAtLogin = "launchAtLogin"
        static let position = "whalePosition"
        static let size = "whaleSize"
        static let snapEnabled = "snapEnabled"
        static let showMenuButton = "showMenuButton"
        static let bubbleCloseAfterSeconds = "bubbleCloseAfterSeconds"
    }

    var codexPath: String {
        get { defaults.string(forKey: Key.codexPath) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.codexPath) }
    }

    var codexHome: String {
        get { defaults.string(forKey: Key.codexHome) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.codexHome) }
    }

    var scale: Double {
        get {
            let value = defaults.object(forKey: Key.scale) as? Double ?? 1
            return min(max(value, WhaleLayout.minimumScale), WhaleLayout.maximumScale)
        }
        set { defaults.set(min(max(newValue, WhaleLayout.minimumScale), WhaleLayout.maximumScale), forKey: Key.scale) }
    }

    var soundEnabled: Bool {
        get { defaults.object(forKey: Key.sound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.sound) }
    }

    var mousePassthrough: Bool {
        get { defaults.bool(forKey: Key.mousePassthrough) }
        set { defaults.set(newValue, forKey: Key.mousePassthrough) }
    }

    var alwaysOnTop: Bool {
        get { defaults.bool(forKey: Key.alwaysOnTop) }
        set { defaults.set(newValue, forKey: Key.alwaysOnTop) }
    }

    var allSpaces: Bool {
        get { defaults.bool(forKey: Key.allSpaces) }
        set { defaults.set(newValue, forKey: Key.allSpaces) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var snapEnabled: Bool {
        get { defaults.object(forKey: Key.snapEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.snapEnabled) }
    }

    var showMenuButton: Bool {
        get { defaults.object(forKey: Key.showMenuButton) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showMenuButton) }
    }

    var bubbleCloseAfterSeconds: Int {
        get { max(0, defaults.object(forKey: Key.bubbleCloseAfterSeconds) as? Int ?? 0) }
        set { defaults.set(max(0, newValue), forKey: Key.bubbleCloseAfterSeconds) }
    }

    func saveFrame(_ frame: CGRect) {
        defaults.set([frame.origin.x, frame.origin.y, frame.size.width, frame.size.height], forKey: Key.position)
    }

    func savedFrame() -> CGRect? {
        guard let values = defaults.array(forKey: Key.position) as? [Double], values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    func resetLayout() {
        defaults.removeObject(forKey: Key.position)
        defaults.removeObject(forKey: Key.size)
    }
}
