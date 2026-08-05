import Foundation
import Testing
@testable import Corvo

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func makeModel() throws -> (HistoryModel, ItemRepository, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-hm-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    return (HistoryModel(repo: repo, prefs: prefs), repo, dir)
}

private func textItem(_ s: String) -> CapturedItem {
    CapturedItem(kind: .text, text: s, imageData: nil,
                 filePath: nil, url: nil, contentHash: s)
}

@MainActor @Test func reloadBringsTheNewestItemsFirst() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("old"), source: nil, now: t0)
    try repo.insert(textItem("recent"), source: nil, now: t0.addingTimeInterval(10))
    model.reload()

    #expect(model.items.map(\.text) == ["recent", "old"])
}

@MainActor @Test func theQueryFiltersAndResetsTheSelection() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("alpha"), source: nil, now: t0)
    try repo.insert(textItem("beta"), source: nil, now: t0.addingTimeInterval(1))
    model.reload()
    model.selectedIndex = 1

    model.query = "alpha"
    model.reload()

    #expect(model.items.map(\.text) == ["alpha"])
    #expect(model.selectedIndex == 0)
}

@MainActor @Test func moveStaysWithinBounds() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("a"), source: nil, now: t0)
    try repo.insert(textItem("b"), source: nil, now: t0.addingTimeInterval(1))
    model.reload()

    model.move(-1)
    #expect(model.selectedIndex == 0)
    model.move(1)
    model.move(1)
    model.move(1)
    #expect(model.selectedIndex == 1)
}

@MainActor @Test func theSourceListFollowsTheItems() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("a"), source: ItemSource(bundleId: "com.apple.Terminal",
                                                      name: "Terminal"), now: t0)
    model.reload()

    #expect(model.sources.map(\.name) == ["Terminal"])
}

/// Both sidebar filters hang off `didSet` hooks. If one of them stops calling
/// `reload()`, the sidebar stays clickable but does nothing and every other test
/// still passes — so this is the only thing standing between us and a dead filter.
@MainActor @Test func theSidebarFiltersActuallyNarrowTheList() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let warp = ItemSource(bundleId: "dev.warp.Warp-Stable", name: "Warp")
    let safari = ItemSource(bundleId: "com.apple.Safari", name: "Safari")
    let fromWarp = try repo.insert(textItem("a"), source: warp, now: t0)
    try repo.insert(textItem("b"), source: warp, now: t0.addingTimeInterval(1))
    try repo.insert(textItem("c"), source: safari, now: t0.addingTimeInterval(2))
    try repo.addTag(named: "keep", to: fromWarp)
    model.reload()

    #expect(model.items.count == 3)

    model.selectedSource = warp.bundleId
    #expect(model.items.map(\.text) == ["b", "a"])

    model.selectedSource = nil
    #expect(model.items.count == 3)

    let tagId = try #require(try repo.allTags().first?.id)
    model.selectedTag = tagId
    #expect(model.items.map(\.text) == ["a"])
}
