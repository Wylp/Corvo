import Foundation

/// Typed `UserDefaults`. One place for everything the user configures.
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var blocklist: [String] {
        get { defaults.stringArray(forKey: "blocklist") ?? [] }
        set { defaults.set(newValue, forKey: "blocklist") }
    }

    var maxItems: Int {
        get {
            let v = defaults.integer(forKey: "maxItems")
            return v > 0 ? v : RetentionPolicy.standard.maxItems
        }
        set { defaults.set(newValue, forKey: "maxItems") }
    }

    var maxAgeDays: Int {
        get {
            let v = defaults.integer(forKey: "maxAgeDays")
            return v > 0 ? v : Int(RetentionPolicy.standard.maxAge / 86400)
        }
        set { defaults.set(newValue, forKey: "maxAgeDays") }
    }

    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(maxItems: maxItems, maxAge: Double(maxAgeDays) * 86400)
    }
}
