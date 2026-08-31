import Foundation

/// Typed `UserDefaults`. One place for everything the user configures.
final class Preferences {
    private let defaults: UserDefaults

    /// What the retention fields will accept.
    ///
    /// The upper bound is a real budget, not a taste. Three things were written
    /// against a fixed ceiling of 1000 and now answer to whatever the user
    /// types: `AppEnvironment.runPrune` deletes rows and scans the blob
    /// directory **on the main thread**, `AutoTagger.items(matching:)` pulls up
    /// to `maxItems` rows through a regex in Swift, and the panel's search is a
    /// `LIKE` with no index. An unbounded number would freeze the app on launch,
    /// so the bound lives at the property every writer goes through rather than
    /// in the field that happens to edit it today.
    ///
    /// ponytail: 10k is roughly a decade of heavy clipboard use and still prunes
    /// in well under a frame here. Move the prune off the main thread and the
    /// search to FTS5 before raising it.
    static let itemLimits = 1...10_000
    static let ageLimits = 1...3_650

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the status item is in the menu bar at all. Absent means **true**.
    ///
    /// `object(forKey:)` and not `bool(forKey:)`: a key nobody ever wrote has to
    /// mean the behaviour the user already had, and `bool(forKey:)` answers
    /// `false` for an absent key — every existing install would launch with no
    /// icon and no visible sign the app is running at all.
    ///
    /// The key is shared, not private: `CorvoApp` binds `MenuBarExtra`'s
    /// `isInserted` to `@AppStorage("showsMenuBarIcon")`, which is what makes the
    /// icon appear and disappear without relaunching — and what records it when
    /// the icon is ⌘-dragged out of the menu bar instead of switched off here.
    /// `showsMenuBarIconKey` exists so the two sides cannot drift apart silently.
    static let showsMenuBarIconKey = "showsMenuBarIcon"

    var showsMenuBarIcon: Bool {
        get { defaults.object(forKey: Self.showsMenuBarIconKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showsMenuBarIconKey) }
    }

    /// Bundle ids whose clippings are never recorded — every line the Settings
    /// window's list holds, including any the user got wrong. `PasteboardMonitor`
    /// compares exact strings, so a line that is not a bundle id matches no app;
    /// `Blocklist` is what tells the screen which ones those are.
    var blocklist: [String] {
        get { defaults.stringArray(forKey: "blocklist") ?? [] }
        set { defaults.set(newValue, forKey: "blocklist") }
    }

    // The clamp runs on both read and write. The setter alone only bounds
    // values Corvo itself wrote; `AppEnvironment.start()` reads through the
    // getter on every launch, and a value that reached `UserDefaults` some
    // other way — `defaults write`, an MDM profile, a restored plist — has to
    // come back bounded from there too.
    var maxItems: Int {
        get {
            let v = defaults.integer(forKey: "maxItems")
            return v > 0 ? Self.clamped(v, to: Self.itemLimits) : RetentionPolicy.defaultMaxItems
        }
        set { defaults.set(Self.clamped(newValue, to: Self.itemLimits), forKey: "maxItems") }
    }

    var maxAgeDays: Int {
        get {
            let v = defaults.integer(forKey: "maxAgeDays")
            return v > 0 ? Self.clamped(v, to: Self.ageLimits) : RetentionPolicy.defaultMaxAgeDays
        }
        set { defaults.set(Self.clamped(newValue, to: Self.ageLimits), forKey: "maxAgeDays") }
    }

    /// Whether the count rule applies at all. Absent means **true**.
    ///
    /// `object(forKey:)` and not `defaults.bool(forKey:)`, and this is the whole
    /// upgrade story: `bool(forKey:)` answers `false` for a key nobody ever wrote,
    /// which would switch retention off for every existing user the first time
    /// they launched a build carrying this — no error, no visible symptom, and a
    /// database quietly growing without a ceiling. Absent has to mean the
    /// behaviour they already had.
    var limitsItems: Bool {
        get { defaults.object(forKey: "limitsItems") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "limitsItems") }
    }

    /// Whether the age rule applies at all. Absent means **true**, for the reason
    /// above.
    var limitsAge: Bool {
        get { defaults.object(forKey: "limitsAge") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "limitsAge") }
    }

    /// The four states the two switches make.
    ///
    /// Switching a rule off does not touch its number: the value the user chose is
    /// still there when they switch it back on, and is still what the dimmed field
    /// shows in the meantime.
    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(maxItems: limitsItems ? maxItems : nil,
                        maxAge: limitsAge ? Double(maxAgeDays) * 86400 : nil)
    }

    /// The global shortcut that opens the panel. `nil` means the user cleared it
    /// and there is no global shortcut — the menu bar item is then the only way
    /// in, which is a choice someone comparing Corvo against another clipboard
    /// manager has a real use for.
    ///
    /// Two traps live in these six lines, both of them in how `UserDefaults`
    /// answers for a value nobody ever wrote:
    ///
    /// - `kVK_ANSI_A` **is 0**, so `defaults.integer(forKey:)` cannot tell the
    ///   key A from a key that was never set. Absence is read with
    ///   `object(forKey:)` instead, and only absence falls back to `⌘⇧V`.
    /// - `modifiers == 0` is the marker for "cleared". `HotkeyRule` makes a
    ///   shortcut with no `⌘`/`⌥`/`⌃` unregisterable, so zero modifiers cannot
    ///   mean a real binding, which leaves it free to mean this and saves a
    ///   third key that could disagree with the other two.
    ///
    /// Validated on read as well as write, for the reason the retention limits
    /// are clamped on read: the setter only bounds what Corvo itself wrote, and
    /// a shortcut that arrived by `defaults write`, an MDM profile or a restored
    /// plist has to come back registerable from here too. A stored shift-only
    /// binding reads back as the default rather than as a shortcut that eats a
    /// letter in every app.
    var hotkey: Hotkey? {
        get {
            guard let code = defaults.object(forKey: "hotkeyKeyCode") as? Int,
                  (0...0xFFFF).contains(code) else { return .default }
            let modifiers = defaults.integer(forKey: "hotkeyModifiers")
            guard modifiers != 0 else { return nil }
            let stored = Hotkey(keyCode: UInt32(code), modifiers: UInt32(truncatingIfNeeded: modifiers))
            return HotkeyRule.isAcceptable(stored) ? stored : .default
        }
        set {
            // A rejected shortcut is stored as cleared rather than dropped: the
            // one thing that must not happen is a write that leaves the previous
            // binding in place while the caller believes it changed something.
            guard let hotkey = newValue, HotkeyRule.isAcceptable(hotkey) else {
                defaults.set(0, forKey: "hotkeyKeyCode")
                defaults.set(0, forKey: "hotkeyModifiers")
                return
            }
            defaults.set(Int(hotkey.keyCode), forKey: "hotkeyKeyCode")
            defaults.set(Int(hotkey.modifiers), forKey: "hotkeyModifiers")
        }
    }

    static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Locale {
    /// The locale everything Corvo *writes* is formatted in.
    ///
    /// Not the system locale, and deliberately not `preferredLocalizations`
    /// either: `Bundle.main.localizations` is `["pt-BR", "en"]` because a
    /// `pt-BR.lproj` exists holding one empty `InfoPlist.strings`, so on a pt-BR
    /// machine that answers `"pt-BR"` while the String Catalog has zero pt-BR
    /// translations and every word on screen is English. A screen that says
    /// "Keep at most 1.000 clippings" in an otherwise English app is formatting
    /// against a language it is not written in.
    ///
    /// SwiftUI re-resolves format styles against `\.environment(\.locale)`, so
    /// this has to be set on the view as well as on any format style — setting
    /// only the style leaves the bug in place. Found by rendering the screen,
    /// twice: once for dates in Task 11b, once for grouped numbers here.
    static let app = Locale(identifier: Bundle.main.developmentLocalization ?? "en")
}

/// The blocklist as the user types it, and as `PasteboardMonitor` reads it.
///
/// This is a privacy control, so its two failure modes are not equal. Silently
/// dropping a line the user meant is unsafe — they believe an app is blocked
/// and it is not. Keeping a line that can never match any app is merely
/// useless. So a line that is not a bundle id is handed back by name to be
/// shown, never swallowed, and the lines around it still apply: one typo must
/// not switch the whole list off.
enum Blocklist {
    /// Reverse-DNS, which is the shape `Bundle.bundleIdentifier` always has:
    /// two or more dot-separated segments of ASCII letters, digits, `-` or `_`.
    ///
    /// The point is not to police the user's spelling — it is that a string of
    /// any other shape cannot equal a real bundle id, so accepting it would be
    /// a promise Corvo has no way to keep.
    static func isValidBundleId(_ id: String) -> Bool {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy(isSegment)
    }

    private static func isSegment(_ s: Substring) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Every non-blank line, trimmed and de-duplicated, in the order it was
    /// typed — the ones that are not bundle ids included. This is what gets
    /// stored.
    ///
    /// Storing only the enforceable lines was the first version and it was
    /// wrong: the typo disappeared from the editor the next time the window
    /// opened, leaving the user believing an app was blocked with nothing left
    /// on screen to say otherwise. A stored line that is not a bundle id can
    /// never equal one, so it blocks nothing either way — the difference is
    /// only whether the warning about it is still there tomorrow.
    ///
    /// Blank lines are dropped rather than kept: those are the user pressing
    /// Return, not something they typed and got wrong.
    ///
    /// Split on `Character.isNewline`, not on the `Character` `"\n"` alone:
    /// `"\r\n"` is a single grapheme cluster in Swift, so splitting on `"\n"`
    /// let a CRLF-pasted list — from a web page, a wiki, anything not authored
    /// on this machine — collapse into one entry that matches no bundle id,
    /// silently switching off every block in it. `isNewline` also covers a bare
    /// `"\r"`.
    static func entries(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The same entries, split into the ones that will be enforced and the ones
    /// the screen has to warn about.
    static func parse(_ text: String) -> (accepted: [String], rejected: [String]) {
        let all = entries(text)
        return (all.filter(isValidBundleId), all.filter { !isValidBundleId($0) })
    }
}
