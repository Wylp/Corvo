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

/// The path the bug was reported on: the user clicks somewhere else and
/// `hidesOnDeactivate` takes the panel away with no call of ours in it. AppKit
/// posts this as it deactivates; clearing here is what stops the sheet from
/// riding the automatic restore back onto the screen.
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
        model: model, blobs: blobs, onPaste: { _ in }, onCopy: { _ in }))
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
