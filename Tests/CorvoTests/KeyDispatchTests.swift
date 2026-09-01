import AppKit
import SwiftUI
import Testing
@testable import Corvo

/// What the panel does with a key is decided by SwiftUI's shortcut matching, not
/// by the model, and the two disagree in a way that is invisible from the code:
/// ⇧+arrow reaches a shortcut registered for the bare arrow, and ⌘+arrow does
/// not. ⇧ is folded into the characters of the key; ⌘ turns the press into a key
/// equivalent, and only an equivalent registered with ⌘ is offered one.
///
/// That difference shipped a dead shortcut once already — ⌘← and ⌘→ read the
/// modifier inside the bare-arrow handler, which is never called, so the tags
/// could not be walked at all and everything compiled and passed. So this posts
/// real key events at a real window with the real view in it, and asserts on
/// what the model ends up holding.
@Test @MainActor func commandArrowsReachTheFiltersAndLeaveTheBareArrowsAlone() throws {
    let (model, window, blobs, dir, _) = try panelUnderTest()
    defer { window.orderOut(nil); try? FileManager.default.removeItem(at: dir) }
    _ = blobs
    let tagId = try #require(model.tags.first?.id)

    // The positive control. Without it a silent harness that delivers nothing
    // would make every assertion below pass by never firing anything.
    #expect(model.selectedIndex == 0)
    press(.rightArrow, in: window)
    #expect(model.selectedIndex == 1, "a bare arrow does not even reach the panel")

    // ⌘→ walks the tag strip. This is the assertion that was false when the
    // modifier was read inside the bare-arrow handler instead of registered.
    press(.rightArrow, modifiers: .command, in: window)
    #expect(model.selectedTag == tagId)

    // ⌘← walks back off it, and the head of the row is "no tag".
    press(.leftArrow, modifiers: .command, in: window)
    #expect(model.selectedTag == nil)

    // And the bare arrows still work with the ⌘ pair registered beside them,
    // which is the half that the ⇧ shortcuts got wrong when they were registered
    // separately: the modified one took every press of the key.
    model.select(0)
    press(.rightArrow, in: window)
    #expect(model.selectedIndex == 1, "registering ⌘+arrow ate the bare arrow")
}

/// ⌘1 through ⌘9 are registered with the modifier, so unlike the arrows they
/// were never in doubt — but the panel is the wrong place to find out that a
/// paste key does nothing, and it costs one event to know.
@Test @MainActor func theNumberKeysPasteTheCardTheyName() throws {
    let (model, window, blobs, dir, box) = try panelUnderTest()
    defer { window.orderOut(nil); try? FileManager.default.removeItem(at: dir) }
    _ = blobs

    let second = try #require(model.items.indices.contains(1) ? model.items[1] : nil)
    press(.character("2"), modifiers: .command, in: window)
    #expect(box.pasted.map(\.id) == [second.id])

    // A number past the end of the list does nothing rather than pasting the
    // nearest thing to it.
    box.pasted = []
    model.query = "no such clipping anywhere"
    #expect(model.items.isEmpty)
    press(.character("1"), modifiers: .command, in: window)
    #expect(box.pasted.isEmpty)
}

/// A sheet is a modal answer to a question, and every one of these keys acts on
/// the list behind it. Measured rather than assumed: if the shortcuts did reach
/// through, ⌘1 would paste and dismiss the panel out from under an open sheet.
@Test @MainActor func theShortcutsDoNotReachThroughAnOpenSheet() throws {
    let (model, window, blobs, dir, box) = try panelUnderTest()
    defer { window.orderOut(nil); try? FileManager.default.removeItem(at: dir) }
    _ = blobs

    model.sheet = .tags
    settle()

    press(.character("1"), modifiers: .command, in: window)
    #expect(box.pasted.isEmpty)

    let tagBefore = model.selectedTag
    press(.rightArrow, modifiers: .command, in: window)
    #expect(model.selectedTag == tagBefore)

    model.sheet = nil
    settle()
}

// MARK: - Posting real key events

@MainActor
private final class PasteBox {
    var pasted: [ClipItem] = []
    /// ⌘, asked for Settings. A count and not a flag, so a shortcut that fires
    /// twice for one press is not read as working.
    var settingsOpened = 0
}

@MainActor
private func panelUnderTest() throws -> (HistoryModel, NSPanel, BlobStore, URL, PasteBox) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-keys-\(UUID().uuidString)")
    let blobs = BlobStore(directory: dir)
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil), blobs: blobs)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let warp = ItemSource(bundleId: "dev.warp.Warp-Stable", name: "Warp")
    var first: Int64?
    for i in 0..<6 {
        let id = try repo.insert(CapturedItem(kind: .text, text: "clipping \(i)",
                                              imageData: nil, filePath: nil, url: nil,
                                              contentHash: "hash-\(i)"),
                                 source: warp, now: start.addingTimeInterval(Double(i)))
        if first == nil { first = id }
    }
    try repo.addTag(named: "alpha", to: try #require(first))

    let model = HistoryModel(repo: repo,
                             prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    model.reload()
    let box = PasteBox()
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 420),
                         styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: HistoryView(
        model: model, blobs: blobs,
        onPaste: { box.pasted = $0 }, onCopy: { _ in },
        onOpenSettings: { box.settingsOpened += 1 }))
    window.makeKeyAndOrderFront(nil)
    settle()
    return (model, window, blobs, dir, box)
}

/// The keys this panel binds, by the code and character AppKit sends for them.
private enum Key {
    case leftArrow, rightArrow, character(Character)

    var code: UInt16 {
        switch self {
        case .leftArrow: return 123
        case .rightArrow: return 124
        // kVK_ANSI_*. A wrong code is a press that lands on another key, so
        // these are named rather than derived.
        case .character(let c):
            switch c {
            case "1": return 18
            case "2": return 19
            case ",": return 43
            default:
                Issue.record("no keyCode for \(c) — add it")
                return 0
            }
        }
    }

    var characters: String {
        switch self {
        case .leftArrow: return String(UnicodeScalar(UInt32(0xF702))!)
        case .rightArrow: return String(UnicodeScalar(UInt32(0xF703))!)
        case .character(let c): return String(c)
        }
    }
}

@MainActor
private func press(_ key: Key, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        characters: key.characters, charactersIgnoringModifiers: key.characters,
        isARepeat: false, keyCode: key.code) else {
        Issue.record("could not build the key event")
        return
    }
    // A ⌘ press is a key equivalent and never arrives as an ordinary keyDown;
    // everything else does. Trying both in this order is what a window does.
    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    settle()
}

/// SwiftUI acts on a shortcut through the run loop, not inside `sendEvent`.
@MainActor
private func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
}


/// ⌘, has to reach the panel, because the panel is the only surface left once
/// the menu bar icon is switched off — and switching it off is what takes the
/// `MenuBarExtra` menu, and the ⌘, on it, away.
///
/// Posted as a real event for the reason this file exists: ⌘ makes a press a key
/// equivalent, and a shortcut that is never offered one compiles, reads
/// correctly, and does nothing. That shipped here once already.
@Test @MainActor func commandCommaReachesSettingsFromThePanel() throws {
    let (model, window, blobs, dir, box) = try panelUnderTest()
    defer { window.orderOut(nil); try? FileManager.default.removeItem(at: dir) }
    _ = blobs

    #expect(box.settingsOpened == 0)

    press(.character(","), modifiers: .command, in: window)
    #expect(box.settingsOpened == 1, "⌘, never reached the panel")

    // The search field holds focus and a comma is an ordinary character in it,
    // so the bare key must stay the field's: only the ⌘ form is ours.
    press(.character(","), in: window)
    #expect(box.settingsOpened == 1, "a bare comma should type, not open Settings")
    #expect(model.query.contains(","))
}
