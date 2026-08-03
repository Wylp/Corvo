import Foundation
import GRDB

/// Conteúdo lido do pasteboard, antes de virar linha no banco.
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

    /// Insere. Se o `contentHash` já existir, promove o item existente ao topo
    /// preservando tags, pin e id — recopiar não deve custar sua organização.
    @discardableResult
    func insert(_ captured: CapturedItem, source: ItemSource?, now: Date) throws -> Int64 {
        var blobPath: String?
        if let data = captured.imageData {
            blobPath = try blobs.store(data, hash: captured.contentHash, ext: "png")
        }

        return try dbQueue.write { db in
            if let existente = try ClipItem
                .filter(ClipItem.Columns.contentHash == captured.contentHash)
                .fetchOne(db), let id = existente.id {
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

    /// `text` casa conteúdo **ou** nome da fonte, de modo que digitar "slack"
    /// filtre por origem sem passar pela barra lateral.
    func search(text: String, sourceBundleId: String?, tagId: Int64?,
                limit: Int) throws -> [ClipItem] {
        var sql = "SELECT item.* FROM item"
        var args: [DatabaseValueConvertible] = []

        if let tagId {
            sql += " JOIN itemTag ON itemTag.itemId = item.id AND itemTag.tagId = ?"
            args.append(tagId)
        }

        var condicoes: [String] = []
        let busca = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !busca.isEmpty {
            // ponytail: LIKE com scan. Ver comentário do índice em AppDatabase.
            condicoes.append("(item.text LIKE ? OR item.sourceName LIKE ?)")
            args.append("%\(busca)%")
            args.append("%\(busca)%")
        }
        if let sourceBundleId {
            condicoes.append("item.sourceBundleId = ?")
            args.append(sourceBundleId)
        }
        if !condicoes.isEmpty {
            sql += " WHERE " + condicoes.joined(separator: " AND ")
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

    func addTag(named name: String, to itemId: Int64) throws {
        let limpo = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return }
        try dbQueue.write { db in
            let existente = try Tag.filter(Tag.Columns.name == limpo).fetchOne(db)
            let tagId: Int64
            if let existente, let id = existente.id {
                tagId = id
            } else {
                var nova = Tag(id: nil, name: limpo, color: nil)
                try nova.insert(db)
                tagId = nova.id!
            }
            try ItemTag(itemId: itemId, tagId: tagId).insert(db, onConflict: .ignore)
        }
    }

    func removeTag(_ tagId: Int64, from itemId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM itemTag WHERE itemId = ? AND tagId = ?",
                           arguments: [itemId, tagId])
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
