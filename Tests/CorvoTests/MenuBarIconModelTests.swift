import Foundation
import Testing
@testable import Corvo

/// Never `.standard`: these tests store the menu bar setting, and `.standard` is
/// the real user's configuration — a test that hid their icon would be a test
/// that broke their app.
private func makeStore() -> (Preferences, UserDefaults) {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    return (Preferences(defaults: defaults), defaults)
}

/// A model that cannot hear `UserDefaults.didChangeNotification`, because nothing
/// posts to this centre.
///
/// Every test about what *this screen* does uses one. The model has two ways to
/// move `isShown` — publishing its own write, and re-reading after someone else's
/// — and on the shared centre either one covers for the other being broken, so a
/// test that leaves both connected proves neither. Deafening it is what leaves
/// the model's own write as the only thing that can have moved the switch.
@MainActor
private func makeDeafModel(_ prefs: Preferences) -> MenuBarIconModel {
    MenuBarIconModel(prefs: prefs, notifications: NotificationCenter())
}

// MARK: - The switch has to show what is stored

/// The bug this file exists for. Switching the icon back on stored `true` and
/// then went on drawing a switch that was off, because the row read `prefs`
/// straight from the body: `Preferences` announces nothing, so the write
/// invalidated no view — and closing and reopening the window does not
/// re-evaluate a body either, so it stayed wrong. Only the hide looked right,
/// and only because it flips the confirmation flag, which is what recomputed
/// the body.
@MainActor
@Test func switchingTheIconOnIsVisibleWithoutAnythingElseChanging() {
    let (prefs, _) = makeStore()
    let model = makeDeafModel(prefs)
    model.confirmHide()
    #expect(!model.isShown)

    model.request(true)

    #expect(model.isShown)          // what the switch draws
    #expect(prefs.showsMenuBarIcon) // what is stored
}

/// The other half of the same bug: a screen opened after the change has to agree
/// with it. This is the close-and-reopen the report described.
@MainActor
@Test func aFreshModelOpensOnTheStoredValue() {
    let (prefs, _) = makeStore()
    makeDeafModel(prefs).confirmHide()
    #expect(!makeDeafModel(prefs).isShown)

    makeDeafModel(prefs).request(true)
    #expect(makeDeafModel(prefs).isShown)
}

/// The setting has two writers. `MenuBarExtra`'s `isInserted` is bound to the
/// same key, so ⌘-dragging the icon out of the menu bar stores `false` with this
/// screen never involved — and a switch still drawn as on would be describing an
/// icon that is not there.
@MainActor
@Test func theRowFollowsAWriteItDidNotMake() async {
    let (prefs, defaults) = makeStore()
    let model = MenuBarIconModel(prefs: prefs)
    #expect(model.isShown)

    defaults.set(false, forKey: Preferences.showsMenuBarIconKey)
    await Task.yield()
    #expect(!model.isShown)

    defaults.set(true, forKey: Preferences.showsMenuBarIconKey)
    await Task.yield()
    #expect(model.isShown)
}

// MARK: - Hiding asks, showing does not

/// Showing is immediate: an icon appearing takes nothing away, so there is
/// nothing to confirm.
@MainActor
@Test func showingTheIconNeverRaisesTheConfirmation() {
    let (prefs, _) = makeStore()
    let model = makeDeafModel(prefs)
    model.confirmHide()

    model.request(true)

    #expect(!model.isConfirmingHide)
}

/// Hiding takes the app's only visible control away, so the alert comes first —
/// and nothing is stored on the way to it. A cancelled hide has to leave nothing
/// behind, which means the icon is still there and still says so.
@MainActor
@Test func askingToHideStoresNothingUntilItIsConfirmed() {
    let (prefs, defaults) = makeStore()
    let model = makeDeafModel(prefs)

    model.request(false)

    #expect(model.isConfirmingHide)
    #expect(model.isShown)
    #expect(prefs.showsMenuBarIcon)
    // Not merely `true` by fallback — untouched. A stored `true` here would be a
    // write the user never confirmed.
    #expect(defaults.object(forKey: Preferences.showsMenuBarIconKey) == nil)
}

@MainActor
@Test func confirmingTheHideIsWhatTakesTheIconAway() {
    let (prefs, _) = makeStore()
    let model = makeDeafModel(prefs)
    model.request(false)

    model.confirmHide()

    #expect(!model.isShown)
    #expect(!prefs.showsMenuBarIcon)
}
