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
            return v > 0 ? Self.clamped(v, to: Self.itemLimits) : RetentionPolicy.standard.maxItems
        }
        set { defaults.set(Self.clamped(newValue, to: Self.itemLimits), forKey: "maxItems") }
    }

    var maxAgeDays: Int {
        get {
            let v = defaults.integer(forKey: "maxAgeDays")
            return v > 0 ? Self.clamped(v, to: Self.ageLimits) : Int(RetentionPolicy.standard.maxAge / 86400)
        }
        set { defaults.set(Self.clamped(newValue, to: Self.ageLimits), forKey: "maxAgeDays") }
    }

    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(maxItems: maxItems, maxAge: Double(maxAgeDays) * 86400)
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
