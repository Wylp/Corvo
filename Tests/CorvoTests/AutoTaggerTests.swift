import Foundation
import Testing
import GRDB
@testable import Corvo

/// In-memory database, temporary blob directory. Nothing here touches the
/// database the running app owns.
@MainActor
private func makeTagger() throws -> (AutoTagger, ItemRepository, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-autotag-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    return (AutoTagger(repo: repo, prefs: prefs), repo, dir)
}

@discardableResult
private func insertTag(_ repo: ItemRepository, name: String, pattern: String? = nil,
                       sourceBundleId: String? = nil,
                       promptsForName: Bool = false) throws -> Int64 {
    try repo.dbQueue.write { db in
        var tag = Tag(id: nil, name: name, color: nil, pattern: pattern,
                      sourceBundleId: sourceBundleId, promptsForName: promptsForName)
        try tag.insert(db)
        return tag.id!
    }
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func insertItem(_ repo: ItemRepository, _ text: String,
                        source: ItemSource? = nil) throws -> Int64 {
    try repo.insert(CapturedItem(kind: .text, text: text, imageData: nil,
                                 filePath: nil, url: nil, contentHash: text),
                    source: source, now: t0)
}

@MainActor @Test func appliesAPatternTagToAMatchingItem() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "todo", pattern: "TODO")
    let id = try insertItem(repo, "a TODO in the middle")

    try tagger.apply(toItem: id, kind: .text, text: "a TODO in the middle", sourceBundleId: nil)
    #expect(try repo.tags(forItem: id).map(\.name) == ["todo"])
}

@MainActor @Test func leavesANonMatchingItemAlone() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "todo", pattern: "TODO")
    let id = try insertItem(repo, "nothing here")

    try tagger.apply(toItem: id, kind: .text, text: "nothing here", sourceBundleId: nil)
    #expect(try repo.tags(forItem: id).isEmpty)
}

/// The tag that carries no rule is the ordinary manual tag every earlier task
/// built. Auto-tagging must not start attaching it to everything.
@MainActor @Test func neverAppliesATagThatCarriesNoRule() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "manual")
    let id = try insertItem(repo, "anything at all")

    try tagger.apply(toItem: id, kind: .text, text: "anything at all", sourceBundleId: nil)
    #expect(try repo.tags(forItem: id).isEmpty)
}

@MainActor @Test func appliesEveryRuleThatMatchesAndOnlyThose() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "figma", sourceBundleId: "com.figma.Desktop")
    try insertTag(repo, name: "sql", pattern: "SELECT")
    try insertTag(repo, name: "terminal-sql", pattern: "SELECT",
                  sourceBundleId: "com.apple.Terminal")
    try insertTag(repo, name: "manual")

    let figma = ItemSource(bundleId: "com.figma.Desktop", name: "Figma")
    let id = try insertItem(repo, "SELECT 1", source: figma)

    try tagger.apply(toItem: id, kind: .text, text: "SELECT 1", sourceBundleId: figma.bundleId)
    #expect(try repo.tags(forItem: id).map(\.name) == ["figma", "sql"])
}

/// A pattern the user typed wrong must not stop the rules that follow it. The
/// broken rule is inserted first on purpose — `allTags` orders by name.
@MainActor @Test func aBrokenPatternDoesNotStopTheOtherRules() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "aaa-broken", pattern: "[unclosed")
    try insertTag(repo, name: "zzz-works", pattern: "keep")
    let id = try insertItem(repo, "keep going")

    try tagger.apply(toItem: id, kind: .text, text: "keep going", sourceBundleId: nil)
    #expect(try repo.tags(forItem: id).map(\.name) == ["zzz-works"])
}

/// Applying twice is what a re-copy of the same content does. The association
/// is a composite primary key, so the second write must be absorbed rather than
/// throw.
@MainActor @Test func applyingTwiceDoesNotDuplicateTheAssociation() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "todo", pattern: "TODO")
    let id = try insertItem(repo, "TODO twice")

    try tagger.apply(toItem: id, kind: .text, text: "TODO twice", sourceBundleId: nil)
    try tagger.apply(toItem: id, kind: .text, text: "TODO twice", sourceBundleId: nil)
    #expect(try repo.tags(forItem: id).map(\.name) == ["todo"])
}

/// The return value is the prompting list, not the applied list: both tags are
/// attached, only the one asking for a name comes back. Nothing here notifies
/// anyone; the prompt the toggle implies does not exist yet.
@MainActor @Test func returnsOnlyTheMatchedTagsThatAskForAName() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "quiet", pattern: "TODO")
    try insertTag(repo, name: "asks", pattern: "TODO", promptsForName: true)
    let id = try insertItem(repo, "TODO both")

    let promptable = try tagger.apply(toItem: id, kind: .text, text: "TODO both", sourceBundleId: nil)
    #expect(promptable.map(\.name) == ["asks"])
    #expect(try repo.tags(forItem: id).map(\.name) == ["asks", "quiet"])
}

// MARK: - The monitor's ordering

/// The whole privacy argument in one test: concealed content is discarded
/// before the insert, so no row exists for a rule to tag. A rule matching
/// everything from a source proves it — if auto-tagging ever moved ahead of the
/// guards, this would find a tagged row.
@MainActor @Test func concealedContentNeverReachesTheRules() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-autotag-mon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let pb = FakePasteboard()
    let tracker = SourceTracker()
    let monitor = PasteboardMonitor(
        pasteboard: pb, repo: repo, tracker: tracker,
        prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))

    try insertTag(repo, name: "everything", pattern: ".")
    tracker.recordActivation(
        ItemSource(bundleId: "com.agilebits.onepassword7", name: "1Password"), at: t0)

    pb.copyText("secret-password")
    pb.availableTypes.append(.init(rawValue: "org.nspasteboard.ConcealedType"))
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
    let associations = try repo.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemTag")
    }
    #expect(associations == 0)
}

/// The positive control for the test above, and the proof that `poll` calls the
/// tagger at all: the same rule, without the concealed marker, does tag.
@MainActor @Test func aCaptureThroughPollGetsItsRuleTags() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-autotag-mon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let pb = FakePasteboard()
    let tracker = SourceTracker()
    let monitor = PasteboardMonitor(
        pasteboard: pb, repo: repo, tracker: tracker,
        prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))

    try insertTag(repo, name: "sql", pattern: "SELECT")
    try insertTag(repo, name: "safari", sourceBundleId: "com.apple.Safari")
    tracker.recordActivation(ItemSource(bundleId: "com.apple.Safari", name: "Safari"), at: t0)

    pb.copyText("SELECT 1")
    try monitor.poll(now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 50).first)
    #expect(try repo.tags(forItem: item.id!).map(\.name) == ["safari", "sql"])
}

// MARK: - What a pattern is allowed to see

/// Every capture carries text, and an image's is the internal label `"Image"`.
/// Handed to a rule unfiltered, a tag patterned on `Image` — or `age`, or `.` —
/// would claim every screenshot the user ever copies.
@MainActor @Test func aPatternNeverMatchesAnImagesInternalLabel() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "images", pattern: "Image")
    let id = try repo.insert(
        CapturedItem(kind: .image, text: "Image", imageData: Data([0x89, 0x50]),
                     filePath: nil, url: nil, contentHash: "img"),
        source: nil, now: t0)

    try tagger.apply(toItem: id, kind: .image, text: "Image", sourceBundleId: nil)
    #expect(try repo.tags(forItem: id).isEmpty)
}

/// The other half of the rule: an image is not unreachable, it is reachable only
/// by a rule that asks about its source. "Everything from Figma" still works.
@MainActor @Test func aSourceOnlyRuleStillTagsAnImage() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "figma", sourceBundleId: "com.figma.Desktop")
    let id = try repo.insert(
        CapturedItem(kind: .image, text: "Image", imageData: Data([0x89, 0x50]),
                     filePath: nil, url: nil, contentHash: "img"),
        source: ItemSource(bundleId: "com.figma.Desktop", name: "Figma"), now: t0)

    try tagger.apply(toItem: id, kind: .image, text: "Image",
                     sourceBundleId: "com.figma.Desktop")
    #expect(try repo.tags(forItem: id).map(\.name) == ["figma"])
}

/// A file's text is its own name, which is the legitimate use the image rule
/// must not take away.
@MainActor @Test func aPatternMatchesAFilesName() throws {
    let (tagger, repo, dir) = try makeTagger()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "keys", pattern: #"\.pem$"#)
    let id = try repo.insert(
        CapturedItem(kind: .file, text: "key.pem", imageData: nil,
                     filePath: "/tmp/key.pem", url: nil, contentHash: "pem"),
        source: nil, now: t0)

    try tagger.apply(toItem: id, kind: .file, text: "key.pem", sourceBundleId: nil)
    #expect(try repo.tags(forItem: id).map(\.name) == ["keys"])
}

// MARK: - The same guarantee, end to end

@MainActor
private func makeMonitor() throws -> (FakePasteboard, ItemRepository, PasteboardMonitor, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-autotag-mon-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let pb = FakePasteboard()
    let monitor = PasteboardMonitor(
        pasteboard: pb, repo: repo, tracker: SourceTracker(),
        prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    return (pb, repo, monitor, dir)
}

/// The unit tests above prove `AutoTagger` filters; this proves `poll` hands it
/// the kind so the filter is reached at all. Both rules are present at once, so
/// the same capture answers both questions: the pattern must miss, the
/// source-only rule must hit.
@MainActor @Test func anImageCapturedThroughPollEscapesPatternRulesOnly() throws {
    let (pb, repo, monitor, dir) = try makeMonitor()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "everything", pattern: ".")
    try insertTag(repo, name: "screens", sourceBundleId: "com.apple.screencapture")
    pb.stringsByType[PasteboardMonitor.sourceType] = "com.apple.screencapture"
    pb.copyImage()
    pb.stringsByType[PasteboardMonitor.sourceType] = "com.apple.screencapture"
    try monitor.poll(now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 50).first)
    #expect(item.kind == .image)
    #expect(try repo.tags(forItem: item.id!).map(\.name) == ["screens"])
}

@MainActor @Test func aFileCapturedThroughPollIsMatchedOnItsName() throws {
    let (pb, repo, monitor, dir) = try makeMonitor()
    defer { try? FileManager.default.removeItem(at: dir) }

    try insertTag(repo, name: "keys", pattern: #"\.pem$"#)
    try insertTag(repo, name: "certs", pattern: #"\.crt$"#)
    pb.copyFile("/tmp/corvo-test/key.pem")
    try monitor.poll(now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 50).first)
    #expect(item.kind == .file)
    #expect(try repo.tags(forItem: item.id!).map(\.name) == ["keys"])
}
