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
