import Foundation

/// Settings live in this user's own defaults, never in the repository.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let sourceDisplay = "sourceDisplayKey"
        static let interval = "intervalSeconds"
        static let enabled = "syncEnabled"
        static let deadband = "deadband"
    }

    static let intervalChoices = [2, 5, 10, 30, 60]

    /// Identity of the display whose brightness the others follow. Nil means
    /// "whichever display macOS considers the main one".
    static var sourceDisplay: String? {
        get { defaults.string(forKey: Key.sourceDisplay) }
        set { defaults.set(newValue, forKey: Key.sourceDisplay) }
    }

    static var interval: Int {
        get { defaults.object(forKey: Key.interval) as? Int ?? 5 }
        set { defaults.set(newValue, forKey: Key.interval) }
    }

    static var isEnabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Ignore differences at or below this many points, so that rounding
    /// between panels with different ranges does not cause constant writes.
    static var deadband: Int {
        get { defaults.object(forKey: Key.deadband) as? Int ?? 1 }
        set { defaults.set(newValue, forKey: Key.deadband) }
    }
}
