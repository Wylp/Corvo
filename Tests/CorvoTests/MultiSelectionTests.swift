import AppKit
import Foundation
import Testing
@testable import Corvo

/// ⇧← / ⇧→ over the carousel, and what the clipboard ends up holding when more
/// than one clipping goes over at once.

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func makeModel() throws -> (HistoryModel, ItemRepository, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-ms-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    return (HistoryModel(repo: repo, prefs: prefs), repo, dir)
}

private func textItem(_ s: String) -> CapturedItem {
    CapturedItem(kind: .text, text: s, imageData: nil,
                 filePath: nil, url: nil, contentHash: s)
}

/// Inserts oldest first so the list reads `["c", "b", "a"]` newest-first.
@MainActor
private func seed(_ repo: ItemRepository, _ texts: [String]) throws {
    for (offset, text) in texts.enumerated() {
        try repo.insert(textItem(text), source: nil,
                        now: t0.addingTimeInterval(TimeInterval(offset)))
    }
}

private func tempPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("corvo-ms-\(UUID().uuidString)"))
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-ms-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func item(kind: ClipKind, id: Int64 = 1, text: String? = nil,
                  blobPath: String? = nil, filePath: String? = nil) -> ClipItem {
    ClipItem(id: id, kind: kind, text: text, blobPath: blobPath, filePath: filePath,
             url: nil, sourceBundleId: nil, sourceName: nil,
             contentHash: "hash-\(id)", createdAt: t0)
}

private func pngData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - The run

@MainActor @Test func withNoRunTheSelectionIsJustTheClippingUnderTheCursor() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b"])
    model.reload()

    #expect(model.selectedItems.map(\.text) == ["b"])
}

@MainActor @Test func shiftArrowMarksTheRunItCrosses() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.extendSelection(1)
    model.extendSelection(1)

    // Newest first, and the run is in list order rather than the order crossed.
    #expect(model.selectedItems.map(\.text) == ["c", "b", "a"])
    #expect(model.selectedIndex == 2)
}

/// The anchor is what makes this shrink rather than grow the other way: without
/// one, ⇧← after ⇧→ would just keep marking whatever the cursor lands on.
@MainActor @Test func extendingBackTowardsTheAnchorShrinksTheRun() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.extendSelection(1)
    model.extendSelection(1)
    model.extendSelection(-1)

    #expect(model.selectedItems.map(\.text) == ["c", "b"])
}

@MainActor @Test func shiftClickSelectsEverythingBetweenTheAnchorAndTheCard() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c", "d"])
    model.reload()          // ["d", "c", "b", "a"], cursor on "d"

    model.extendSelection(to: 2)

    #expect(model.selectedItems.map(\.text) == ["d", "c", "b"])
    #expect(model.selectedIndex == 2)
}

/// ⇧-click keeps sweeping from where the run started rather than dragging the
/// start along behind the cursor.
@MainActor @Test func shiftClickingAgainSweepsFromTheSameAnchor() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c", "d"])
    model.reload()

    model.select(1)                  // cursor on "c", which becomes the anchor
    model.extendSelection(to: 3)
    model.extendSelection(to: 2)

    #expect(model.selectedItems.map(\.text) == ["c", "b"])
}

/// ⇧-click backwards from the anchor covers the same ground as forwards.
@MainActor @Test func shiftClickReachesBackwardsTowardsNewerClippings() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.select(2)                  // oldest
    model.extendSelection(to: 0)     // ⇧-click the newest

    #expect(model.selectedItems.map(\.text) == ["c", "b", "a"])
}

/// A plain click after a run starts a fresh one rather than adding to the old.
@MainActor @Test func aPlainClickResetsTheAnchorForTheNextShiftClick() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c", "d"])
    model.reload()

    model.extendSelection(to: 3)     // run of four
    model.select(1)                  // plain click on "c"
    model.extendSelection(to: 2)

    #expect(model.selectedItems.map(\.text) == ["c", "b"])
}

/// The bug this pair exists for: ⇧+arrow used to be registered as its own
/// keyboard shortcut, and SwiftUI handed it every press of that key, so moving
/// with a bare arrow silently extended a run.
@MainActor @Test func anArrowWithoutShiftMovesAndMarksNothing() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.arrow(1, extending: false)
    model.arrow(1, extending: false)

    #expect(model.selectedIndex == 2)
    #expect(model.markedIds.isEmpty)
    #expect(model.selectedItems.map(\.text) == ["a"])
}

@MainActor @Test func anArrowWithShiftExtendsInstead() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.arrow(1, extending: true)

    #expect(model.selectedItems.map(\.text) == ["c", "b"])
}

@MainActor @Test func aBareArrowDropsTheRun() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.extendSelection(1)
    model.move(1)

    #expect(model.selectedItems.map(\.text) == ["a"])
    #expect(model.markedIds.isEmpty)
}

@MainActor @Test func tappingACardDropsTheRun() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.extendSelection(1)
    model.select(2)

    #expect(model.selectedItems.map(\.text) == ["a"])
}

/// A mark is an id, and the list it points into is reloaded by the poller. A
/// mark left pointing at a clipping that filtering removed would be a clipping
/// that silently fails to paste.
@MainActor @Test func aRunDropsClippingsThatLeaveTheList() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["alpha", "beta", "gamma"])
    model.reload()

    model.extendSelection(1)
    model.extendSelection(1)
    #expect(model.selectedItems.count == 3)

    model.query = "alpha"

    // Exactly the survivor, not "at most one": a run reduced to nothing would
    // also read as ["alpha"] through the no-run path and hide the bug.
    #expect(model.markedIds == Set(model.items.compactMap(\.id)))
    #expect(model.selectedItems.map(\.text) == ["alpha"])
}

/// A clipping copied while a run is open lands at the front of the list and
/// shifts every index by one. The anchor is an id for exactly this reason.
@MainActor @Test func aRunSurvivesSomethingNewArrivingAtTheFront() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seed(repo, ["a", "b", "c"])
    model.reload()

    model.extendSelection(1)          // run is ["c", "b"], cursor on "b"
    try repo.insert(textItem("brand new"), source: nil,
                    now: t0.addingTimeInterval(99))
    model.reload()

    #expect(model.selectedItems.map(\.text) == ["c", "b"])
}

// MARK: - What reaches the clipboard

@Test func severalTextClippingsArriveJoinedByNewlines() {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let blobs = BlobStore(directory: tempDirectory())

    let written = Paster.writeToClipboard(
        [item(kind: .text, id: 1, text: "first"),
         item(kind: .text, id: 2, text: "second")],
        blobs: blobs, to: pasteboard)

    #expect(written == 2)
    #expect(pasteboard.string(forType: .string) == "first\nsecond")
}

@Test func severalFileClippingsArriveAsSeveralURLs() throws {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobs = BlobStore(directory: tempDirectory())
    let one = directory.appendingPathComponent("one.txt")
    let two = directory.appendingPathComponent("two.txt")
    try Data("1".utf8).write(to: one)
    try Data("2".utf8).write(to: two)

    let written = Paster.writeToClipboard(
        [item(kind: .file, id: 1, filePath: one.path),
         item(kind: .file, id: 2, filePath: two.path)],
        blobs: blobs, to: pasteboard)

    #expect(written == 2)
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    #expect(urls?.map(\.path) == [one.path, two.path])
}

/// Mixed kinds have no single representation, so the run collapses to the text
/// each one can offer. A file offers its path.
@Test func aMixOfTextAndFileCollapsesToJoinedText() throws {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobs = BlobStore(directory: tempDirectory())
    let file = directory.appendingPathComponent("note.txt")
    try Data("x".utf8).write(to: file)

    let written = Paster.writeToClipboard(
        [item(kind: .text, id: 1, text: "hello"),
         item(kind: .file, id: 2, filePath: file.path)],
        blobs: blobs, to: pasteboard)

    #expect(written == 2)
    #expect(pasteboard.string(forType: .string) == "hello\n\(file.path)")
}

/// Images have no text to join and no pasteboard type that carries several of
/// them, so the run falls back to one image rather than clearing the clipboard
/// and putting nothing back.
@Test func aRunOfNothingButImagesFallsBackToTheFirstOne() throws {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobs = BlobStore(directory: directory)
    let first = try blobs.store(pngData(), hash: "one", ext: "png")
    let second = try blobs.store(pngData(), hash: "two", ext: "png")

    let written = Paster.writeToClipboard(
        [item(kind: .image, id: 1, blobPath: first),
         item(kind: .image, id: 2, blobPath: second)],
        blobs: blobs, to: pasteboard)

    // One of the two, and the count says so — this is the shortfall the user
    // has to be told about.
    #expect(written == 1)
    #expect(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
}

@Test func anEmptySelectionLeavesTheClipboardAlone() {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let blobs = BlobStore(directory: tempDirectory())
    Paster.writeToClipboard(item(kind: .text, text: "keep me"), blobs: blobs, to: pasteboard)

    let written = Paster.writeToClipboard([], blobs: blobs, to: pasteboard)

    #expect(written == 0)
    #expect(pasteboard.string(forType: .string) == "keep me")
}

/// One clipping through the multi-item door is the same as through the old one.
@Test func aSingleClippingIsUnchangedByTheNewPath() {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let blobs = BlobStore(directory: tempDirectory())

    let written = Paster.writeToClipboard([item(kind: .text, text: "alone")],
                                          blobs: blobs, to: pasteboard)

    #expect(written == 1)
    #expect(pasteboard.string(forType: .string) == "alone")
}

/// ⌘-click: the selection ⇧ cannot describe — scattered cards, not a run.
@MainActor @Test func commandClickPicksScatteredClippings() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    for (i, text) in ["a", "b", "c", "d"].enumerated() {
        try repo.insert(textItem(text), source: nil, now: t0.addingTimeInterval(Double(i)))
    }
    model.reload()          // newest first: d, c, b, a
    model.select(0)         // cursor on "d"

    // The first ⌘-click adds to the cursor's clipping rather than replacing it.
    model.toggleMark(at: 2)
    #expect(model.selectedItems.map(\.text) == ["d", "b"])

    model.toggleMark(at: 3)
    #expect(model.selectedItems.map(\.text) == ["d", "b", "a"])

    // Clicking a marked card again takes it back out.
    model.toggleMark(at: 2)
    #expect(model.selectedItems.map(\.text) == ["d", "a"])

    // A plain click still drops the whole thing.
    model.select(1)
    #expect(model.selectedItems.map(\.text) == ["c"])
}

/// ⌘T on a run reaches every clipping in it. It used to reach exactly one and
/// say nothing about the rest.
@MainActor @Test func oneTagLandsOnEveryClippingInTheRun() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    for (i, text) in ["a", "b", "c"].enumerated() {
        try repo.insert(textItem(text), source: nil, now: t0.addingTimeInterval(Double(i)))
    }
    model.reload()
    model.select(0)
    model.extendSelection(2)
    #expect(model.selectedItems.count == 3)

    model.addTag("run", to: model.selectedItems)

    for item in model.items {
        #expect(model.tags(for: item).map(\.name) == ["run"])
    }
    // One tag row, not three.
    #expect(model.tags.map(\.name) == ["run"])
}

/// The case the other clipboard tests do not cover: the count going in differs
/// from the count coming out.
///
/// Text+text, file+file and text+file all keep everything, so a boolean is
/// enough to describe them and the shortfall never appears. Put an image in the
/// run and one clipping is left behind — that is the number `paste` reports and
/// the panel says out loud, and losing it in silence is the bug this replaces.
@Test func animageInAMixedRunIsLeftBehindAndTheCountSaysSo() throws {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobs = BlobStore(directory: directory)
    let png = try blobs.store(pngData(), hash: "shot", ext: "png")

    let written = Paster.writeToClipboard(
        [item(kind: .text, id: 1, text: "first"),
         item(kind: .image, id: 2, blobPath: png),
         item(kind: .text, id: 3, text: "second")],
        blobs: blobs, to: pasteboard)

    // Three marked, two carried.
    #expect(written == 2)
    #expect(pasteboard.string(forType: .string) == "first\nsecond")
}
