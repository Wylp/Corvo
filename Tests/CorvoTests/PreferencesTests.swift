import Foundation
import Testing
@testable import Corvo

/// Never `.standard`: these tests write retention limits and a blocklist, and
/// `.standard` is the real user's configuration.
private func makePrefs() -> Preferences {
    Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
}

// MARK: - The blocklist is a privacy control

@Test func aWellFormedBundleIdIsAccepted() {
    #expect(Blocklist.isValidBundleId("com.apple.Terminal"))
    #expect(Blocklist.isValidBundleId("com.1password.1password"))
    #expect(Blocklist.isValidBundleId("dev.warp.Warp-Stable"))
    #expect(Blocklist.isValidBundleId("com.foo_bar.app"))
}

/// Every one of these is a string a user could plausibly type believing it
/// blocks an app. None of them can ever equal a real bundle id, so accepting
/// any of them would be a promise Corvo cannot keep.
@Test func aStringThatCannotBeABundleIdIsRejected() {
    #expect(!Blocklist.isValidBundleId("Terminal"))
    #expect(!Blocklist.isValidBundleId("com.apple.Terminal, com.apple.Safari"))
    #expect(!Blocklist.isValidBundleId("com..Terminal"))
    #expect(!Blocklist.isValidBundleId(".com.apple.Terminal"))
    #expect(!Blocklist.isValidBundleId("com.apple.Terminal "))
    #expect(!Blocklist.isValidBundleId("*"))
    #expect(!Blocklist.isValidBundleId(""))
}

/// The failure this guards is silent deactivation: one bad line must not take
/// the working lines down with it, and it must come back by name so the screen
/// can say what is not being enforced.
@Test func oneBadLineDoesNotDisarmTheLinesAroundIt() {
    let parsed = Blocklist.parse("""
        com.apple.Terminal
        Safari
          com.apple.Notes\u{20}\u{20}

        com.apple.Terminal, com.apple.Safari
        """)

    #expect(parsed.accepted == ["com.apple.Terminal", "com.apple.Notes"])
    #expect(parsed.rejected == ["Safari", "com.apple.Terminal, com.apple.Safari"])
}

@Test func blankLinesAreNeitherEnforcedNorReported() {
    let parsed = Blocklist.parse("\n\n   \n")
    #expect(parsed.accepted.isEmpty)
    #expect(parsed.rejected.isEmpty)
}

/// `"\r\n"` is a single grapheme cluster in Swift, so splitting on the
/// `Character` `"\n"` alone never matches it — a list pasted with Windows line
/// endings collapsed into one entry that blocked nothing. `isNewline` also
/// covers a bare `"\r"`.
@Test func crlfAndBareCRAreTreatedAsLineBreaks() {
    #expect(Blocklist.entries("com.apple.Terminal\r\ncom.apple.Notes\rcom.apple.Safari")
        == ["com.apple.Terminal", "com.apple.Notes", "com.apple.Safari"])
}

@Test func duplicateBlocklistLinesAreCollapsed() {
    #expect(Blocklist.entries("com.apple.Notes\ncom.apple.Notes") == ["com.apple.Notes"])
}

/// A line that is not a bundle id is still stored, so that reopening the window
/// shows the user the same list they typed and the same warning about it.
/// Dropping it would make the typo vanish overnight and leave them believing an
/// app is blocked, which is the silent failure this control may not have.
@Test func aLineTheUserGotWrongSurvivesTheRoundTrip() {
    let prefs = makePrefs()
    prefs.blocklist = Blocklist.entries(" com.apple.Terminal \nSafari\n\n")

    #expect(prefs.blocklist == ["com.apple.Terminal", "Safari"])
    // And it comes back to the editor still flagged, not silently enforced.
    let reopened = Blocklist.parse(prefs.blocklist.joined(separator: "\n"))
    #expect(reopened.accepted == ["com.apple.Terminal"])
    #expect(reopened.rejected == ["Safari"])
}

// MARK: - The retention limits are now the user's to type

/// The prune and the auto-tagger scan both run on the main thread and were
/// written against a fixed ceiling of 1000. An editable limit with no bound
/// would freeze the app on launch, so the bound is enforced on the way in —
/// at the property every writer goes through, not at the field that edits it.
@Test func aRetentionLimitIsClampedWhereverItIsWrittenFrom() {
    let prefs = makePrefs()

    prefs.maxItems = 10_000_000
    #expect(prefs.maxItems == Preferences.itemLimits.upperBound)

    prefs.maxItems = 0
    #expect(prefs.maxItems == Preferences.itemLimits.lowerBound)

    prefs.maxAgeDays = -5
    #expect(prefs.maxAgeDays == Preferences.ageLimits.lowerBound)

    prefs.maxAgeDays = 10_000
    #expect(prefs.maxAgeDays == Preferences.ageLimits.upperBound)
}

/// The setter clamps, but `AppEnvironment.start()` reads the limit through the
/// getter on every launch — so a value that reached `UserDefaults` some other
/// way (`defaults write`, an MDM profile, a restored plist) has to come back
/// bounded from there too, or the prune's launch-time read is unbounded.
@Test func theGetterClampsAValueWrittenOutsideTheSetter() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    defaults.set(10_000_000, forKey: "maxItems")
    defaults.set(99_999, forKey: "maxAgeDays")
    let prefs = Preferences(defaults: defaults)

    #expect(prefs.maxItems == Preferences.itemLimits.upperBound)
    #expect(prefs.maxAgeDays == Preferences.ageLimits.upperBound)
}

@Test func anUnsetLimitStillFallsBackToTheStandardPolicy() {
    let prefs = makePrefs()
    #expect(prefs.maxItems == RetentionPolicy.standard.maxItems)
    #expect(prefs.retentionPolicy == RetentionPolicy.standard)
}

/// The number the window writes is the number retention enforces. Task 12c
/// already proved the auto-tagger reads this rather than the fixed default;
/// this is the same guarantee from the writing end.
@Test func aRaisedLimitReachesTheRetentionPolicy() {
    let prefs = makePrefs()
    prefs.maxItems = 2_500
    prefs.maxAgeDays = 7
    #expect(prefs.retentionPolicy == RetentionPolicy(maxItems: 2_500, maxAge: 7 * 86400))
}

// MARK: - The menu bar icon is the app's only visible control

/// The upgrade. Every existing install has never written this key, and the wrong
/// read — `defaults.bool(forKey:)`, which answers `false` for an absent key —
/// would launch them with no icon, no Dock icon and no window: an app that looks
/// uninstalled and is running. Absent has to mean the behaviour they already had.
@Test func anUnsetMenuBarIconPreferenceShowsTheIcon() {
    #expect(makePrefs().showsMenuBarIcon)
}

@Test func theMenuBarIconPreferenceSurvivesBothWays() {
    let prefs = makePrefs()

    prefs.showsMenuBarIcon = false
    #expect(!prefs.showsMenuBarIcon)

    prefs.showsMenuBarIcon = true
    #expect(prefs.showsMenuBarIcon)
}

/// The key is a contract with a second reader. `MenuBarExtra`'s `isInserted` is
/// bound to `@AppStorage(Preferences.showsMenuBarIconKey)`, which goes to
/// `UserDefaults` directly and never through this type — so what `Preferences`
/// writes has to be what plain `bool(forKey:)` reads back under that name, or
/// the switch in Settings and the icon in the menu bar answer to two different
/// settings that merely look like one.
@Test func theStoredValueIsWhatAppStorageWouldRead() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let prefs = Preferences(defaults: defaults)

    prefs.showsMenuBarIcon = false
    #expect(defaults.object(forKey: Preferences.showsMenuBarIconKey) as? Bool == false)

    // And the other direction: the icon dragged out of the menu bar is
    // `isInserted` writing this key itself, with no help from `Preferences`.
    defaults.set(true, forKey: Preferences.showsMenuBarIconKey)
    #expect(prefs.showsMenuBarIcon)
}

// MARK: - Switching a rule off

@Test func bothRulesAreOnWhenNothingHasBeenStored() {
    let prefs = makePrefs()
    #expect(prefs.limitsItems)
    #expect(prefs.limitsAge)
}

/// The upgrade. Someone who has been using Corvo has neither switch in their
/// plist and a limit they chose; the build that adds the switches has to keep
/// enforcing exactly what it enforced yesterday.
///
/// This is the test that must never be deleted: `defaults.bool(forKey:)` here
/// instead of `object(forKey:)` reads `false` for an absent key, which would
/// switch retention off for every existing user with no error and no symptom
/// until their database was large.
@Test func aPlistFromBeforeTheSwitchesKeepsItsRetention() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    defaults.set(500, forKey: "maxItems")
    defaults.set(14, forKey: "maxAgeDays")

    let prefs = Preferences(defaults: defaults)

    #expect(prefs.limitsItems)
    #expect(prefs.limitsAge)
    #expect(prefs.retentionPolicy == RetentionPolicy(maxItems: 500, maxAge: 14 * 86400))
}

/// Switching off is not forgetting. The number stays stored, so switching back on
/// restores what the user chose rather than the default — and the dimmed field has
/// something true to show meanwhile.
@Test func switchingARuleOffKeepsItsNumber() {
    let prefs = makePrefs()
    prefs.maxItems = 2_500

    prefs.limitsItems = false
    #expect(prefs.maxItems == 2_500)
    #expect(prefs.retentionPolicy.maxItems == nil)

    prefs.limitsItems = true
    #expect(prefs.retentionPolicy.maxItems == 2_500)
}

@Test func thePolicyMapsAllFourStates() {
    let prefs = makePrefs()
    prefs.maxItems = 400
    prefs.maxAgeDays = 10

    prefs.limitsItems = true; prefs.limitsAge = true
    #expect(prefs.retentionPolicy == RetentionPolicy(maxItems: 400, maxAge: 10 * 86400))

    prefs.limitsAge = false
    #expect(prefs.retentionPolicy == RetentionPolicy(maxItems: 400, maxAge: nil))

    prefs.limitsItems = false; prefs.limitsAge = true
    #expect(prefs.retentionPolicy == RetentionPolicy(maxItems: nil, maxAge: 10 * 86400))

    prefs.limitsAge = false
    #expect(prefs.retentionPolicy == RetentionPolicy(maxItems: nil, maxAge: nil))
}
