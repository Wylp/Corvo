import Testing
@testable import Corvo

/// The gate on writing a tag, now that two screens ask it.
///
/// It was `canSave` inside `TagEditor` and nothing could ask it a question. The
/// panel's tag sheet needs the same answer for a button it draws itself, and two
/// copies of a uniqueness rule is how "Work" and "Work " both end up in a table
/// with a unique index on the name.
private func tag(_ name: String, id: Int64? = nil, pattern: String? = nil) -> Corvo.Tag {
    Corvo.Tag(id: id, name: name, color: nil, pattern: pattern, sourceBundleId: nil)
}

@Test func aDraftNeedsAName() {
    #expect(!TagDraft.canSave(tag(""), among: []))
    #expect(TagDraft.canSave(tag("Work"), among: []))
}

/// Whitespace is the case the trim exists for: the stored name is trimmed, so a
/// draft of "   " looks like a filled field and would write an empty tag.
@Test func whitespaceIsNotAName() {
    #expect(!TagDraft.canSave(tag("   "), among: []))
    #expect(!TagDraft.canSave(tag("\n\t "), among: []))
}

/// The unique index would turn this into a constraint failure on write. The
/// comparison is against the *trimmed* draft, because that is what gets stored —
/// checking the raw field would let "Work " through to fail later.
@Test func aNameAlreadyTakenIsRefused() {
    let existing = [tag("Work", id: 1)]
    #expect(!TagDraft.canSave(tag("Work"), among: existing))
    #expect(!TagDraft.canSave(tag("  Work  "), among: existing))
    #expect(TagDraft.canSave(tag("Works"), among: existing))
}

/// Editing a tag is not a collision with itself. Without the id comparison,
/// opening any stored tag and changing its colour would refuse to save.
@Test func aTagDoesNotCollideWithItself() {
    let existing = [tag("Work", id: 1)]
    #expect(TagDraft.canSave(tag("Work", id: 1), among: existing))
}

/// Case matters here on purpose, and it is not an oversight worth "fixing" in
/// this rule: the store compares exact strings, so "work" really is a second
/// tag. What catches it is the search beside the field, not this.
@Test func theComparisonIsExact() {
    #expect(TagDraft.canSave(tag("work"), among: [tag("Work", id: 1)]))
}

/// An empty pattern is a tag with no rule, not a broken one.
@Test func noPatternIsNotABadPattern() {
    #expect(TagDraft.canSave(tag("Work", pattern: nil), among: []))
    #expect(TagDraft.canSave(tag("Work", pattern: ""), among: []))
}

@Test func aBrokenPatternBlocksTheSave() {
    #expect(!TagDraft.canSave(tag("Work", pattern: "[unclosed"), among: []))
}

/// The pattern that compiles and then runs for hours is refused by the same
/// gate as the one that does not compile. Both are `TagRule.problem`.
@Test func aCatastrophicPatternBlocksTheSave() {
    #expect(!TagDraft.canSave(tag("Work", pattern: "(a+)+$"), among: []))
}

// MARK: - The sheet's filter

/// The Auto/Manual filter splits on the same property the tag strip and the
/// manager's list already draw a bolt for, so all three agree by construction.
@Test func theKindFilterSplitsOnWhetherATagAppliesItself() {
    let manual = tag("Work")
    let auto = tag("Tokens", pattern: "token-[a-z]+")
    #expect(auto.rule.isActive)
    #expect(!manual.rule.isActive)

    #expect(HistoryView.TagKind.all.accepts(manual))
    #expect(HistoryView.TagKind.all.accepts(auto))
    #expect(HistoryView.TagKind.auto.accepts(auto))
    #expect(!HistoryView.TagKind.auto.accepts(manual))
    #expect(HistoryView.TagKind.manual.accepts(manual))
    #expect(!HistoryView.TagKind.manual.accepts(auto))
}
