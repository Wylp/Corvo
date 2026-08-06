import Foundation
import Testing
@testable import Corvo

@Test func aRuleWithNeitherFieldIsInactiveAndNeverMatches() {
    let rule = TagRule(pattern: nil, sourceBundleId: nil)
    #expect(rule.isActive == false)
    #expect(rule.matches(text: "anything at all", sourceBundleId: "com.apple.Safari") == false)
}

@Test func aPatternRuleSearchesInsideTheTextRatherThanMatchingTheWholeLine() {
    let rule = TagRule(pattern: "TODO", sourceBundleId: nil)
    #expect(rule.isActive)
    #expect(rule.matches(text: "a TODO in the middle of the sentence", sourceBundleId: nil))
    #expect(rule.matches(text: "nothing to do here", sourceBundleId: nil) == false)
}

@Test func aSourceRuleComparesTheBundleIdExactlyAndIgnoringCase() {
    let rule = TagRule(pattern: nil, sourceBundleId: "com.figma.Desktop")
    #expect(rule.matches(text: nil, sourceBundleId: "com.figma.desktop"))
    #expect(rule.matches(text: nil, sourceBundleId: "COM.FIGMA.DESKTOP"))
    // Exact, not a prefix or a substring.
    #expect(rule.matches(text: nil, sourceBundleId: "com.figma.Desktop.helper") == false)
    #expect(rule.matches(text: nil, sourceBundleId: nil) == false)
}

/// Copying an image out of Figma with a "everything from Figma" rule has to
/// tag it, and an image carries no text to match against.
@Test func anItemWithNoTextStillMatchesASourceOnlyRule() {
    #expect(TagRule(pattern: nil, sourceBundleId: "com.figma.Desktop")
        .matches(text: nil, sourceBundleId: "com.figma.Desktop"))
    #expect(TagRule(pattern: "TODO", sourceBundleId: nil)
        .matches(text: nil, sourceBundleId: "com.figma.Desktop") == false)
}

@Test func bothFieldsSetRequireBoth() {
    let rule = TagRule(pattern: "SELECT", sourceBundleId: "com.apple.Terminal")
    #expect(rule.matches(text: "SELECT 1", sourceBundleId: "com.apple.Terminal"))
    #expect(rule.matches(text: "SELECT 1", sourceBundleId: "com.apple.Safari") == false)
    #expect(rule.matches(text: "DROP TABLE", sourceBundleId: "com.apple.Terminal") == false)
}

/// The pattern is typed by hand, and the poller that evaluates it fires every
/// 0.3 seconds. A pattern that does not compile has to answer "no match" and
/// keep going — throwing here would end clipboard capture for good.
@Test func anInvalidPatternNeverMatchesAndNeverThrows() {
    for broken in ["[unclosed", "(unclosed", "*", "\\"] {
        let rule = TagRule(pattern: broken, sourceBundleId: nil)
        #expect(rule.isActive)
        #expect(rule.matches(text: "[unclosed", sourceBundleId: nil) == false)
    }
}

/// An invalid pattern paired with a source that does match still has to come
/// back false: the broken half must not be skipped just because the other half
/// passed.
@Test func anInvalidPatternAlsoFailsWhenTheSourceMatches() {
    let rule = TagRule(pattern: "[unclosed", sourceBundleId: "com.apple.Terminal")
    #expect(rule.matches(text: "anything", sourceBundleId: "com.apple.Terminal") == false)
}

@Test func matchingIsCaseSensitiveForThePatternUnlessTheUserAsksOtherwise() {
    #expect(TagRule(pattern: "TODO", sourceBundleId: nil)
        .matches(text: "todo", sourceBundleId: nil) == false)
    // The user has the whole regex language for this; nothing is smuggled in.
    #expect(TagRule(pattern: "(?i)TODO", sourceBundleId: nil)
        .matches(text: "todo", sourceBundleId: nil))
}

/// Guards the truncation ceiling in both directions: a hit inside the window is
/// found, and a hit past it is knowingly missed rather than accidentally found.
@Test func matchingIsTruncatedToTheDocumentedCeiling() {
    let rule = TagRule(pattern: "needle", sourceBundleId: nil)
    let filler = String(repeating: "x", count: 8_000)
    #expect(rule.matches(text: filler + "needle", sourceBundleId: nil))

    let beyond = String(repeating: "x", count: 9_000)
    #expect(rule.matches(text: beyond + "needle", sourceBundleId: nil) == false)
}

/// The compiled regex is cached by pattern text; a second evaluation of the
/// same rule must not start answering differently.
@Test func aCachedPatternKeepsAnsweringTheSame() {
    let rule = TagRule(pattern: "cached-\\d+", sourceBundleId: nil)
    #expect(rule.matches(text: "cached-1", sourceBundleId: nil))
    #expect(rule.matches(text: "cached-2", sourceBundleId: nil))
    #expect(rule.matches(text: "cached-none", sourceBundleId: nil) == false)
}

// MARK: - Catastrophic backtracking

/// The pattern is the user's, but the text is whatever any app put on the
/// pasteboard. `(a+)+$` against 28 characters of "a" measured 11,6 s on the
/// unguarded matcher, doubling per added character — 35 characters froze the app
/// for good, with Force Quit the only way out.
///
/// One second is not the target, it is the headroom: the budget is 0,05 s and
/// this leaves twenty times that for a loaded machine. 28 characters rather than
/// the 40 that make the point, because a regression has to *fail* this test in
/// twelve seconds rather than hang the suite for thirteen hours.
@Test func aPatternThatBacktracksCatastrophicallyIsAbandonedRatherThanRun() {
    let rule = TagRule(pattern: "(a+)+$", sourceBundleId: nil)
    let hostile = String(repeating: "a", count: 28) + "!"

    let started = Date()
    let matched = rule.matches(text: hostile, sourceBundleId: nil)
    let elapsed = Date().timeIntervalSince(started)

    #expect(elapsed < 1)
    // Abandoned means "no", never "yes": tagging has no undo in this app, and a
    // timeout says nothing whatsoever about what the clipping contains.
    #expect(matched == false)
}

/// Whitespace at the start of a copied snippet is one of the most ordinary
/// things there is, and `^(\s+)+\S` is a pattern someone writes meaning
/// "anything indented". It is exponential, and nothing about it looks dangerous
/// to the person typing it — which is the argument for the budget existing at
/// all, rather than trusting the user's own pattern.
///
/// The blanks are deliberately not followed by anything: the failing case is
/// what backtracks. Whitespace *and then* a visible character matches on the
/// first try and costs nothing, so a probe shaped that way would prove nothing.
/// Bare, this measured 5,4 s at 28 characters on the unguarded matcher.
@Test func anAccidentallyExponentialPatternIsAlsoAbandoned() {
    let rule = TagRule(pattern: "^(\\s+)+\\S", sourceBundleId: nil)
    let started = Date()
    let matched = rule.matches(text: String(repeating: " ", count: 28), sourceBundleId: nil)
    #expect(Date().timeIntervalSince(started) < 1)
    #expect(matched == false)
}

/// The budget must not cost the ordinary case anything. These are the patterns
/// the feature exists for, run against the full 8 KB window.
@Test func ordinaryPatternsStillMatchAndStayFast() {
    let text = String(repeating: "x", count: 8_000) + " TODO: ship it"
    let started = Date()
    #expect(TagRule(pattern: "TODO|FIXME", sourceBundleId: nil)
        .matches(text: text, sourceBundleId: nil))
    #expect(TagRule(pattern: "^https?://", sourceBundleId: nil)
        .matches(text: "https://example.com", sourceBundleId: nil))
    #expect(TagRule(pattern: "\\.pem$", sourceBundleId: nil)
        .matches(text: "id_rsa.pem", sourceBundleId: nil))
    #expect(Date().timeIntervalSince(started) < 1)
}

/// A pattern that blew the budget once is not asked again. Without this the
/// editor's preview and the retroactive apply would pay it per item — a
/// thousand rows is a thousand timeouts, which is fifty seconds of frozen UI.
@Test func aPatternThatBlewTheBudgetIsNotRetriedPerItem() {
    let rule = TagRule(pattern: "(c+)+$", sourceBundleId: nil)
    let hostile = String(repeating: "c", count: 28) + "!"
    _ = rule.matches(text: hostile, sourceBundleId: nil)

    let started = Date()
    for _ in 0..<200 { _ = rule.matches(text: hostile, sourceBundleId: nil) }
    // 200 fresh budgets would be ten seconds; short-circuited they are free.
    #expect(Date().timeIntervalSince(started) < 0.5)
}

// MARK: - What the editor refuses

/// Compiling says nothing about cost — every pathological pattern measured
/// compiles fine. The editor has to tell the two apart because they need two
/// different sentences.
@Test func theEditorTellsAnUnrunnablePatternApartFromAMalformedOne() {
    #expect(TagRule.problem(with: "[unclosed") == .malformed)
    #expect(TagRule.problem(with: "(d+)+$") == .tooSlow)
    #expect(TagRule.problem(with: "^(\\s+)+\\S") == .tooSlow)
    #expect(TagRule.problem(with: "TODO|FIXME") == nil)
    #expect(TagRule.problem(with: "^https?://") == nil)
}

/// `isValid` is what the editor's save button reads, and it has to refuse both.
@Test func aPatternTheMatcherWouldAbandonCannotBeSaved() {
    #expect(TagRule.isValid(pattern: "(e+)+$") == false)
    #expect(TagRule.isValid(pattern: "[unclosed") == false)
    #expect(TagRule.isValid(pattern: "\\bTODO\\b"))
}
