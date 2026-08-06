import AppKit
import Foundation
import Testing
@testable import Corvo

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// A real but private pasteboard: exercises the actual `NSPasteboard` without
/// touching the user's clipboard.
private func privatePasteboard() -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "corvo.test.\(UUID().uuidString)"))
    pb.clearContents()
    return pb
}

@MainActor
private func makeEnvironment(_ pb: NSPasteboard) throws
    -> (PasteboardMonitor, ItemRepository, BlobStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-int-\(UUID().uuidString)")
    let blobs = BlobStore(directory: dir)
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil), blobs: blobs)
    let monitor = PasteboardMonitor(
        pasteboard: pb, repo: repo, tracker: SourceTracker(),
        prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    return (monitor, repo, blobs, dir)
}

@MainActor @Test func capturesTextFromARealNSPasteboard() throws {
    let pb = privatePasteboard()
    let (monitor, repo, _, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.clearContents()
    pb.setString("real text", forType: .string)
    try monitor.poll(now: t0)

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)
    #expect(items.map(\.text) == ["real text"])
    #expect(items.first?.kind == .text)
}

@MainActor @Test func capturesImageFromARealNSPasteboardAndWritesAReadablePNG() throws {
    let pb = privatePasteboard()
    let (monitor, repo, blobs, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.unlockFocus()

    pb.clearContents()
    pb.writeObjects([image])
    try monitor.poll(now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 10).first)
    #expect(item.kind == .image)
    let path = try #require(item.blobPath)
    let url = blobs.url(for: path)
    let reloaded = try #require(NSImage(contentsOf: url))
    #expect(reloaded.size.width == 8)

    // The pasteboard hands us TIFF; the blob has to be the converted PNG. Only
    // the signature proves it — `NSImage(contentsOf:)` reads TIFF just as
    // happily, so it would still pass if `toPNG` fell through to its raw-data
    // fallback and we stored the TIFF under a `.png` name.
    #expect(try Data(contentsOf: url).prefix(8)
        == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
}

@MainActor @Test func capturesFileFromARealNSPasteboardKeepingThePath() throws {
    let pb = privatePasteboard()
    let (monitor, repo, _, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("note.txt")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: file)

    pb.clearContents()
    pb.writeObjects([file as NSURL])
    try monitor.poll(now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 10).first)
    #expect(item.kind == .file)
    #expect(item.filePath == file.path)
    #expect(item.text == "note.txt")
    // A file is stored as a reference, never duplicated into the blob store —
    // the path above is the whole record of it.
    #expect(item.blobPath == nil)
}

@MainActor @Test func aRealPasteboardMarkedConcealedIsNotStored() throws {
    let pb = privatePasteboard()
    let (monitor, repo, _, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.clearContents()
    let item = NSPasteboardItem()
    item.setString("password", forType: .string)
    item.setString("", forType: .init(rawValue: "org.nspasteboard.ConcealedType"))
    pb.writeObjects([item])
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10).isEmpty)
}

/// The test above marks one item with both the payload and the marker, which is
/// the common real-world shape — and which `first?.types` handles just as well as
/// `flatMap`, so it cannot tell the two apart. This one splits them across two
/// items, which is the input the adapter's `flatMap` exists for.
///
/// Without it, reverting `availableTypes` to `pasteboardItems?.first?.types` — the
/// bug fixed in Task 7 — passes the whole suite while a password goes to the
/// database in plaintext.
@MainActor @Test func aConcealedMarkerOnASeparateItemIsAlsoHonoured() throws {
    let pb = privatePasteboard()
    let (monitor, repo, _, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.clearContents()
    let payload = NSPasteboardItem()
    payload.setString("password", forType: .string)
    let marker = NSPasteboardItem()
    marker.setString("", forType: .init(rawValue: "org.nspasteboard.ConcealedType"))
    pb.writeObjects([payload, marker])
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10).isEmpty)
}

@MainActor @Test func writesBackToThePasteboardTheSameContentThatWasCaptured() throws {
    let source = privatePasteboard()
    let destination = privatePasteboard()
    let (monitor, repo, blobs, dir) = try makeEnvironment(source)
    defer { try? FileManager.default.removeItem(at: dir) }

    source.clearContents()
    source.setString("round trip", forType: .string)
    try monitor.poll(now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 10).first)
    Paster.writeToClipboard(item, blobs: blobs, to: destination)

    #expect(destination.string(forType: .string) == "round trip")
}

@MainActor @Test func fullFlowFromThePollerToTheOnScreenList() throws {
    let pb = privatePasteboard()
    let (monitor, repo, _, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    let model = HistoryModel(repo: repo, prefs: monitor.prefs)

    pb.clearContents()
    pb.setString("first", forType: .string)
    try monitor.poll(now: t0)

    pb.clearContents()
    pb.setString("second", forType: .string)
    try monitor.poll(now: t0.addingTimeInterval(1))

    model.reload()
    #expect(model.items.map(\.text) == ["second", "first"])

    model.query = "fir"
    #expect(model.items.map(\.text) == ["first"])
}

@Test func theOnDiskDatabasePersistsAndTheMigrationIsIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-disk-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("corvo.sqlite")

    do {
        let repo = ItemRepository(dbQueue: try AppDatabase.make(at: url),
                                  blobs: BlobStore(directory: dir))
        try repo.insert(CapturedItem(kind: .text, text: "survived", imageData: nil,
                                     filePath: nil, url: nil, contentHash: "h1"),
                        source: nil, now: t0)
    }

    // Reopening runs the migrator again: it must neither blow up nor lose data.
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: url),
                              blobs: BlobStore(directory: dir))
    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)
    #expect(items.map(\.text) == ["survived"])
}

/// The ceiling as the user experiences it: copy past the limit and the history is
/// already at the limit, with no timer having fired and no prune having been asked
/// for by hand. This is the whole point of the capture-path sweep.
@MainActor @Test func theHistoryHoldsItsCeilingAsYouCopy() throws {
    let pb = privatePasteboard()
    let (monitor, repo, blobs, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    prefs.maxItems = 3
    prefs.limitsAge = false
    let retention = Retention(repo: repo, blobs: blobs)
    monitor.onDidCapture = {
        try? retention.enforceItemCeiling(policy: prefs.retentionPolicy)
    }

    for i in 0..<6 {
        pb.clearContents()
        pb.setString("clip \(i)", forType: .string)
        try monitor.poll(now: t0.addingTimeInterval(Double(i)))
    }

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(items.count == 3)
    #expect(items.compactMap(\.text) == ["clip 5", "clip 4", "clip 3"])
}

/// With the count rule off, the same six copies all stay — the sweep runs and
/// decides there is nothing to do.
@MainActor @Test func withNoCeilingTheHistoryKeepsEverythingYouCopy() throws {
    let pb = privatePasteboard()
    let (monitor, repo, blobs, dir) = try makeEnvironment(pb)
    defer { try? FileManager.default.removeItem(at: dir) }

    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    prefs.limitsItems = false
    prefs.limitsAge = false
    let retention = Retention(repo: repo, blobs: blobs)
    monitor.onDidCapture = {
        try? retention.enforceItemCeiling(policy: prefs.retentionPolicy)
    }

    for i in 0..<6 {
        pb.clearContents()
        pb.setString("clip \(i)", forType: .string)
        try monitor.poll(now: t0.addingTimeInterval(Double(i)))
    }

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).count == 6)
}
