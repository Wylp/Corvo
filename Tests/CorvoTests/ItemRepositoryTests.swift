import Foundation
import Testing
import GRDB
@testable import Corvo

private func makeRepo() throws -> (ItemRepository, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-repo-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    return (repo, dir)
}

private func textItem(_ s: String) -> CapturedItem {
    CapturedItem(kind: .text, text: s, imageData: nil,
                 filePath: nil, url: nil, contentHash: s)
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func insertsAndSearches() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("hello world"),
                    source: ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
                    now: t0)

    let found = try repo.search(text: "world", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(found.count == 1)
    #expect(found[0].sourceName == "Slack")
}

@Test func repeatedContentMovesToTheTopWithoutDuplicatingOrLosingTagOrPin() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = try repo.insert(textItem("repeated"), source: nil, now: t0)
    try repo.addTag(named: "work", to: id)
    try repo.setPinned(id, true)

    let idAgain = try repo.insert(textItem("repeated"), source: nil,
                                  now: t0.addingTimeInterval(60))

    #expect(idAgain == id)
    let all = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(all.count == 1)
    #expect(all[0].pinned == true)
    #expect(all[0].createdAt == t0.addingTimeInterval(60))
    #expect(try repo.tags(forItem: id).map(\.name) == ["work"])
}

@Test func textSearchAlsoMatchesTheSourceName() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("SELECT 1"),
                    source: ItemSource(bundleId: "com.apple.Terminal", name: "Terminal"),
                    now: t0)
    try repo.insert(textItem("something else"),
                    source: ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
                    now: t0)

    let found = try repo.search(text: "slack", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(found.count == 1)
    #expect(found[0].text == "something else")
}

/// A named item is findable by any word of the name, not only by its content —
/// naming a clipping is worthless if it does not make it easier to find again.
@Test func textSearchAlsoMatchesTheNameTheUserGaveTheItem() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = try repo.insert(textItem("x-api-key: 0f3a"), source: nil, now: t0)
    try repo.insert(textItem("unrelated"), source: nil, now: t0)
    try repo.dbQueue.write { db in
        try db.execute(sql: "UPDATE item SET label = ? WHERE id = ?",
                       arguments: ["Claude session about GRDB", id])
    }

    for query in ["GRDB", "Claude", "session"] {
        #expect(try repo.search(text: query, sourceBundleId: nil, tagId: nil, limit: 50)
            .map(\.id) == [id])
    }
    // The content still matches on its own.
    #expect(try repo.search(text: "x-api-key", sourceBundleId: nil, tagId: nil, limit: 50)
        .map(\.id) == [id])
}

@Test func sourceAndTagFiltersCombineWithAnd() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let slack = ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
    let a = try repo.insert(textItem("a"), source: slack, now: t0)
    _ = try repo.insert(textItem("b"), source: slack, now: t0)
    _ = try repo.insert(textItem("c"),
                        source: ItemSource(bundleId: "com.apple.Terminal", name: "Terminal"),
                        now: t0)
    try repo.addTag(named: "important", to: a)
    let tagId = try #require(try repo.allTags().first?.id)

    let sourceOnly = try repo.search(text: "", sourceBundleId: slack.bundleId,
                                     tagId: nil, limit: 50)
    #expect(sourceOnly.count == 2)

    let sourceAndTag = try repo.search(text: "", sourceBundleId: slack.bundleId,
                                       tagId: tagId, limit: 50)
    #expect(sourceAndTag.map(\.text) == ["a"])
}

@Test func imageGoesToDiskNotToTheDatabase() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let captured = CapturedItem(kind: .image, text: "Image", imageData: png,
                                filePath: nil, url: nil, contentHash: "hashpng")
    let id = try repo.insert(captured, source: nil, now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 50).first)
    #expect(item.id == id)
    #expect(item.blobPath == "hashpng.png")
    #expect(try repo.liveBlobPaths() == ["hashpng.png"])
}

@Test func sourceSummaryCountsItemsPerApp() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let slack = ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
    try repo.insert(textItem("a"), source: slack, now: t0)
    try repo.insert(textItem("b"), source: slack, now: t0)
    try repo.insert(textItem("c"),
                    source: ItemSource(bundleId: "com.apple.Terminal", name: "Terminal"),
                    now: t0)

    let sources = try repo.sources()
    #expect(sources.count == 2)
    #expect(sources[0].name == "Slack")
    #expect(sources[0].count == 2)
}

/// All three filters at once. It exists because `search` builds SQL by
/// concatenation with positional arguments: the tag JOIN's `?` precedes the
/// WHERE ones, and reordering the blocks would return the wrong result without
/// throwing. No other test combines all three, so this is the only net for it.
@Test func searchCombinesAllThreeFiltersAtOnce() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let slack = ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
    let term = ItemSource(bundleId: "com.apple.Terminal", name: "Terminal")

    let zero = try repo.insert(textItem("alpha zero"), source: slack, now: t0)
    let one = try repo.insert(textItem("alpha one"), source: slack, now: t0.addingTimeInterval(10))
    let six = try repo.insert(textItem("alpha six"), source: slack, now: t0.addingTimeInterval(300))
    _ = try repo.insert(textItem("alpha two"), source: slack, now: t0.addingTimeInterval(400))
    let three = try repo.insert(textItem("alpha three"), source: term, now: t0.addingTimeInterval(500))
    let four = try repo.insert(textItem("beta four"), source: slack, now: t0.addingTimeInterval(600))
    let five = try repo.insert(textItem("alpha five"), source: slack, now: t0.addingTimeInterval(700))

    for id in [zero, one, six, three, four] { try repo.addTag(named: "work", to: id) }
    try repo.addTag(named: "personal", to: five)
    try repo.setPinned(zero, true)

    let work = try #require(try repo.allTags().first(where: { $0.name == "work" })?.id)
    let personal = try #require(try repo.allTags().first(where: { $0.name == "personal" })?.id)

    #expect(try repo.search(text: "alpha", sourceBundleId: slack.bundleId,
                            tagId: work, limit: 50).map(\.text)
            == ["alpha zero", "alpha six", "alpha one"])

    #expect(try repo.search(text: "alpha", sourceBundleId: slack.bundleId,
                            tagId: work, limit: 2).map(\.text)
            == ["alpha zero", "alpha six"])

    // "slack" matches the sourceName, so "beta four" belongs in the result.
    #expect(try repo.search(text: "slack", sourceBundleId: slack.bundleId,
                            tagId: work, limit: 50).map(\.text)
            == ["alpha zero", "beta four", "alpha six", "alpha one"])

    #expect(try repo.search(text: "alpha", sourceBundleId: term.bundleId,
                            tagId: personal, limit: 50).isEmpty)
}

/// The bug this fixes, in the shape it was reported: searching "g cloud" over a
/// history holding `gcloud auth login` found nothing, because the space between
/// the words was being demanded of the stored text too.
///
/// The words also have to work in either order and across the three columns the
/// search spans, since none of that is what the person typing them is thinking
/// about.
@Test func searchingSeveralWordsFindsThemAnywhereAndInAnyOrder() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-search-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    let warp = ItemSource(bundleId: "dev.warp.Warp-Stable", name: "Warp")

    func text(_ s: String) -> CapturedItem {
        CapturedItem(kind: .text, text: s, imageData: nil,
                     filePath: nil, url: nil, contentHash: s)
    }
    _ = try repo.insert(text("gcloud auth login"), source: warp, now: t)
    _ = try repo.insert(text("cloud storage bucket"), source: warp,
                        now: t.addingTimeInterval(1))
    _ = try repo.insert(text("nothing to do with either"), source: warp,
                        now: t.addingTimeInterval(2))

    func hits(_ q: String) throws -> Set<String> {
        Set(try repo.search(text: q, sourceBundleId: nil, tagId: nil, limit: 200)
            .compactMap(\.text))
    }

    // The reported case. A single letter is a weak word and "storage" carries a
    // "g" of its own, so this is asserted as reaching the clipping rather than
    // as reaching only it — what was broken is that it reached nothing at all.
    #expect(try hits("g cloud").contains("gcloud auth login"))
    #expect(try !hits("g cloud").contains("nothing to do with either"))
    // Order is not part of what was asked for.
    #expect(try hits("login gcloud") == ["gcloud auth login"])
    // Every word has to be there, so a second one narrows instead of widening.
    #expect(try hits("cloud") == ["gcloud auth login", "cloud storage bucket"])
    #expect(try hits("cloud bucket") == ["cloud storage bucket"])
    // One word in the content, the other in the app that produced it.
    #expect(try hits("warp bucket") == ["cloud storage bucket"])
    #expect(try hits("cloud nonsense").isEmpty)
    // Whitespace alone is not a filter.
    #expect(try hits("   ").count == 3)
}
