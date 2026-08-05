import Foundation
import Testing
import GRDB
@testable import Corvo

/// The seam between a rule that asks for a name and the thing that asks.
///
/// `NamePrompt` itself is not exercised here: it is a thin shell over
/// `UNUserNotificationCenter`, and a test that stood a protocol in front of that
/// would only prove the stand-in works. What is testable — and what actually
/// broke before this task — is that `poll` reports the tags asking for a name at
/// all, and that the answer survives the round trip into the column the panel
/// and the search read.
@MainActor
private func makeEnvironment() throws -> (FakePasteboard, ItemRepository, PasteboardMonitor, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-naming-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let pb = FakePasteboard()
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let monitor = PasteboardMonitor(pasteboard: pb, repo: repo,
                                    tracker: SourceTracker(), prefs: prefs)
    return (pb, repo, monitor, dir)
}

private func makeTag(_ repo: ItemRepository, name: String, pattern: String?,
                     promptsForName: Bool) throws {
    try repo.dbQueue.write { db in
        var tag = Tag(id: nil, name: name, color: nil, pattern: pattern,
                      sourceBundleId: nil, promptsForName: promptsForName)
        try tag.insert(db)
    }
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor @Test func aCaptureClaimedByAPromptingTagAsksForAName() throws {
    let (pb, repo, monitor, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try makeTag(repo, name: "claude", pattern: "claude --resume", promptsForName: true)

    var asked: [(Int64, String, String?)] = []
    monitor.onNeedsName = { id, tag, text in asked.append((id, tag.name, text)) }

    pb.copyText("claude --resume 550e8400-e29b-41d4-a716-446655440000")
    try monitor.poll(now: t0)

    #expect(asked.count == 1)
    #expect(asked.first?.1 == "claude")
    #expect(asked.first?.2 == "claude --resume 550e8400-e29b-41d4-a716-446655440000")

    // The prompt is about a row that is already stored and already tagged. A
    // notification that never arrives may cost the name, never the clipping.
    let items = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)
    #expect(items.count == 1)
    #expect(asked.first?.0 == items.first?.id)
    #expect(try repo.tags(forItem: items.first!.id!).map(\.name) == ["claude"])
}

/// The toggle is what decides, not the rule. A rule tag with the toggle off is
/// the ordinary case and must stay silent.
@MainActor @Test func aTagThatDoesNotAskForANameDoesNotPrompt() throws {
    let (pb, repo, monitor, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try makeTag(repo, name: "todo", pattern: "TODO", promptsForName: false)

    var asked = 0
    monitor.onNeedsName = { _, _, _ in asked += 1 }

    pb.copyText("a TODO in the middle")
    try monitor.poll(now: t0)

    #expect(asked == 0)
    #expect(try repo.tags(forItem:
        repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)[0].id!)
        .map(\.name) == ["todo"])
}

/// Two tags both asking about one clipping is still one question, and there is
/// one name to give in answer.
@MainActor @Test func twoPromptingTagsOnOneClippingAskOnce() throws {
    let (pb, repo, monitor, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try makeTag(repo, name: "claude", pattern: "claude", promptsForName: true)
    try makeTag(repo, name: "resume", pattern: "resume", promptsForName: true)

    var asked = 0
    monitor.onNeedsName = { _, _, _ in asked += 1 }

    pb.copyText("claude --resume abc")
    try monitor.poll(now: t0)

    #expect(asked == 1)
    // Both tags still land — only the prompting is deduplicated.
    let id = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)[0].id!
    #expect(try repo.tags(forItem: id).map(\.name) == ["claude", "resume"])
}

/// The privacy order is not negotiable. Concealed content is dropped before the
/// rules run, so it cannot be tagged — and therefore cannot raise a prompt that
/// would put a password manager's clipping on screen in a banner.
@MainActor @Test func concealedContentNeverReachesTheNamePrompt() throws {
    let (pb, repo, monitor, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    try makeTag(repo, name: "claude", pattern: "claude", promptsForName: true)

    var asked = 0
    monitor.onNeedsName = { _, _, _ in asked += 1 }

    pb.copyText("claude --resume secret")
    pb.availableTypes.append(.init(rawValue: "org.nspasteboard.ConcealedType"))
    try monitor.poll(now: t0)

    #expect(asked == 0)
    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10).isEmpty)
}

@MainActor @Test func namingAClippingMakesItSearchableByThatName() throws {
    let (pb, repo, monitor, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copyText("claude --resume 550e8400")
    try monitor.poll(now: t0)
    let id = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)[0].id!

    try repo.setLabel("auth refactor", for: id)

    #expect(try repo.search(text: "auth refactor", sourceBundleId: nil,
                            tagId: nil, limit: 10).map(\.id) == [id])
    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil,
                            limit: 10)[0].label == "auth refactor")
}

/// Clearing the field is the way back out of a name you regret, so a blank has
/// to reach the column as NULL. Stored as `""` it would leave the card showing
/// an empty name line, and `LIKE '%%'` would match every row in the history.
@MainActor @Test func aBlankNameClearsTheNameRatherThanStoringEmptyText() throws {
    let (pb, repo, monitor, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copyText("some clipping")
    try monitor.poll(now: t0)
    let id = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)[0].id!

    try repo.setLabel("a name", for: id)
    try repo.setLabel("   \n ", for: id)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 10)[0].label == nil)
}

/// The panel's half of the feature, reached through the same call the
/// notification's answer takes.
@MainActor @Test func theModelWritesTheNameAndRefreshesTheList() throws {
    let (pb, repo, monitor, dir) = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: dir) }

    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    pb.copyText("claude --resume 550e8400")
    try monitor.poll(now: t0)

    let model = HistoryModel(repo: repo, prefs: prefs)
    let id = try #require(model.items.first?.id)
    model.setLabel("auth refactor", forItemId: id)

    #expect(model.items.first?.label == "auth refactor")
}
