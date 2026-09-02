import Foundation
import Testing
@testable import Corvo

/// Deleting a tag while the panel is filtering by it.
///
/// The database was never the problem — `ItemRepositoryTests` covers the write,
/// and it passed the whole time this was broken. What failed was the screen: the
/// row stayed, so from the outside "delete" looked like it did nothing, which is
/// how it was reported.
///
/// Worth its own file because of how it broke. Nobody edited `deleteTag`. It was
/// written to clear the filter and let the `didSet` reload, `reload()` was later
/// split so the panel's opening did not re-read both sidebars, and the `didSet`
/// quietly became the half that does not re-read tags. A comment two lines up
/// still said otherwise.
@MainActor
private func model(withTagNamed name: String) throws -> (HistoryModel, ItemRepository, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-tagdel-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let id = try repo.insert(CapturedItem(kind: .text, text: "hello", imageData: nil,
                                          filePath: nil, url: nil, contentHash: "h1"),
                             source: ItemSource(bundleId: "a.b", name: "A"), now: Date())
    try repo.addTag(named: name, to: id)
    let model = HistoryModel(repo: repo,
                             prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    model.reload()
    return (model, repo, dir)
}

/// The regression. Clicking a tag in the strip sets this filter, and deleting
/// that tag from the manager is a perfectly ordinary thing to do next.
@Test @MainActor func deletingTheTagBeingFilteredByRemovesItFromTheList() throws {
    let (model, repo, dir) = try model(withTagNamed: "Work")
    defer { try? FileManager.default.removeItem(at: dir) }
    let tag = try #require(model.tags.first)

    model.selectedTag = tag.id
    model.deleteTag(tag)

    #expect(try repo.allTags().isEmpty, "the write is not what broke")
    #expect(model.tags.isEmpty, "the tag is gone from the database and still on screen")
}

/// The filter has to go too. Left pointing at a deleted id it matches nothing,
/// so the panel shows an empty history and no way to see why.
@Test @MainActor func deletingTheFilteredTagClearsTheFilter() throws {
    let (model, _, dir) = try model(withTagNamed: "Work")
    defer { try? FileManager.default.removeItem(at: dir) }
    let tag = try #require(model.tags.first)

    model.selectedTag = tag.id
    model.deleteTag(tag)

    #expect(model.selectedTag == nil)
    #expect(model.items.count == 1, "the clipping outlives the tag")
}

/// The path that always worked, pinned so a fix for the one above cannot break
/// it: with no filter set, `deleteTag` reloads directly.
@Test @MainActor func deletingAnUnfilteredTagStillRemovesIt() throws {
    let (model, _, dir) = try model(withTagNamed: "Work")
    defer { try? FileManager.default.removeItem(at: dir) }
    let tag = try #require(model.tags.first)

    #expect(model.selectedTag == nil)
    model.deleteTag(tag)

    #expect(model.tags.isEmpty)
}

/// Deleting one tag while filtering by another leaves that filter alone. The
/// clearing is for the tag that stopped existing, not for whichever one happens
/// to be selected.
@Test @MainActor func deletingAnotherTagLeavesTheFilterAlone() throws {
    let (model, repo, dir) = try model(withTagNamed: "Work")
    defer { try? FileManager.default.removeItem(at: dir) }
    let other = try repo.saveTag(Tag(id: nil, name: "Receipts", color: nil))
    model.reload()
    let work = try #require(model.tags.first { $0.name == "Work" })

    model.selectedTag = work.id
    model.deleteTag(other)

    #expect(model.selectedTag == work.id, "the surviving filter was cleared")
    #expect(model.tags.map(\.name) == ["Work"])
}
