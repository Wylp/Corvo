import Foundation
import GRDB

/// Content read from the pasteboard, before it becomes a database row.
struct CapturedItem: Equatable {
    var kind: ClipKind
    var text: String?
    var imageData: Data?
    var filePath: String?
    var url: String?
    var contentHash: String
}

struct ItemSource: Equatable {
    let bundleId: String
    let name: String
}

struct SourceSummary: Identifiable, Equatable {
    var id: String { bundleId }
    let bundleId: String
    let name: String
    let count: Int
}

final class ItemRepository {
    let dbQueue: DatabaseQueue
    private let blobs: BlobStore

    init(dbQueue: DatabaseQueue, blobs: BlobStore) {
        self.dbQueue = dbQueue
        self.blobs = blobs
    }

    /// Inserts. If `contentHash` already exists, promotes the existing item to
    /// the top keeping tags, pin and id — recopying must not cost you your
    /// organization.
    @discardableResult
    func insert(_ captured: CapturedItem, source: ItemSource?, now: Date) throws -> Int64 {
        var blobPath: String?
        if let data = captured.imageData {
            blobPath = try blobs.store(data, hash: captured.contentHash, ext: "png")
        }

        return try dbQueue.write { db in
            if let existing = try ClipItem
                .filter(ClipItem.Columns.contentHash == captured.contentHash)
                .fetchOne(db), let id = existing.id {
                try db.execute(sql: "UPDATE item SET createdAt = ? WHERE id = ?",
                               arguments: [now, id])
                return id
            }

            var item = ClipItem(
                id: nil,
                kind: captured.kind,
                text: captured.text,
                blobPath: blobPath,
                filePath: captured.filePath,
                url: captured.url,
                sourceBundleId: source?.bundleId,
                sourceName: source?.name,
                contentHash: captured.contentHash,
                pinned: false,
                createdAt: now,
                lastUsedAt: nil
            )
            try item.insert(db)
            return item.id!
        }
    }

    /// `text` matches content, source name **or** the name the user gave the
    /// item, so that typing "slack" filters by origin without going through the
    /// sidebar and an item named "Claude session about GRDB" is found by either
    /// word.
    func search(text: String, sourceBundleId: String?, tagId: Int64?,
                limit: Int) throws -> [ClipItem] {
        var sql = "SELECT item.* FROM item"
        var args: [DatabaseValueConvertible] = []

        if let tagId {
            sql += " JOIN itemTag ON itemTag.itemId = item.id AND itemTag.tagId = ?"
            args.append(tagId)
        }

        var conditions: [String] = []
        // One condition per word, joined with AND, rather than one match on the
        // whole line. Matching the line means the words have to appear together
        // and in the order they were typed, which is not how a search box is
        // used: "g cloud" found nothing in a history that had `gcloud auth
        // login` in it, because the space the user put in was being required of
        // the text as well. Split, each word only has to be in there somewhere,
        // and typing another word narrows rather than starts over.
        //
        // ponytail: LIKE with a scan. See the index comment in AppDatabase.
        for word in text.split(whereSeparator: \.isWhitespace) {
            conditions.append(
                "(item.text LIKE ? OR item.sourceName LIKE ? OR item.label LIKE ?)")
            args.append(contentsOf: repeatElement("%\(word)%", count: 3))
        }
        if let sourceBundleId {
            conditions.append("item.sourceBundleId = ?")
            args.append(sourceBundleId)
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        sql += " ORDER BY item.pinned DESC, item.createdAt DESC LIMIT ?"
        args.append(limit)

        return try dbQueue.read { db in
            try ClipItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func sources() throws -> [SourceSummary] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sourceBundleId AS bundleId,
                       sourceName     AS name,
                       COUNT(*)       AS count
                FROM item
                WHERE sourceBundleId IS NOT NULL
                GROUP BY sourceBundleId
                ORDER BY count DESC, name ASC
                """)
            .map { SourceSummary(bundleId: $0["bundleId"],
                                 name: $0["name"] ?? $0["bundleId"],
                                 count: $0["count"]) }
        }
    }

    func allTags() throws -> [Tag] {
        try dbQueue.read { db in
            try Tag.order(Tag.Columns.name).fetchAll(db)
        }
    }

    /// How many clippings carry each tag, by tag id. A tag on nothing is absent
    /// rather than zero — the one caller sorts by this and reads a missing key
    /// as none, so a row per unused tag would be work for no answer.
    ///
    /// ponytail: count, not recency. Ordering by "the tag you reached for last"
    /// would be the better answer and it cannot be had from here: `itemTag` is
    /// two foreign keys and no timestamp, so there is nothing recording *when* a
    /// clipping was tagged. That is a migration, not a query.
    func tagUsage() throws -> [Int64: Int] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT tagId, COUNT(*) AS n FROM itemTag GROUP BY tagId")
                .reduce(into: [:]) { counts, row in counts[row["tagId"]] = row["n"] }
        }
    }

    func tags(forItem id: Int64) throws -> [Tag] {
        try dbQueue.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT tag.* FROM tag
                JOIN itemTag ON itemTag.tagId = tag.id
                WHERE itemTag.itemId = ?
                ORDER BY tag.name
                """, arguments: [id])
        }
    }

    /// `true` when this created the link, `false` when the item already carried
    /// the tag. Callers that report a count to the user need the difference —
    /// the conflict is ignored, so "how many rows matched" is not "how many
    /// rows changed".
    @discardableResult
    func addTag(named name: String, to itemId: Int64) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return try dbQueue.write { db in
            let existing = try Tag.filter(Tag.Columns.name == trimmed).fetchOne(db)
            let tagId: Int64
            if let existing, let id = existing.id {
                tagId = id
            } else {
                var newTag = Tag(id: nil, name: trimmed, color: nil)
                try newTag.insert(db)
                tagId = newTag.id!
            }
            try ItemTag(itemId: itemId, tagId: tagId).insert(db, onConflict: .ignore)
            return db.changesCount > 0
        }
    }

    /// Creates the tag, or writes an existing one back in place.
    ///
    /// An update is an `UPDATE` on the tag row and never touches `itemTag`, so
    /// changing a rule cannot cost the user the items they tagged by hand. That
    /// is the whole reason there is no delete-then-insert path here.
    ///
    /// A new tag whose name already belongs to another resolves to that row
    /// rather than failing the unique index, and the stored one is returned
    /// **unchanged**: the incoming draft is a second tag that happens to collide,
    /// not a correction of the first, and letting its blank pattern and colour
    /// win would erase the real tag's rule with no undo and no message. The
    /// editor stops the case before it arrives; this is what keeps the
    /// repository from either throwing or losing configuration at a caller that
    /// did not.
    @discardableResult
    func saveTag(_ tag: Tag) throws -> Tag {
        var saved = tag
        saved.name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.color = Self.nilIfBlank(tag.color)
        // An emptied field has to store NULL, not "": `TagRule.isActive` reads
        // any non-nil pattern as a rule, and the empty pattern matches every
        // item there is. Not trimmed, unlike the name — trailing space is
        // meaningful inside a regex.
        saved.pattern = Self.nilIfEmpty(tag.pattern)
        saved.sourceBundleId = Self.nilIfBlank(tag.sourceBundleId)

        // Same silence as `addTag`: a nameless tag is not an error worth its own
        // error type, it is a form the user has not finished filling in.
        guard !saved.name.isEmpty else { return tag }

        return try dbQueue.write { db in
            if saved.id != nil {
                try saved.update(db)
                return saved
            }
            if let existing = try Tag.filter(Tag.Columns.name == saved.name).fetchOne(db) {
                return existing
            }
            try saved.insert(db)
            return saved
        }
    }

    /// The foreign key cascade drops the links. The items themselves stay — a
    /// tag is a label on a clipping, never the clipping itself.
    func deleteTag(_ id: Int64) throws {
        try dbQueue.write { db in
            _ = try Tag.deleteOne(db, key: id)
        }
    }

    /// How many items carry the tag. Quoted in the delete confirmation, which is
    /// the only warning the user gets before the cascade runs.
    func itemCount(forTag id: Int64) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemTag WHERE tagId = ?",
                             arguments: [id]) ?? 0
        }
    }

    private static func nilIfEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func nilIfBlank(_ s: String?) -> String? {
        nilIfEmpty(s?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func removeTag(_ tagId: Int64, from itemId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM itemTag WHERE itemId = ? AND tagId = ?",
                           arguments: [itemId, tagId])
        }
    }

    /// The name the user gave this clipping, or `nil` to take it away again.
    ///
    /// Blank is stored as NULL rather than `""`, which is what makes clearing
    /// the field the way back from a name you regret: the card falls back to
    /// showing the content, and `search` stops matching an empty string against
    /// every row. Same `nilIfBlank` the tag editor writes through, for the same
    /// reason.
    func setLabel(_ label: String?, for id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET label = ? WHERE id = ?",
                           arguments: [Self.nilIfBlank(label), id])
        }
    }

    func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET pinned = ? WHERE id = ?",
                           arguments: [pinned, id])
        }
    }

    func touch(_ id: Int64, now: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE item SET lastUsedAt = ? WHERE id = ?",
                           arguments: [now, id])
        }
    }

    func delete(_ id: Int64) throws {
        try dbQueue.write { db in
            _ = try ClipItem.deleteOne(db, key: id)
        }
    }

    func liveBlobPaths() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql:
                "SELECT blobPath FROM item WHERE blobPath IS NOT NULL"))
        }
    }
}
