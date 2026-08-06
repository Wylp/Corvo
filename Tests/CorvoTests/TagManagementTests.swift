import Foundation
import Testing
import GRDB
@testable import Corvo

/// Tag CRUD at the repository, which is where the damage would be silent.
///
/// The three operations this file exists for are irreversible: editing a rule,
/// applying it to what is already stored, and deleting a tag. Corvo has no undo,
/// so what keeps them safe is not the code being right today but this file
/// noticing the day it stops being.
///
/// In-memory database, temporary blob directory, a `Preferences` on its own
/// suite. Nothing here touches the database the running app owns.
@MainActor
private func makeTags() throws -> (ItemRepository, AutoTagger, Preferences, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-tagmgmt-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    return (repo, AutoTagger(repo: repo, prefs: prefs), prefs, dir)
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@discardableResult
private func addItem(_ repo: ItemRepository, _ text: String,
                     kind: ClipKind = .text, source: ItemSource? = nil) throws -> Int64 {
    try repo.insert(CapturedItem(kind: kind, text: text, imageData: nil,
                                 filePath: nil, url: nil, contentHash: text),
                    source: source, now: t0)
}

// MARK: - 1. A tag survives the round trip

/// Brief test 1. The rule is two columns added by the v2 migration; a tag that
/// comes back without them is a rule the poller will never apply and the user
/// will never be told about.
@MainActor @Test func reviewATagRoundTripsItsNameColourPatternAndSource() throws {
    let (repo, _, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.saveTag(Tag(id: nil, name: "keys", color: "red", pattern: #"\.pem$"#,
                         sourceBundleId: "com.apple.Terminal", promptsForName: true))

    let stored = try #require(try repo.allTags().first)
    #expect(stored.name == "keys")
    #expect(stored.color == "red")
    #expect(stored.pattern == #"\.pem$"#)
    #expect(stored.sourceBundleId == "com.apple.Terminal")
    #expect(stored.promptsForName)
}

/// The normalisation the save path applies, and the one place it deliberately
/// does not: a trailing space is meaningful inside a regex, and an emptied
/// pattern has to become `NULL` rather than `""`, which `TagRule.isActive`
/// would read as a rule matching every item there is.
@MainActor @Test func reviewSaveTagNormalisesBlanksButNeverTrimsThePattern() throws {
    let (repo, _, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.saveTag(Tag(id: nil, name: "  work  ", color: "  ", pattern: " TODO ",
                         sourceBundleId: "   "))
    try repo.saveTag(Tag(id: nil, name: "blank", color: nil, pattern: ""))

    let byName = Dictionary(uniqueKeysWithValues: try repo.allTags().map { ($0.name, $0) })
    let work = try #require(byName["work"])
    #expect(work.color == nil)
    #expect(work.sourceBundleId == nil)
    #expect(work.pattern == " TODO ")
    #expect(try #require(byName["blank"]).pattern == nil)
    #expect(!(try #require(byName["blank"]).rule.isActive))
}

// MARK: - 2. Editing a rule must not cost the user their tagging

/// Brief test 2, and the single most expensive failure this screen could have.
/// `itemTag.tagId` cascades on delete, so a save implemented as delete-then-
/// insert would take every hand-made link with it — silently, with no undo.
@MainActor @Test func reviewEditingAPatternPreservesManualLinks() throws {
    let (repo, _, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    var tag = try repo.saveTag(Tag(id: nil, name: "work", color: "blue", pattern: "TODO"))
    let a = try addItem(repo, "nothing to do with the pattern")
    let b = try addItem(repo, "also unrelated")
    try repo.addTag(named: "work", to: a)
    try repo.addTag(named: "work", to: b)

    let idBefore = try #require(tag.id)
    tag.pattern = "FIXME"
    let saved = try repo.saveTag(tag)

    #expect(saved.id == idBefore)
    #expect(saved.pattern == "FIXME")
    #expect(try repo.tags(forItem: a).map(\.name) == ["work"])
    #expect(try repo.tags(forItem: b).map(\.name) == ["work"])
    #expect(try repo.itemCount(forTag: idBefore) == 2)
}

/// The same guarantee through the column the unique index sits on. A rename is
/// the edit most likely to be implemented as "remove the old one, add the new".
@MainActor @Test func reviewRenamingATagPreservesLinks() throws {
    let (repo, _, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    var tag = try repo.saveTag(Tag(id: nil, name: "old", color: nil))
    let id = try addItem(repo, "a clipping")
    try repo.addTag(named: "old", to: id)

    tag.name = "new"
    let saved = try repo.saveTag(tag)

    #expect(saved.id == tag.id)
    #expect(try repo.tags(forItem: id).map(\.name) == ["new"])
    #expect(try repo.allTags().count == 1)
}

// MARK: - 3. Deleting a tag deletes a label, never a clipping

/// Brief test 3. The confirmation says "the clippings themselves stay"; this is
/// what makes that sentence true.
@MainActor @Test func reviewDeletingATagKeepsTheItems() throws {
    let (repo, _, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tag = try repo.saveTag(Tag(id: nil, name: "doomed", color: nil))
    let tagId = try #require(tag.id)
    let a = try addItem(repo, "first clipping")
    let b = try addItem(repo, "second clipping")
    try repo.addTag(named: "doomed", to: a)
    try repo.addTag(named: "doomed", to: b)
    #expect(try repo.itemCount(forTag: tagId) == 2)

    try repo.deleteTag(tagId)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).count == 2)
    #expect(try repo.tags(forItem: a).isEmpty)
    #expect(try repo.tags(forItem: b).isEmpty)
    #expect(try repo.allTags().isEmpty)
}

// MARK: - 4. A repeated name

/// Brief test 4, extended by finding I3. A new tag whose name is already taken
/// resolves to the stored row — no duplicate and no constraint failure — and the
/// stored row comes back **untouched**. The incoming draft is a second tag that
/// collided, not a correction of the first; letting its blank fields win would
/// erase a working rule with no undo and no message.
@MainActor @Test func reviewASecondTagWithTheSameNameFoldsIntoTheFirst() throws {
    let (repo, _, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    let original = try repo.saveTag(Tag(id: nil, name: "work", color: "blue",
                                        pattern: "TODO",
                                        sourceBundleId: "com.apple.Terminal"))
    let id = try addItem(repo, "a clipping")
    try repo.addTag(named: "work", to: id)

    let folded = try repo.saveTag(Tag(id: nil, name: "work", color: nil, pattern: nil))

    #expect(folded.id == original.id)
    #expect(try repo.allTags().count == 1)

    let stored = try #require(try repo.allTags().first)
    #expect(stored.pattern == "TODO")
    #expect(stored.color == "blue")
    #expect(stored.sourceBundleId == "com.apple.Terminal")
    #expect(try repo.tags(forItem: id).map(\.name) == ["work"])
}

// MARK: - 5. Retroactive apply

/// Brief test 5. Five of six rows match; the sixth is an image, whose text is
/// the internal label `"Image"` and would satisfy this deliberately loose
/// pattern if the kind were not consulted.
@MainActor @Test func reviewApplyToExistingTagsExactlyTheMatches() throws {
    let (repo, tagger, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tag = try repo.saveTag(Tag(id: nil, name: "loose", color: nil, pattern: "e"))
    var matching: [Int64] = []
    for text in ["note one", "note two", "note three", "note four", "note five"] {
        matching.append(try addItem(repo, text))
    }
    let image = try addItem(repo, "Image", kind: .image)

    #expect(try tagger.applyToExistingItems(tag) == 5)

    for id in matching {
        #expect(try repo.tags(forItem: id).map(\.name) == ["loose"])
    }
    #expect(try repo.tags(forItem: image).isEmpty)
}

/// The editor's preview and the retroactive apply come from one call, so the
/// number the user is asked to confirm is the set that gets tagged. Anything
/// less makes the confirmation a lie about an operation with no undo.
@MainActor @Test func reviewPreviewCountEqualsWhatGetsTagged() throws {
    let (repo, tagger, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tag = try repo.saveTag(Tag(id: nil, name: "sql", color: nil, pattern: "SELECT"))
    for text in ["SELECT 1", "SELECT 2", "SELECT 3", "no query here"] {
        try addItem(repo, text)
    }

    let previewed = try tagger.items(matching: tag.rule).items
    #expect(previewed.count == 3)
    #expect(try tagger.applyToExistingItems(tag) == previewed.count)

    let tagged = try repo.search(text: "", sourceBundleId: nil,
                                 tagId: try #require(tag.id), limit: 50)
    #expect(Set(tagged.map(\.id)) == Set(previewed.map(\.id)))
}

/// Finding I2. The scan is bounded by the ceiling retention actually enforces,
/// which the user can raise — not by `RetentionPolicy.standard`'s default. With
/// a limit stuck at the default the preview would undercount and the apply
/// would skip the tail of the history without saying so.
@MainActor @Test func reviewPreviewAndApplyReachPastTheDefaultItemCeiling() throws {
    let (repo, tagger, prefs, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.maxItems = 1_500
    let total = RetentionPolicy.defaultMaxItems + 25
    // One transaction: 1025 rows through `insert` would be 1025 of them.
    try repo.dbQueue.write { db in
        for i in 0..<total {
            try db.execute(sql: """
                INSERT INTO item (kind, text, contentHash, pinned, createdAt)
                VALUES ('text', ?, ?, 0, ?)
                """, arguments: ["SELECT \(i)", "hash-\(i)", t0])
        }
    }

    let tag = try repo.saveTag(Tag(id: nil, name: "sql", color: nil, pattern: "SELECT"))
    let tagId = try #require(tag.id)
    #expect(try tagger.items(matching: tag.rule).items.count == total)
    #expect(try tagger.applyToExistingItems(tag) == total)
    #expect(try repo.itemCount(forTag: tagId) == total)
}

/// Finding M5. `addTag` ignores the conflict, so the second run changes nothing
/// and must say so — the number goes straight into "added to N clippings".
@MainActor @Test func reviewApplyingTheSameRuleTwiceReportsNoSecondChange() throws {
    let (repo, tagger, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tag = try repo.saveTag(Tag(id: nil, name: "sql", color: nil, pattern: "SELECT"))
    let tagId = try #require(tag.id)
    try addItem(repo, "SELECT 1")
    try addItem(repo, "SELECT 2")

    #expect(try tagger.applyToExistingItems(tag) == 2)
    #expect(try tagger.applyToExistingItems(tag) == 0)
    #expect(try repo.itemCount(forTag: tagId) == 2)
}

// MARK: - What the editor blocks, and what happens when it does not

/// The editor calls the same `isValid` the matcher does, so it can never accept
/// a pattern the poller would go on to drop in silence.
@MainActor @Test func reviewAnInvalidPatternIsRejectedByTheSameCallTheMatcherUses() throws {
    #expect(!TagRule.isValid(pattern: "[unclosed"))
    #expect(!TagRule.isValid(pattern: "("))
    #expect(TagRule.isValid(pattern: #"\.pem$"#))
}

/// Finding I4, at the layer that throws. Renaming a tag onto a name another tag
/// already holds hits the unique index on `tag.name`. The editor blocks it, but
/// the repository is what has to be honest with a caller that did not check.
@MainActor @Test func reviewRenamingOntoAnExistingNameThrows() throws {
    let (repo, _, _, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.saveTag(Tag(id: nil, name: "taken", color: nil))
    var other = try repo.saveTag(Tag(id: nil, name: "other", color: nil))

    other.name = "taken"
    #expect(throws: (any Error).self) { try repo.saveTag(other) }
    #expect(try repo.allTags().map(\.name) == ["other", "taken"])
}

/// Finding I4, at the layer the screen reads. The failure above has to arrive as
/// `nil` rather than as nothing at all — a save that quietly does nothing is
/// indistinguishable from one that worked, on a screen whose whole job is
/// telling the user whether their rule took.
@MainActor @Test func reviewAFailedTagWriteComesBackAsNil() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-tagmgmt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let model = HistoryModel(
        repo: repo, prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))

    try repo.saveTag(Tag(id: nil, name: "taken", color: nil))
    var other = try repo.saveTag(Tag(id: nil, name: "other", color: nil))
    other.name = "taken"

    #expect(model.saveTag(other) == nil)
    #expect(model.saveTag(Tag(id: nil, name: "fresh", color: nil)) != nil)
}

// MARK: - 9. The preview when the history has no ceiling

/// With the count rule off there is no retention number to borrow, so the scan
/// falls back to `previewScanLimit`. A cap can undercount where a ceiling cannot,
/// and undercounting in silence is the one thing this pair may not do — so the
/// result says the cap bit, and the editor turns that into "10,000+".
@MainActor @Test func withNoCeilingThePreviewReportsThatItsScanWasCapped() throws {
    let (repo, tagger, prefs, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.limitsItems = false
    prefs.limitsAge = false

    // One more row than the cap, all of them matching.
    try repo.dbQueue.write { db in
        for i in 0...AutoTagger.previewScanLimit {
            try db.execute(sql: """
                INSERT INTO item (kind, text, contentHash, pinned, createdAt)
                VALUES ('text', ?, ?, 0, ?)
                """, arguments: ["SELECT \(i)", "hash-\(i)", t0])
        }
    }

    let tag = try repo.saveTag(Tag(id: nil, name: "sql", color: nil, pattern: "SELECT"))
    let previewed = try tagger.items(matching: tag.rule)

    #expect(previewed.items.count == AutoTagger.previewScanLimit)
    #expect(previewed.hitLimit)

    // The invariant that survives the cap: what the user is asked to confirm is
    // exactly the set that gets tagged.
    #expect(try tagger.applyToExistingItems(tag) == previewed.items.count)
}

/// Under the cap, nothing changes: the count is exact and there is nothing to
/// warn about.
@MainActor @Test func withNoCeilingASmallHistoryStillCountsExactly() throws {
    let (repo, tagger, prefs, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.limitsItems = false
    for text in ["SELECT 1", "SELECT 2", "nothing"] { try addItem(repo, text) }

    let tag = try repo.saveTag(Tag(id: nil, name: "sql", color: nil, pattern: "SELECT"))
    let previewed = try tagger.items(matching: tag.rule)

    #expect(previewed.items.count == 2)
    #expect(!previewed.hitLimit)
}

/// A retention ceiling *is* the whole history, so filling the scan is not a
/// warning — there is nothing older for it to have missed. Reporting `hitLimit`
/// here would put "10,000+" on a screen where the count is exact.
@MainActor @Test func aFullScanUnderARetentionCeilingIsNotFlaggedAsCapped() throws {
    let (repo, tagger, prefs, dir) = try makeTags()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.maxItems = 3
    for text in ["SELECT 1", "SELECT 2", "SELECT 3"] { try addItem(repo, text) }

    let tag = try repo.saveTag(Tag(id: nil, name: "sql", color: nil, pattern: "SELECT"))
    let previewed = try tagger.items(matching: tag.rule)

    #expect(previewed.items.count == 3)
    #expect(!previewed.hitLimit)
}
