import Foundation
import GRDB

enum AppDatabase {
    /// App support directory: `~/Library/Application Support/Corvo/`.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Corvo", isDirectory: true)
    }

    /// Opens the database. `url == nil` opens in memory — that is what tests use.
    static func make(at url: URL?) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true

        let dbQueue: DatabaseQueue
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        } else {
            dbQueue = try DatabaseQueue(configuration: config)
        }
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    static var defaultURL: URL {
        supportDirectory.appendingPathComponent("corvo.sqlite")
    }

    /// Not private so that `AppDatabaseTests` can stop at `"v1"` and migrate
    /// forward from there. The only way to prove the upgrade preserves rows is
    /// to build a v1 database on purpose.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("text", .text)
                t.column("blobPath", .text)
                t.column("filePath", .text)
                t.column("url", .text)
                t.column("sourceBundleId", .text)
                t.column("sourceName", .text)
                t.column("contentHash", .text).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime)
            }
            // ponytail: search is a LIKE over `text` and `sourceName`. The row
            // count it scans is now the user's to set, so what bounds it is
            // `Preferences.itemLimits` rather than the old fixed 1000 — 10k
            // short rows still answer in well under a frame. Move to an FTS5
            // virtual table plus triggers before raising that bound.
            try db.create(index: "idx_item_hash", on: "item",
                          columns: ["contentHash"], unique: true)
            try db.create(index: "idx_item_createdAt", on: "item", columns: ["createdAt"])
            try db.create(index: "idx_item_source", on: "item", columns: ["sourceBundleId"])

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("color", .text)
            }
            try db.create(index: "idx_tag_name", on: "tag",
                          columns: ["name"], unique: true)

            try db.create(table: "itemTag") { t in
                t.column("itemId", .integer).notNull()
                    .references("item", onDelete: .cascade)
                t.column("tagId", .integer).notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["itemId", "tagId"])
            }
        }

        // "v1" above is frozen. It has already run against the database in the
        // user's Application Support directory, so editing it would not re-run
        // anything — it would only make tomorrow's fresh install disagree with
        // today's. Schema changes are new migrations, always.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "tag") { t in
                t.add(column: "pattern", .text)
                t.add(column: "sourceBundleId", .text)
                t.add(column: "promptsForName", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "item") { t in
                t.add(column: "label", .text)
            }
        }

        // The list is always ordered `pinned DESC, createdAt DESC` — that is the
        // panel's order, and `search` is the only way it is read. `idx_item_createdAt`
        // cannot serve a two-column sort, so SQLite answered every query with
        //
        //     SCAN item
        //     USE TEMP B-TREE FOR ORDER BY
        //
        // which sorts the whole history before taking 200 rows, on the main
        // thread, on every panel opening and every capture. Measured on this
        // machine, opening the panel: 1.9 ms at 1,000 clippings, 4.7 ms at
        // 5,000, 15.3 ms at 20,000 — the cost of the list is the size of the
        // history, and a dropped frame long before anyone would call the
        // history large.
        //
        // With this index the plan is `SCAN item USING INDEX` and the temp
        // b-tree is gone: 1.2 ms at all three sizes.
        //
        // The column order is the ORDER BY's. The two DESCs are not load-bearing
        // and are here to mirror it: SQLite walks an index backwards happily, so
        // `(pinned, createdAt)` serves this sort too — checked. What it will not
        // do is mix directions. `(pinned DESC, createdAt ASC)` against this
        // ORDER BY gives `USE TEMP B-TREE FOR RIGHT PART OF ORDER BY`, half the
        // sort back — also checked, and what the plan test would catch.
        //
        // ponytail: a search that matches nothing pays more, not less — SQLite
        // walks the whole index looking for 200 rows that are not there, where
        // before it scanned the table and had nothing to sort. 3.2 ms → 4.7 ms
        // at 20,000. Still inside a frame, and the trade buys 15.3 → 1.2 on the
        // opening that happens every time. FTS5 is what fixes the LIKE itself;
        // this is not that.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE INDEX idx_item_pinned_createdAt
                ON item(pinned DESC, createdAt DESC)
                """)
        }

        return migrator
    }
}
