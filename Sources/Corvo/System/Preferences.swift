import Foundation

/// `UserDefaults` tipado. Um lugar só para tudo que o usuário configura.
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
            return v > 0 ? v : RetentionPolicy.padrao.maxItems
        }
        set { defaults.set(newValue, forKey: "maxItems") }
    }

    var maxAgeDias: Int {
        get {
            let v = defaults.integer(forKey: "maxAgeDias")
            return v > 0 ? v : 30
        }
        set { defaults.set(newValue, forKey: "maxAgeDias") }
    }

    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(maxItems: maxItems, maxAge: Double(maxAgeDias) * 86400)
    }
}
