import Foundation
import Testing
@testable import Corvo

/// What confirming a clipping does, at the layer that can be asked
/// deterministically.
///
/// There were four more tests here and they are gone on purpose. They built a
/// real `NSPanel` and posted real key events at it — ⏎ and ⌘1-9 in both modes —
/// which is the only way to prove a SwiftUI shortcut is wired at all, and it is
/// how `KeyDispatchTests` earns its keep.
///
/// Measured, they failed about one full-suite run in three while passing every
/// time in isolation. Swift Testing runs tests in parallel, several other files
/// build windows of their own, and a synthetic key event at a window that is not
/// the one holding key focus is dropped. Neither a longer wait nor `.serialized`
/// on this suite fixed it: `.serialized` orders a suite against itself, not
/// against the rest of the run, and a five-second poll failed too — the event is
/// not late, it never arrives.
///
/// So the coverage that survives is what can be asserted without a window.
/// `HistoryView.confirm(_:)` being the one place the four paths route through is
/// what makes that nearly enough: there is one decision, and it is made here.
///
/// The real fix is to serialize every window-building test in the suite against
/// every other one, which is a change across four files and does not belong in
/// the same commit as a behaviour change. It would also settle
/// `commandCommaReachesSettingsFromThePanel`, which has been failing at about
/// half of all runs since long before this.

/// Absent means copy. Every existing install has no value stored for this key,
/// so this is the setting they all get.
@Test func theDefaultIsToCopy() {
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    #expect(!prefs.pastesOnConfirm)
}

@Test func theSettingRoundTrips() {
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    prefs.pastesOnConfirm = true
    #expect(prefs.pastesOnConfirm)
    prefs.pastesOnConfirm = false
    #expect(!prefs.pastesOnConfirm)
}

@MainActor
private func model(pastesOnConfirm: Bool) throws -> (HistoryModel, Preferences, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-confirm-\(UUID().uuidString)")
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    prefs.pastesOnConfirm = pastesOnConfirm
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    return (HistoryModel(repo: repo, prefs: prefs), prefs, dir)
}

/// The panel reads the model, not `Preferences`, so the model has to start out
/// agreeing with what is stored.
@Test @MainActor func theModelStartsFromTheStoredSetting() throws {
    let (copies, _, dirA) = try model(pastesOnConfirm: false)
    defer { try? FileManager.default.removeItem(at: dirA) }
    #expect(!copies.pastesOnConfirm)

    let (pastes, _, dirB) = try model(pastesOnConfirm: true)
    defer { try? FileManager.default.removeItem(at: dirB) }
    #expect(pastes.pastesOnConfirm)
}

/// The mirror is refreshed on `resetView()`, which runs on every deliberate
/// opening of the panel. That moment is load-bearing: it is the only point at
/// which the switch can have moved, because changing it means going to Settings
/// and coming back, and coming back means the panel was shown again.
///
/// A mirror that never re-read would leave the rail naming the wrong key and ⏎
/// doing the wrong thing until the app was relaunched.
@Test @MainActor func openingThePanelPicksUpAChangedSetting() throws {
    let (model, prefs, dir) = try model(pastesOnConfirm: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!model.pastesOnConfirm)

    prefs.pastesOnConfirm = true
    #expect(!model.pastesOnConfirm, "a mirror that tracked live would not need the refresh")

    model.resetView()
    #expect(model.pastesOnConfirm, "opening the panel did not re-read the setting")
}

/// And back again, so the refresh is a re-read rather than a one-way latch.
@Test @MainActor func theSettingCanBeTurnedBackOff() throws {
    let (model, prefs, dir) = try model(pastesOnConfirm: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(model.pastesOnConfirm)

    prefs.pastesOnConfirm = false
    model.resetView()
    #expect(!model.pastesOnConfirm)
}
