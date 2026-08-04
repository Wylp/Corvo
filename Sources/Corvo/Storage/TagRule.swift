import Foundation

/// The condition a tag carries. A tag with neither field set is an ordinary
/// manual tag and never matches anything; with either field set it applies
/// itself to every capture that satisfies it.
///
/// Deliberately a plain value — no GRDB, no AppKit — so the matching rules can
/// be tested without a database and without a pasteboard.
struct TagRule: Equatable {
    /// A regular expression searched inside the item's text. Typed by hand by
    /// the user, so it is never assumed to compile.
    var pattern: String?
    /// Compared exactly against the item's source app, ignoring case.
    var sourceBundleId: String?

    var isActive: Bool { pattern != nil || sourceBundleId != nil }

    /// Both fields set means both must hold. An inactive rule never matches.
    func matches(text: String?, sourceBundleId: String?) -> Bool {
        guard isActive else { return false }

        if let wanted = self.sourceBundleId {
            guard let actual = sourceBundleId,
                  actual.compare(wanted, options: .caseInsensitive) == .orderedSame
            else { return false }
        }

        // Source-only rule: an item with no text still matches, which is how
        // "everything from Figma" tags a copied image.
        guard let pattern else { return true }
        guard let regex = Self.regex(for: pattern), let text else { return false }

        let haystack = String(text.prefix(Self.matchLimit))
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    // ponytail: only the first 8 KB of the text is matched. This runs on every
    // capture against every rule, inside a poller that fires every 0.3s, and a
    // regex over a multi-megabyte paste would stall it. The ceiling: a pattern
    // that would only match past the cut is missed. Upgrade: move matching off
    // the main actor and apply the tags asynchronously.
    private static let matchLimit = 8_192

    /// `nil` for a pattern that does not compile — a rule the user typed wrong
    /// simply stops matching. Throwing here would kill the poller and with it
    /// every future capture.
    ///
    /// ponytail: `NSCache` is the whole cache. Keys are pattern texts, which
    /// come from the tag table, so the count is however many rules the user
    /// made — tens. It is thread-safe on its own, which is why there is no lock
    /// here. Swap for an explicit LRU only if rules ever arrive from somewhere
    /// unbounded.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSRegularExpression>()

    /// Whether a pattern the user is typing would compile. The same call the
    /// matcher makes, so the editor can never accept a pattern the poller would
    /// go on to drop in silence.
    static func isValid(pattern: String) -> Bool { regex(for: pattern) != nil }

    private static func regex(for pattern: String) -> NSRegularExpression? {
        if let cached = cache.object(forKey: pattern as NSString) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache.setObject(compiled, forKey: pattern as NSString)
        return compiled
    }
}
