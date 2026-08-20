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

/// The three things the sheet's list has to get right, and the reason it exists
/// is the middle one: the whole point of offering the tags is that reaching one
/// must not depend on remembering how it was capitalised.
@MainActor @Test func theTagsOfferedAreTheOnesThisClippingCouldStillTake() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = try repo.insert(textItem("a"), source: nil, now: t0)
    try repo.addTag(named: "Work", to: id)
    try repo.addTag(named: "Receipts", to: id)
    try repo.addTag(named: "Personal", to: try repo.insert(textItem("b"), source: nil,
                                                           now: t0.addingTimeInterval(1)))
    model.reload()
    let item = try #require(model.items.first { $0.text == "a" })

    // Nothing typed: everything the clipping does not already carry.
    #expect(model.tagChoices(for: item, matching: "").map(\.name) == ["Personal"])

    // A tag it does not carry, reached without matching the capitals.
    #expect(model.tagChoices(for: item, matching: "pers").map(\.name) == ["Personal"])

    // A tag it already carries is not offered a second time.
    #expect(model.tagChoices(for: item, matching: "work").isEmpty)
}

/// The tag filed under most comes first, because that is the one likely to be
/// wanted again. Name settles ties so the order does not move between openings.
@MainActor @Test func theTagsOfferedComeMostUsedFirst() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = try repo.insert(textItem("a"), source: nil, now: t0)
    let b = try repo.insert(textItem("b"), source: nil, now: t0.addingTimeInterval(1))
    let bare = try repo.insert(textItem("c"), source: nil, now: t0.addingTimeInterval(2))
    // "zebra" on two, "alpha" on one, "never" on none.
    try repo.addTag(named: "zebra", to: a)
    try repo.addTag(named: "zebra", to: b)
    try repo.addTag(named: "alpha", to: a)
    try repo.saveTag(Tag(id: nil, name: "never", color: nil))
    model.reload()
    let item = try #require(model.items.first { $0.id == bare })

    // Alphabetical order would have put this exactly backwards.
    #expect(model.tagChoices(for: item, matching: "").map(\.name) == ["zebra", "alpha", "never"])
}

/// ↑/↓ in the tag sheet. `nil` is the field, and getting back to it is what
/// keeps ⏎ able to mean "make the tag I just typed".
@Test func theHighlightEntersTheListAndComesBackOutTheTop() {
    // From the field: ↓ takes the top, ↑ takes the bottom.
    #expect(HistoryModel.highlight(nil, step: 1, count: 3) == 0)
    #expect(HistoryModel.highlight(nil, step: -1, count: 3) == 2)
    // Off the top is the field again; off the bottom stays put rather than wrapping.
    #expect(HistoryModel.highlight(0, step: -1, count: 3) == nil)
    #expect(HistoryModel.highlight(2, step: 1, count: 3) == 2)
    #expect(HistoryModel.highlight(1, step: 1, count: 3) == 2)
    // Nothing to walk.
    #expect(HistoryModel.highlight(nil, step: 1, count: 0) == nil)
}

/// Taking a tag off one clipping leaves the tag itself, and every other
/// clipping's link to it, alone. The destructive one is `deleteTag`.
@MainActor @Test func removingATagFromAClippingKeepsTheTagAndTheOtherClippings() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = try repo.insert(textItem("a"), source: nil, now: t0)
    let b = try repo.insert(textItem("b"), source: nil, now: t0.addingTimeInterval(1))
    try repo.addTag(named: "shared", to: a)
    try repo.addTag(named: "shared", to: b)
    model.reload()
    let item = try #require(model.items.first { $0.id == a })
    let tag = try #require(model.tags.first)

    model.removeTag(tag, from: item)

    #expect(try repo.tags(forItem: a).isEmpty)
    #expect(try repo.tags(forItem: b).map(\.name) == ["shared"])
    #expect(model.tags.map(\.name) == ["shared"])
    // And it is offered again, which is the way back from a removal by mistake.
    #expect(model.tagChoices(for: model.items.first { $0.id == a }, matching: "")
        .map(\.name) == ["shared"])
}

/// ⌘↑/⌘↓ down the sidebar. The two lists it draws are one column to the
/// keyboard, with "everything" at the top and the tags after the apps.
@MainActor @Test func eachPairOfKeysWalksItsOwnAxisAndLeavesTheOtherAlone() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let warp = ItemSource(bundleId: "dev.warp.Warp-Stable", name: "Warp")
    let tagged = try repo.insert(textItem("a"), source: warp, now: t0)
    try repo.addTag(named: "keep", to: tagged)
    model.reload()
    let tagId = try #require(model.tags.first?.id)

    // ⌘↓ down the apps.
    #expect(model.selectedSource == nil)
    #expect(model.selectedTag == nil)
    model.moveFilter(1)
    #expect(model.selectedSource == warp.bundleId)
    // The end of the column, not the top of it again.
    model.moveFilter(1)
    #expect(model.selectedSource == warp.bundleId)

    // ⌘→ along the tags, with the app filter still on. This is the pair of
    // filters that used to be reachable only with the mouse: one pair of keys
    // could not hold two positions, and landing on either cleared the other.
    model.moveTagFilter(1)
    #expect(model.selectedTag == tagId)
    #expect(model.selectedSource == warp.bundleId)
    model.moveTagFilter(1)
    #expect(model.selectedTag == tagId)

    // And back off each axis independently.
    model.moveTagFilter(-1)
    #expect(model.selectedTag == nil)
    #expect(model.selectedSource == warp.bundleId)
    model.moveFilter(-1)
    #expect(model.selectedSource == nil)
    model.moveFilter(-1)
    #expect(model.selectedSource == nil)
    #expect(model.selectedTag == nil)
}

/// One registration per key, the modifiers read at the moment of the press. The
/// three meanings have to stay apart, and ⌘ has to win over ⇧: extending a run
/// into the tag strip is not a thing.
@MainActor @Test func oneArrowKeyCarriesThreeMeanings() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let warp = ItemSource(bundleId: "dev.warp.Warp-Stable", name: "Warp")
    let tagged = try repo.insert(textItem("a"), source: warp, now: t0)
    try repo.insert(textItem("b"), source: warp, now: t0.addingTimeInterval(1))
    try repo.addTag(named: "keep", to: tagged)
    model.reload()
    let tagId = try #require(model.tags.first?.id)

    // Bare: the cursor moves and nothing gets marked.
    model.arrow(1, extending: false, acrossTags: false)
    #expect(model.selectedIndex == 1)
    #expect(model.selectedItems.count == 1)

    // ⇧: the run grows, the cursor stays where it landed.
    model.arrow(-1, extending: true, acrossTags: false)
    #expect(model.selectedItems.count == 2)

    // ⌘: the tag filter moves, and it is not an extension of the run.
    model.arrow(1, extending: false, acrossTags: true)
    #expect(model.selectedTag == tagId)

    // ⌘⇧: still the filter, never the run.
    model.selectedTag = nil
    model.arrow(1, extending: true, acrossTags: true)
    #expect(model.selectedTag == tagId)
}

/// The sheet acts on the selection, so both of its halves have to. A row that
/// reached one clipping while typing the same name reached five would be the
/// sheet contradicting itself.
@MainActor @Test func takingAndRemovingAnOfferedTagReachTheWholeRun() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    for (i, text) in ["a", "b", "c"].enumerated() {
        try repo.insert(textItem(text), source: nil, now: t0.addingTimeInterval(Double(i)))
    }
    try repo.addTag(named: "Work", to: try repo.insert(textItem("other"), source: nil,
                                                       now: t0.addingTimeInterval(9)))
    model.reload()
    model.select(1)
    model.extendSelection(2)          // three clippings, none of them "other"
    #expect(model.selectedItems.count == 3)

    let offered = try #require(model.tagChoices(for: model.selectedItems, matching: "wor").first)
    model.addTag(offered.name, to: model.selectedItems)
    #expect(model.selectedItems.allSatisfy { model.tags(for: $0).map(\.name) == ["Work"] })
    #expect(model.tags.map(\.name) == ["Work"])   // one tag row, not four

    model.removeTag(offered, from: model.selectedItems)
    #expect(model.selectedItems.allSatisfy { model.tags(for: $0).isEmpty })
    #expect(model.tags.map(\.name) == ["Work"])   // the tag itself survives
}

/// A tag on part of the run stays offered, because it is the row that finishes
/// the job; only one carried by all of them moves to the removable list.
@MainActor @Test func aTagOnPartOfTheRunIsStillOffered() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = try repo.insert(textItem("a"), source: nil, now: t0)
    let b = try repo.insert(textItem("b"), source: nil, now: t0.addingTimeInterval(1))
    try repo.addTag(named: "half", to: a)
    try repo.addTag(named: "both", to: a)
    try repo.addTag(named: "both", to: b)
    model.reload()
    model.select(0)
    model.extendSelection(1)

    #expect(model.tagChoices(for: model.selectedItems, matching: "").map(\.name) == ["half"])
    #expect(model.tagsOnAll(model.selectedItems) == ["both"])
}

/// The panel is hidden and not destroyed, so everything narrowing the list
/// outlives the task it was set for. This is the one call that puts all of it
/// back, and it has to be all of it: a reset that left the search box full would
/// be the same complaint one field over.
@MainActor @Test func openingThePanelPutsBackTheWholeHistory() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    let warp = ItemSource(bundleId: "dev.warp.Warp-Stable", name: "Warp")
    let tagged = try repo.insert(textItem("alpha"), source: warp, now: t0)
    try repo.insert(textItem("beta"), source: warp, now: t0.addingTimeInterval(1))
    try repo.insert(textItem("gamma"), source: nil, now: t0.addingTimeInterval(2))
    try repo.addTag(named: "keep", to: tagged)
    model.reload()
    let tagId = try #require(model.tags.first?.id)

    // A query that actually excludes, so clearing it has to show in the list and
    // not only in the field: "a" matches all three, and a reset measured against
    // it would pass on an assignment that never reached the search.
    model.query = "alph"
    model.selectedSource = warp.bundleId
    model.selectedTag = tagId
    #expect(model.items.map(\.text) == ["alpha"])

    model.resetView()

    #expect(model.query.isEmpty)
    #expect(model.selectedSource == nil)
    #expect(model.selectedTag == nil)
    #expect(model.selectedSource == nil)
    #expect(model.selectedTag == nil)
    #expect(model.items.map(\.text) == ["gamma", "beta", "alpha"])
    // The newest clipping, not wherever the cursor was left: it is the one the
    // panel is most often opened to reach.
    #expect(model.selectedIndex == 0)
}

/// A run is as much a filter on what ⏎ acts on as the sidebar is on what the
/// list shows, and it is the more expensive of the two to inherit: a restored
/// run pastes five clippings where the cursor promised one.
@MainActor @Test func openingThePanelDropsARunLeftOpen() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("a"), source: nil, now: t0)
    try repo.insert(textItem("b"), source: nil, now: t0.addingTimeInterval(1))
    try repo.insert(textItem("c"), source: nil, now: t0.addingTimeInterval(2))
    model.reload()

    model.extendSelection(to: 2)
    #expect(model.selectedItems.count == 3)

    model.resetView()

    #expect(model.selectedItems.map(\.text) == ["c"])
    #expect(model.selectedIndex == 0)
}

/// The reset has to hold on a history with nothing in it too. `select` is
/// guarded on there being a row to land on, so a reset that leaned on it would
/// leave a run in place exactly where there is no card left to justify one.
@MainActor @Test func openingThePanelOnAnEmptyHistoryStillDropsTheRun() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(textItem("a"), source: nil, now: t0)
    try repo.insert(textItem("b"), source: nil, now: t0.addingTimeInterval(1))
    model.reload()
    model.extendSelection(to: 1)
    #expect(model.selectedItems.count == 2)

    // Everything the run pointed at, gone from under it.
    for item in model.items { model.delete(item) }
    #expect(model.items.isEmpty)

    model.resetView()

    #expect(model.selectedItems.isEmpty)
    #expect(model.selectedIndex == 0)
}

/// The numbers on the cards and the keys that fire have to mean the same thing,
/// and the failure mode if they do not is a paste of the neighbouring clipping —
/// noticed after it has landed in whatever the user was writing.
@MainActor @Test func theNumberOnACardIsTheKeyThatPastesIt() throws {
    let (model, repo, dir) = try makeModel()
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 0..<12 {
        try repo.insert(textItem("clipping \(i)"), source: nil,
                        now: t0.addingTimeInterval(Double(i)))
    }
    model.reload()
    // Newest first, so the newest clipping is the one wearing ⌘1.
    #expect(model.items.first?.text == "clipping 11")

    for index in model.items.indices {
        guard let number = HistoryModel.number(forIndex: index) else { continue }
        #expect(model.item(atNumber: number)?.id == model.items[index].id)
    }

    #expect(model.item(atNumber: 1)?.text == "clipping 11")
    #expect(model.item(atNumber: 9)?.text == "clipping 3")
    // Past the ninth the cards wear nothing, and nothing is what the key finds.
    #expect(HistoryModel.number(forIndex: 9) == nil)
    #expect(model.item(atNumber: 10) == nil)
    #expect(model.item(atNumber: 0) == nil)

    // The number is a position, so it follows the filter rather than naming one
    // clipping for good.
    model.query = "clipping 4"
    #expect(model.item(atNumber: 1)?.text == "clipping 4")
    // And it does not reach past the end of a list the search made short.
    #expect(model.item(atNumber: 2) == nil)
}
