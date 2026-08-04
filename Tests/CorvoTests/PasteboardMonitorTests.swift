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
