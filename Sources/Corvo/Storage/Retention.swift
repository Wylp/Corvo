import Foundation
import GRDB

/// The two rules that delete clippings, each of which the user can switch off.
///
/// `nil` is a rule that is not applied. Optionals rather than sentinels because
/// there is no honest sentinel for a count: `maxAge` could say "off" with
/// `.infinity` and did, but a reader had to know that to see it, and 0 items is a
/// real ceiling rather than an absent one. `nil` says it the same way for both.
///
/// Neither rule stores anything on a clipping. The age sweep derives its cutoff
/// from `item.createdAt` every time it runs, which is what lets a rule be
/// switched off and back on without anything to migrate: the clippings that
/// accumulated while it was off are compared against the same `createdAt` the
/// moment it is on again.
struct RetentionPolicy: Equatable {
    /// The most unprotected clippings to keep. `nil` for no ceiling.
    var maxItems: Int?
    /// How old an unprotected clipping may get. `nil` for no expiry.
    var maxAge: TimeInterval?

    /// The numbers a fresh install starts from, kept non-optional and apart from
    /// the policy: these are what the two fields hold, which is a different
    /// question from whether either rule is switched on. `Preferences` reads them
    /// when nothing has been stored yet.
    static let defaultMaxItems = 1000
    static let defaultMaxAgeDays = 30

    static let standard = RetentionPolicy(maxItems: defaultMaxItems,
                                         maxAge: Double(defaultMaxAgeDays) * 86400)
}

/// Prunes the history. An item that is pinned, named, or has at least one tag is
/// protected: it never expires and does not count towards the item ceiling.
struct Retention {
    private let repo: ItemRepository
    private let blobs: BlobStore

    init(repo: ItemRepository, blobs: BlobStore) {
        self.repo = repo
        self.blobs = blobs
    }

    /// Everything: both rules, then the blob garbage collection. Runs on launch,
    /// hourly, and when the user confirms a change that deletes.
    @discardableResult
    func prune(policy: RetentionPolicy, now: Date) throws -> Int {
        let removed = try repo.dbQueue.write { db -> Int in
            var total = 0
            if let maxAge = policy.maxAge {
                total += try Self.deleteOlderThan(now.addingTimeInterval(-maxAge), in: db)
            }
            if let maxItems = policy.maxItems {
                total += try Self.deleteBeyond(maxItems, in: db)
            }
            return total
        }

        try blobs.collectGarbage(keeping: repo.liveBlobPaths())
        return removed
    }

    /// The count rule alone, and deliberately without the blob collection.
    ///
    /// This is the sweep that runs after every capture, so that a ceiling behaves
    /// like a ceiling instead of settling whenever the hourly timer next fires.
    /// It is the half of `prune` that is cheap enough to sit on the copy path: one
    /// `DELETE` over an indexed ordering, where the collection it skips walks the
    /// whole blob directory on the main thread.
    ///
    /// The price is that a clipping deleted here leaves its image on disk until
    /// the next full prune collects it. The collection is keyed on the rows that
    /// still exist and is idempotent, so nothing is lost and nothing is
    /// double-deleted — the cost is bounded by how long until the next hourly run.
    @discardableResult
    func enforceItemCeiling(policy: RetentionPolicy) throws -> Int {
        guard let maxItems = policy.maxItems else { return 0 }
        return try repo.dbQueue.write { db in try Self.deleteBeyond(maxItems, in: db) }
    }

    // MARK: - The two statements

    /// Pinned, or tagged. Written once because it appears in both deletes, and a
    /// copy that lost the `EXISTS` would silently delete what the user marked to
    /// keep.
    /// Three ways of saying "I meant to keep this", and they are the same
    /// statement: somebody stopped and did something to this clipping on
    /// purpose. A name took a keystroke and a sentence to write, exactly like a
    /// tag did, and expiring it thirty days later throws away the work rather
    /// than the clipping. ⌘R was the one of the three that did not count.
    ///
    /// `IFNULL(...) <> ''` and not `IS NOT NULL`: `setLabel` stores blank as
    /// NULL, so the two agree today. They stop agreeing the moment anything
    /// writes `''`, and on a DELETE the cost of being wrong is a clipping the
    /// user cannot get back.
    private static let protected = """
        item.pinned = 1
        OR IFNULL(item.label, '') <> ''
        OR EXISTS (SELECT 1 FROM itemTag WHERE itemTag.itemId = item.id)
        """

    private static func deleteOlderThan(_ cutoff: Date, in db: Database) throws -> Int {
        try db.execute(sql: """
            DELETE FROM item
            WHERE createdAt < ? AND NOT (\(protected))
            """, arguments: [cutoff])
        return db.changesCount
    }

    /// `LIMIT -1 OFFSET ?` skips the N newest and deletes what is left. One
    /// statement, called from both entry points, so the ceiling cannot come to
    /// mean two different things.
    private static func deleteBeyond(_ maxItems: Int, in db: Database) throws -> Int {
        try db.execute(sql: """
            DELETE FROM item WHERE id IN (
                SELECT id FROM item
                WHERE NOT (\(protected))
                ORDER BY createdAt DESC
                LIMIT -1 OFFSET ?
            )
            """, arguments: [maxItems])
        return db.changesCount
    }
}
