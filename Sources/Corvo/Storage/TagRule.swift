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

        guard let matched = Self.search(regex, in: text, pattern: pattern) else {
            // Ran out of time. A rule that cannot answer must not answer "yes":
            // tagging is not undoable and a timeout says nothing about content.
            return false
        }
        return matched
    }

    // ponytail: only the first 8 KB of the text is matched. This runs on every
    // capture against every rule, inside a poller that fires every 0.3s, and a
    // regex over a multi-megabyte paste would stall it. The ceiling: a pattern
    // that would only match past the cut is missed. Upgrade: move matching off
    // the main actor and apply the tags asynchronously.
    private static let matchLimit = 8_192

    /// How long a single pattern may run against a single text before it is
    /// abandoned.
    ///
    /// Calibration, not a magic number. The floor is set by legitimate work:
    /// every non-pathological pattern measured against the full 8 KB window
    /// finished in under 0,001 s, so 0,05 s is fifty times the honest cost. The
    /// ceiling is set by the poller: it fires every 0,3 s and evaluates one
    /// budget per rule, so a handful of rules that all give up still leaves the
    /// tick inside its interval. Lower it if a user's rule list ever grows past
    /// a few, raise it only with a measurement in hand.
    private static let matchBudget: TimeInterval = 0.05

    /// `firstMatch` with a real time limit.
    ///
    /// `NSRegularExpression` exposes no timeout, but `enumerateMatches` with
    /// `.reportProgress` calls back periodically *during* a match — including
    /// deep inside catastrophic backtracking — and honours `stop` there. That
    /// callback is the whole fix: it makes the abandonment cooperative, on this
    /// thread, with no second thread left spinning behind it.
    ///
    /// Returns `nil` when the budget ran out.
    ///
    /// The pattern is the user's, but the text is whatever any app put on the
    /// pasteboard, and that asymmetry is what makes an accidentally exponential
    /// pattern — `^(\s+)+\S`, say — a permanent freeze rather than a slow tick.
    /// Measured before this guard: `(a+)+$` against 30 characters took 46 s, and
    /// 40 characters would have taken hours.
    private static func search(_ regex: NSRegularExpression, in text: String,
                               pattern: String) -> Bool? {
        // A pattern that has already blown the budget once is not asked again.
        // Without this the editor's preview and the retroactive apply would pay
        // the budget per item — a thousand rows is a thousand timeouts — and the
        // poller would pay it on every capture, forever.
        if timedOut.object(forKey: pattern as NSString) != nil { return nil }

        let haystack = String(text.prefix(matchLimit))
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        let deadline = Date().addingTimeInterval(matchBudget)
        var found = false
        var expired = false

        regex.enumerateMatches(in: haystack, options: [.reportProgress], range: range) {
            result, flags, stop in
            if result != nil {
                found = true
                stop.pointee = true
                return
            }
            guard flags.contains(.progress), Date() > deadline else { return }
            expired = true
            stop.pointee = true
        }

        guard expired else { return found }
        timedOut.setObject(NSNumber(value: true), forKey: pattern as NSString)
        NSLog("Corvo: tag pattern abandoned after \(matchBudget)s and disabled for this run: \(pattern)")
        return nil
    }

    /// Patterns that exhausted the budget. Same reasoning as `cache` for the
    /// choice of `NSCache`: thread-safe on its own, bounded without a policy.
    ///
    /// ponytail: only lives as long as the process, and the user is told nothing
    /// beyond the `NSLog`. A pattern the editor accepted but that turns out to
    /// be pathological on real text stops matching in silence. Upgrade: persist
    /// the fact and surface it as "the rule X was disabled for taking too long".
    nonisolated(unsafe) private static let timedOut = NSCache<NSString, NSNumber>()

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

    /// Why the editor refuses a pattern. Two reasons, because they need two
    /// different sentences: one is a typo, the other is a shape.
    enum PatternProblem {
        /// Does not compile.
        case malformed
        /// Compiles, but blew `matchBudget` on a probe — the pattern is
        /// exponential in the length of the text and would freeze the poller.
        case tooSlow
    }

    /// Strings built to make a backtracking pattern do its worst: a long run of
    /// one repeated character, which is what forces the engine to retry every
    /// partition of the run.
    ///
    /// The alphabet comes from the pattern itself, and it has to: the run must
    /// be something the pattern's inner quantifier will actually consume, and a
    /// fixed alphabet of `a`, `1` and space never triggers `(d+)+$`. Taking the
    /// pattern's own letters, digits and blanks costs nothing and covers the
    /// literals people write.
    ///
    /// Two shapes per character, because the two families fail differently: a
    /// bare run defeats a pattern that needs one more character after it
    /// (`^(\s+)+\S`), and a run followed by a character it cannot consume
    /// defeats an anchored one (`(a+)+$`).
    ///
    /// 40 is past the knee: `(a+)+$` measured 46 s at 30 characters and doubles
    /// per character, so anything exponential is far beyond the budget here
    /// while anything linear stays in microseconds.
    private static func probes(for pattern: String) -> [String] {
        var alphabet: Set<Character> = ["a", "1", " "]
        alphabet.formUnion(pattern.filter { $0.isLetter || $0.isNumber || $0 == " " })
        return alphabet.flatMap { character -> [String] in
            let run = String(repeating: character, count: 40)
            return [run, run + "!"]
        }
    }

    /// What is wrong with a pattern the user is typing, or `nil` for a pattern
    /// the matcher will accept. The editor asks this so a rule can never be
    /// saved that the poller would go on to drop in silence.
    ///
    /// ponytail: the cost check runs the pattern against degenerate strings, it
    /// does not analyse it. Parsing the regex to find quantified nesting would
    /// be exact and is a parser nobody needs — the probes catch the shapes
    /// people actually type, and `matchBudget` in `search` is the real guarantee
    /// for whatever they miss. Measured: catches `(a+)+$`, `(d+)+$`, `(x+x+)+y`,
    /// `^(\s+)+\S` and `(\w+\s?)+KEY`, and costs 0,0000 s on every legitimate
    /// pattern tried. The ceiling: a pattern exponential only on characters it
    /// never mentions saves fine, and then costs one abandoned match per run.
    static func problem(with pattern: String) -> PatternProblem? {
        guard let regex = regex(for: pattern) else { return .malformed }
        for probe in probes(for: pattern) where search(regex, in: probe, pattern: pattern) == nil {
            return .tooSlow
        }
        return nil
    }

    static func isValid(pattern: String) -> Bool { problem(with: pattern) == nil }

    private static func regex(for pattern: String) -> NSRegularExpression? {
        if let cached = cache.object(forKey: pattern as NSString) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache.setObject(compiled, forKey: pattern as NSString)
        return compiled
    }
}
