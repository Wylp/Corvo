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
    return (HistoryModel(repo: repo), repo, dir)
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
