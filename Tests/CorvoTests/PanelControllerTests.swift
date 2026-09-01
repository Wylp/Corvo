import AppKit
import SwiftUI
import Testing
@testable import Corvo

/// The guarantee the panel has to keep: it always comes back usable. Whatever
/// sheet was up when it was last put away is gone before it is on screen again,
/// so there is no reopening into a sheet with a dead window behind it.
///
/// The panel is only ever on screen after `show()`, or after AppKit restores it
/// following an activation — and an activation is always preceded by the
/// deactivation that hid it. Both of those are covered here.

@Test @MainActor func openingThePanelClearsWhateverSheetWasUp() {
    var cleared = 0
    let panel = PanelController(content: Text(verbatim: "x")) { cleared += 1 }

    panel.show()
    #expect(cleared == 1)

    // However it was put away — ⌘⇧V again, Esc, a paste — the next opening is
    // the one that has to be clean, and it is.
    panel.hide()
    panel.show()

    #expect(cleared == 2)
    panel.hide()
}

/// The path the bug was reported on: the user clicks somewhere else and the
/// panel goes away. AppKit posts this as it deactivates; clearing here is what
/// stops the sheet from coming back onto the screen with the panel.
@Test @MainActor func theAppResigningActiveClearsItToo() {
    var cleared = 0
    let panel = PanelController(content: Text(verbatim: "x")) { cleared += 1 }
    panel.show()
    #expect(cleared == 1)

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification,
                                    object: NSApp)

    #expect(cleared == 2)
    panel.hide()
}

/// The bug itself, as close as a test can stand to it: a real window, the real
/// `HistoryView`, the real sheet. `attachedSheet` is the dimming overlay the
/// user was left staring at — the thing that has to be gone when the panel comes
/// back, not merely a flag that says it should be.
@Test @MainActor func aSheetLeftUpIsGoneWhenThePanelComesBack() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-sheet-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let blobs = BlobStore(directory: dir)
    let model = HistoryModel(repo: ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                                                  blobs: blobs),
                             prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                         styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: HistoryView(
        model: model, blobs: blobs, onPaste: { _ in }, onCopy: { _ in },
        onOpenSettings: {}))
    defer { window.orderOut(nil) }

    window.makeKeyAndOrderFront(nil)
    settle()
    model.sheet = .tags
    settle()
    #expect(window.attachedSheet != nil)

    // Put away with the sheet still up, which is how the user got here.
    window.orderOut(nil)
    settle()
    // What `PanelController` does on the way back in.
    model.sheet = nil
    window.makeKeyAndOrderFront(nil)
    settle()

    #expect(window.attachedSheet == nil)
}

/// SwiftUI presents and dismisses a sheet on the run loop, not on the assignment.
@MainActor
private func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
}

/// The observer is torn down with the controller. Without this a test's counter
/// keeps being incremented by every later deactivation in the run.
@Test @MainActor func aReleasedControllerStopsListening() {
    var cleared = 0
    do {
        let panel = PanelController(content: Text(verbatim: "x")) { cleared += 1 }
        panel.show()
        panel.hide()
    }
    let afterRelease = cleared

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification,
                                    object: NSApp)

    #expect(cleared == afterRelease)
}

/// The two closures answer to different moments, and the difference is the
/// whole reason there are two of them. A sheet must not survive a round trip at
/// all, so it goes on both. What the user is looking at is not transient in that
/// sense: clicking into another app for a moment is not asking for the search
/// and the filter to be thrown away, and `hidesOnDeactivate` means that click
/// arrives here as the same notification a real close would.
@Test @MainActor func onlyADeliberateOpeningPutsTheViewBackToItsDefault() {
    var cleared = 0
    var reset = 0
    let panel = PanelController(content: Text(verbatim: "x"),
                                clearTransientState: { cleared += 1 },
                                resetToDefaultView: { reset += 1 })

    panel.show()
    #expect(cleared == 1)
    #expect(reset == 1)

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification,
                                    object: NSApp)

    // The sheet is cleared again, because AppKit can put the panel back with no
    // call of ours in it. The filter is not.
    #expect(cleared == 2)
    #expect(reset == 1)
    panel.hide()
}


/// Resigning active takes the panel off the screen, and this asserts it because
/// it is ours to do now.
///
/// `hidesOnDeactivate` used to. It was dropped because AppKit enforces it in the
/// other direction too — a window carrying it is ordered straight back out if it
/// is brought front while the app is inactive, which is exactly what `show()`
/// does after `NSApp.activate(ignoringOtherApps:)`, an activation that does not
/// land synchronously. Losing that race opened nothing and made the next press
/// look like the one that worked: the "hotkey needs two presses" report.
///
/// The behaviour moved from AppKit, where nothing could ask it a question, into
/// one line here — so there is something to fail if it is ever removed.
@Test @MainActor func theAppResigningActiveTakesThePanelOffTheScreen() {
    let panel = PanelController(content: Text(verbatim: "x"))
    panel.show()
    #expect(panel.isVisible)

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification,
                                    object: NSApp)

    #expect(!panel.isVisible, "the panel stayed up after the app resigned active")
}

/// The half the race was about: bringing the panel front twice in a row leaves
/// it up. With `hidesOnDeactivate` this held only while the app was active, and
/// `show()` cannot promise that — `NSApp.activate(ignoringOtherApps:)` returns
/// before the activation lands.
@Test @MainActor func showingTwiceLeavesThePanelUp() {
    let panel = PanelController(content: Text(verbatim: "x"))
    panel.show()
    #expect(panel.isVisible)
    panel.show()
    #expect(panel.isVisible, "the second opening put the panel away")
    panel.hide()
}
