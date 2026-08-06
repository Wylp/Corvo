import Foundation
import Testing
@testable import Corvo

/// Both rules on, 1000 clippings, 30 days — what a fresh install is looking at.
private let bothOn = RetentionSettings(maxItems: 1000, maxAgeDays: 30,
                                      limitsItems: true, limitsAge: true)

// MARK: - Narrowing a number

/// Behaviour that predates this branch, and had no test of its own: the alert
/// lived on a comparison inside the view.
@Test func loweringTheCountIsACut() {
    var after = bothOn
    after.maxItems = 500
    #expect(RetentionEdit.isCut(from: bothOn, to: after))
}

@Test func loweringTheAgeIsACut() {
    var after = bothOn
    after.maxAgeDays = 7
    #expect(RetentionEdit.isCut(from: bothOn, to: after))
}

@Test func raisingEitherNumberIsNotACut() {
    var after = bothOn
    after.maxItems = 5000
    after.maxAgeDays = 90
    #expect(!RetentionEdit.isCut(from: bothOn, to: after))
}

@Test func changingNothingIsNotACut() {
    #expect(!RetentionEdit.isCut(from: bothOn, to: bothOn))
}

// MARK: - Switching a rule on

/// The largest cut this screen can make, and the one the old comparison could not
/// see: the number is identical, and turning the rule on can still take years of
/// history in one go.
@Test func switchingARuleOnIsACutEvenWithTheSameNumber() {
    let before = RetentionSettings(maxItems: 1000, maxAgeDays: 30,
                                  limitsItems: true, limitsAge: false)
    var after = before
    after.limitsAge = true

    #expect(RetentionEdit.isCut(from: before, to: after))
}

@Test func switchingTheCountRuleOnIsACut() {
    let before = RetentionSettings(maxItems: 1000, maxAgeDays: 30,
                                  limitsItems: false, limitsAge: true)
    var after = before
    after.limitsItems = true

    #expect(RetentionEdit.isCut(from: before, to: after))
}

/// A rule switched on while its number is raised is still a cut: the rule was not
/// being enforced at all, so any number is narrower than none.
@Test func switchingARuleOnWhileRaisingItsNumberIsStillACut() {
    let before = RetentionSettings(maxItems: 100, maxAgeDays: 30,
                                  limitsItems: false, limitsAge: true)
    var after = before
    after.limitsItems = true
    after.maxItems = 9000

    #expect(RetentionEdit.isCut(from: before, to: after))
}

// MARK: - Switching a rule off

@Test func switchingARuleOffIsNotACut() {
    var after = bothOn
    after.limitsAge = false
    #expect(!RetentionEdit.isCut(from: bothOn, to: after))
}

@Test func switchingBothRulesOffIsNotACut() {
    var after = bothOn
    after.limitsItems = false
    after.limitsAge = false
    #expect(!RetentionEdit.isCut(from: bothOn, to: after))
}

/// Nothing is being enforced, so the number is not a limit — moving it deletes
/// nothing and must not raise an alert about deleting.
@Test func loweringTheNumberOfARuleThatIsOffIsNotACut() {
    let before = RetentionSettings(maxItems: 1000, maxAgeDays: 30,
                                  limitsItems: false, limitsAge: false)
    var after = before
    after.maxItems = 1
    after.maxAgeDays = 1

    #expect(!RetentionEdit.isCut(from: before, to: after))
}

/// One rule switched off while the other is lowered. The cut is real, and the
/// half that widens must not cancel it out.
@Test func aCutInOneRuleCountsWhileTheOtherIsSwitchedOff() {
    var after = bothOn
    after.limitsAge = false
    after.maxItems = 10

    #expect(RetentionEdit.isCut(from: bothOn, to: after))
}
