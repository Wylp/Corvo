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

    private static var migrator: DatabaseMigrator {
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
            // ponytail: search is a LIKE over `text` and `sourceName`. With the
            // 1000-item ceiling from the retention policy that answers in
            // microseconds. If the ceiling grows a lot, move to an FTS5 virtual
            // table plus triggers.
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

        return migrator
    }
}
