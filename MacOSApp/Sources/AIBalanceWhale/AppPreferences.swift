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
            return min(max(value, 0.65), 1.6)
        }
        set { defaults.set(min(max(newValue, 0.65), 1.6), forKey: Key.scale) }
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

    func saveFrame(_ frame: CGRect) {
        defaults.set([frame.origin.x, frame.origin.y, frame.size.width, frame.size.height], forKey: Key.position)
    }

    func savedFrame() -> CGRect? {
        guard let values = defaults.array(forKey: Key.position) as? [Double], values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
