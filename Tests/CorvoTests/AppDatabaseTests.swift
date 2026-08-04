import Foundation
import Testing
import GRDB
@testable import Corvo

@Test func migrationCreatesTheThreeTables() throws {
    let dbQueue = try AppDatabase.make(at: nil)
    let tables = try dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
              AND name NOT LIKE 'grdb_%'
            ORDER BY name
            """)
    }
    #expect(tables == ["item", "itemTag", "tag"])
}

@Test func foreignKeyDeletesTheAssociationAlongWithTheItem() throws {
    let dbQueue = try AppDatabase.make(at: nil)
    try dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO item (kind, contentHash, pinned, createdAt)
            VALUES ('text', 'abc', 0, '2026-01-01 00:00:00.000')
            """)
        try db.execute(sql: "INSERT INTO tag (name) VALUES ('work')")
        try db.execute(sql: "INSERT INTO itemTag (itemId, tagId) VALUES (1, 1)")
        try db.execute(sql: "DELETE FROM item WHERE id = 1")
        let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemTag")
        #expect(remaining == 0)
    }
}

// MARK: - v1 → v2

/// The migration this project cannot get wrong. There is a real database on the
/// user's disk that has already run "v1" and nothing else; the next launch runs
/// "v2" against their whole clipboard history. This builds that exact
/// situation — stop at v1, put rows in, then migrate forward — and checks that
/// every row is still there afterwards.
///
/// The file lives in a temporary directory. Nothing in this suite goes near
/// `~/Library/Application Support/Corvo/corvo.sqlite`.
@Test func migratingAV1DatabaseToV2KeepsEveryRow() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-migrate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("corvo.sqlite").path)

    // A v1 database, stopped there on purpose: this is the schema on disk today.
    try AppDatabase.migrator.migrate(dbQueue, upTo: "v1")
    #expect(try dbQueue.read { try $0.columns(in: "item").map(\.name) }.contains("label") == false)

    try dbQueue.write { db in
        for i in 1...3 {
            try db.execute(sql: """
                INSERT INTO item (kind, text, sourceBundleId, sourceName, contentHash,
                                  pinned, createdAt)
                VALUES ('text', ?, 'com.apple.Terminal', 'Terminal', ?, ?, ?)
                """, arguments: ["clipping \(i)", "hash\(i)", i == 2,
                                 "2026-01-0\(i) 00:00:00.000"])
        }
        try db.execute(sql: "INSERT INTO tag (name, color) VALUES ('work', '#ff0000')")
        try db.execute(sql: "INSERT INTO tag (name) VALUES ('personal')")
        try db.execute(sql: "INSERT INTO itemTag (itemId, tagId) VALUES (1, 1), (2, 2)")
    }

    try AppDatabase.migrator.migrate(dbQueue)

    try dbQueue.read { db in
        // Every row survived, and so did what was in it.
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") == 3)
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") == 2)
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemTag") == 2)

        #expect(try String.fetchAll(db, sql: "SELECT text FROM item ORDER BY id")
                == ["clipping 1", "clipping 2", "clipping 3"])
        #expect(try Int64.fetchOne(db, sql: "SELECT id FROM item WHERE pinned = 1") == 2)
        #expect(try String.fetchOne(db, sql: "SELECT color FROM tag WHERE name = 'work'")
                == "#ff0000")

        // The new columns exist and are empty, not defaulted into a rule that
        // would start tagging the user's whole history.
        let items = try ClipItem.order(Column("id")).fetchAll(db)
        #expect(items.allSatisfy { $0.label == nil })

        let tags = try Tag.order(Tag.Columns.name).fetchAll(db)
        #expect(tags.map(\.name) == ["personal", "work"])
        #expect(tags.allSatisfy { $0.pattern == nil && $0.sourceBundleId == nil })
        #expect(tags.allSatisfy { $0.promptsForName == false })
        #expect(tags.allSatisfy { $0.rule.isActive == false })
    }
}

/// A database created from scratch today must end up with the same columns as
/// one that migrated up from v1 — that is the divergence editing "v1" in place
/// would have caused, and this is what would catch it.
@Test func aFreshDatabaseHasTheV2Columns() throws {
    let dbQueue = try AppDatabase.make(at: nil)
    try dbQueue.read { db in
        let item = try db.columns(in: "item").map(\.name)
        #expect(item.contains("label"))

        let tag = try db.columns(in: "tag").map(\.name)
        #expect(tag.contains("pattern"))
        #expect(tag.contains("sourceBundleId"))
        #expect(tag.contains("promptsForName"))
    }
}
