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
