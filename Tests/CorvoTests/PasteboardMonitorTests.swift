import AppKit
import Foundation
import Testing
@testable import Corvo

final class FakePasteboard: PasteboardReading, @unchecked Sendable {
    var changeCount = 0
    var availableTypes: [NSPasteboard.PasteboardType] = []
    var stringsByType: [NSPasteboard.PasteboardType: String] = [:]
    var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    var urls: [URL] = []

    func data(forType t: NSPasteboard.PasteboardType) -> Data? { dataByType[t] }
    func string(forType t: NSPasteboard.PasteboardType) -> String? { stringsByType[t] }
    func fileURLs() -> [URL] { urls }

    func copyText(_ s: String) {
        changeCount += 1
        availableTypes = [.string]
        stringsByType = [.string: s]
        dataByType = [:]
        urls = []
    }

    /// `PasteboardMonitor.toPNG` hands back the bytes it was given when they do
    /// not decode, so a stand-in header is enough to drive a `.image` capture.
    func copyImage(_ data: Data = Data([0x89, 0x50, 0x4E, 0x47])) {
        changeCount += 1
        availableTypes = [.png]
        stringsByType = [:]
        dataByType = [.png: data]
        urls = []
    }

    func copyFile(_ path: String) {
        changeCount += 1
        availableTypes = [.fileURL]
        stringsByType = [:]
        dataByType = [:]
        urls = [URL(fileURLWithPath: path)]
    }
}

@MainActor
private func makeEnvironment() throws
    -> (FakePasteboard, ItemRepository, PasteboardMonitor, URL, SourceTracker, Preferences) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-mon-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let pb = FakePasteboard()
    let tracker = SourceTracker()
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let monitor = PasteboardMonitor(pasteboard: pb, repo: repo,
                                    tracker: tracker, prefs: prefs)
    return (pb, repo, monitor, dir, tracker, prefs)
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor @Test func capturesTextWhenTheChangeCountChanges() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copyText("hello")
    try monitor.poll(now: t0)

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(items.map(\.text) == ["hello"])
}

@MainActor @Test func doesNotRecaptureWhenTheChangeCountIsUnchanged() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copyText("hello")
    try monitor.poll(now: t0)
    try monitor.poll(now: t0.addingTimeInterval(0.3))

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(items.count == 1)
}

@MainActor @Test func discardsContentMarkedAsConcealed() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copyText("secret-password")
    pb.availableTypes.append(.init(rawValue: "org.nspasteboard.ConcealedType"))
    try monitor.poll(now: t0)

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(items.isEmpty)
}

@MainActor @Test func discardsTransientContent() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copyText("temporary")
    pb.availableTypes.append(.init(rawValue: "org.nspasteboard.TransientType"))
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

@MainActor @Test func discardsContentFromABlocklistedApp() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    monitor.prefs.blocklist = ["com.apple.keychainaccess"]
    pb.copyText("secret")
    pb.availableTypes.append(.init(rawValue: "org.nspasteboard.source"))
    pb.stringsByType[.init(rawValue: "org.nspasteboard.source")] = "com.apple.keychainaccess"
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

@MainActor @Test func discardsEmptyText() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copyText("   \n  ")
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

// The path that actually runs: almost no app declares its own source through
// "org.nspasteboard.source" — the real source comes from SourceTracker (system
// focus). The two tests below cover that path, one at a time, and the second is
// the positive control: without it, the first would pass even with `poll`
// broken and storing nothing.
@MainActor @Test func discardsWhenTheInferredSourceIsBlocklisted() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = ["com.agilebits.onepassword7"]
    tracker.recordActivation(
        ItemSource(bundleId: "com.agilebits.onepassword7", name: "1Password"), at: t0)
    pb.copyText("secret")
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

@MainActor @Test func storesWhenTheInferredSourceIsNotBlocklisted() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = ["com.agilebits.onepassword7"]
    tracker.recordActivation(ItemSource(bundleId: "com.apple.Safari", name: "Safari"), at: t0)
    pb.copyText("normal text")
    try monitor.poll(now: t0)

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(items.map(\.text) == ["normal text"])
    #expect(items.map(\.sourceBundleId) == ["com.apple.Safari"])
}

// Ties `Blocklist` to the code that actually enforces it. `Blocklist.entries`
// keeps a malformed line rather than dropping it, so the screen can warn about
// it — this proves that malformed line, sitting first in the list, does not
// stop the valid line next to it from still blocking here.
@MainActor @Test func aMalformedBlocklistLineDoesNotDisarmTheValidOnesAroundIt() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = Blocklist.entries("Safari\ncom.agilebits.onepassword7")
    tracker.recordActivation(
        ItemSource(bundleId: "com.agilebits.onepassword7", name: "1Password"), at: t0)
    pb.copyText("secret")
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

// Covers privacy fix 1: the declared source must not mask the inferred one in
// the blocklist check. The tracker points at a blocked app; the pasteboard
// declares an id that is not blocklisted. Before the fix (`source = declared ??
// inferred` evaluated on its own) this test failed — the declared id won and
// the item was stored.
@MainActor @Test func aDeclaredSourceDoesNotMaskTheInferredOneInTheBlocklist() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = ["com.agilebits.onepassword7"]
    tracker.recordActivation(
        ItemSource(bundleId: "com.agilebits.onepassword7", name: "1Password"), at: t0)
    pb.copyText("secret")
    pb.availableTypes.append(.init(rawValue: "org.nspasteboard.source"))
    pb.stringsByType[.init(rawValue: "org.nspasteboard.source")] = "com.apple.Safari"
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

/// The seam between what the user pastes into the blocklist field and the code
/// that enforces it. Splitting on the `Character` "\n" left a `\r` glued to every
/// entry of a CRLF paste, so no entry equalled a real bundle id and the whole
/// privacy control went quiet — no error, nothing on screen, just a list that
/// stopped blocking.
///
/// The other end-to-end blocklist test uses plain `\n` and passes on that broken
/// code too. This one is the guard for the line ending.
@MainActor @Test func aBlocklistPastedWithWindowsLineEndingsStillBlocks() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = Blocklist.entries("com.apple.Safari\r\ncom.agilebits.onepassword7\r\n")

    #expect(prefs.blocklist == ["com.apple.Safari", "com.agilebits.onepassword7"])

    // Both ends of the list, so a stray `\r` on either one is caught.
    for bundleId in ["com.apple.Safari", "com.agilebits.onepassword7"] {
        tracker.recordActivation(ItemSource(bundleId: bundleId, name: bundleId), at: t0)
        pb.copyText("secret from \(bundleId)")
        try monitor.poll(now: t0)
    }

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

// MARK: - Telling retention that something was captured

@MainActor @Test func aStoredClippingReportsItself() throws {
    let (pb, _, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    var captures = 0
    monitor.onDidCapture = { captures += 1 }

    pb.copyText("hello")
    try monitor.poll(now: t0)
    #expect(captures == 1)

    // A poll with nothing new is not a capture.
    try monitor.poll(now: t0.addingTimeInterval(0.3))
    #expect(captures == 1)
}

/// Everything that was discarded before the insert. Firing here would run a
/// retention sweep for a clipping that was never stored — harmless today, and a
/// lie about what the callback means.
@MainActor @Test func contentThatWasNeverStoredDoesNotReportACapture() throws {
    let (pb, _, monitor, dir, _, prefs) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    var captures = 0
    monitor.onDidCapture = { captures += 1 }

    pb.copyText("secret-password")
    pb.availableTypes.append(.init(rawValue: "org.nspasteboard.ConcealedType"))
    try monitor.poll(now: t0)
    #expect(captures == 0)

    prefs.blocklist = ["com.apple.Terminal"]
    pb.copyText("from a blocked app")
    pb.stringsByType[.init(rawValue: "org.nspasteboard.source")] = "com.apple.Terminal"
    try monitor.poll(now: t0.addingTimeInterval(1))
    #expect(captures == 0)

    // Nothing capturable at all: a change count that moved with no usable type.
    pb.changeCount += 1
    pb.availableTypes = []
    pb.stringsByType = [:]
    try monitor.poll(now: t0.addingTimeInterval(2))
    #expect(captures == 0)
}

// MARK: - Image decompression bombs

/// A bilevel TIFF: one bit per pixel, so a payload declaring tens of millions of
/// pixels costs almost nothing to build here — which is the whole shape of the
/// attack. The real measurement is worse than anything this test can afford to
/// allocate: a 4,67 MB RGBA TIFF of 16 000 × 16 000 decoded to 998 MB of RSS and
/// held the main thread for 1,396 s, inside a poller that fires every 0,3 s.
private func oversizedImage(width: Int, height: Int) -> Data {
    let bytesPerRow = (width + 7) / 8
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 1, samplesPerPixel: 1, hasAlpha: false,
                               isPlanar: false, colorSpaceName: .deviceWhite,
                               bytesPerRow: bytesPerRow, bitsPerPixel: 1)!
    memset(rep.bitmapData!, 0, bytesPerRow * height)
    return rep.representation(using: .tiff,
                              properties: [.compressionMethod:
                                            NSNumber(value: NSBitmapImageRep.TIFFCompression.lzw.rawValue)])!
}

/// Past the ceiling the capture is dropped whole. Not stored small, not stored
/// truncated: a blob is what makes this bomb persistent — it would be decoded
/// again on every redraw of the card — so it must never reach the disk.
@MainActor @Test func discardsAnImageThatDeclaresMorePixelsThanTheCeiling() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 48 MPx against a 40 MPx ceiling, in under a kilobyte of pasteboard.
    let bomb = oversizedImage(width: 8_000, height: 6_000)
    #expect(bomb.count < 100_000)

    pb.changeCount += 1
    pb.availableTypes = [.tiff]
    pb.dataByType = [.tiff: bomb]
    pb.stringsByType = [:]
    pb.urls = []

    let started = Date()
    try monitor.poll(now: t0)
    // Refused from the header, so no decode is paid for. The unguarded path
    // decoded this same payload in 0,323 s and a real RGBA bomb in 1,396 s.
    #expect(Date().timeIntervalSince(started) < 0.2)

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(items.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

/// The other direction: the ceiling is calibrated to clear any real screen
/// capture, so an image under it still has to be stored.
@MainActor @Test func stillCapturesAnImageUnderTheCeiling() throws {
    let (pb, repo, monitor, dir, _, _) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 32 MPx — larger than a 6K display grab, and comfortably under 40 MPx.
    pb.changeCount += 1
    pb.availableTypes = [.tiff]
    pb.dataByType = [.tiff: oversizedImage(width: 8_000, height: 4_000)]
    pb.stringsByType = [:]
    pb.urls = []

    try monitor.poll(now: t0)

    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(items.map(\.kind) == [.image])
    #expect(items.first?.blobPath != nil)
}
