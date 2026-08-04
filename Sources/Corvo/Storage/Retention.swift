import Foundation
import GRDB

struct RetentionPolicy: Equatable {
    var maxItems: Int
    var maxAge: TimeInterval

    static let standard = RetentionPolicy(maxItems: 1000, maxAge: 30 * 24 * 3600)
}

/// Prunes the history. An item that is pinned or has at least one tag is
/// protected: it never expires and does not count towards the item ceiling.
struct Retention {
    private let repo: ItemRepository
    private let blobs: BlobStore

    init(repo: ItemRepository, blobs: BlobStore) {
        self.repo = repo
        self.blobs = blobs
    }

    @discardableResult
    func prune(policy: RetentionPolicy, now: Date) throws -> Int {
        let protected = """
            item.pinned = 1
            OR EXISTS (SELECT 1 FROM itemTag WHERE itemTag.itemId = item.id)
            """

        let removed = try repo.dbQueue.write { db -> Int in
            var total = 0

            if policy.maxAge.isFinite {
                let cutoff = now.addingTimeInterval(-policy.maxAge)
                try db.execute(sql: """
                    DELETE FROM item
                    WHERE createdAt < ? AND NOT (\(protected))
                    """, arguments: [cutoff])
                total += db.changesCount
            }

            try db.execute(sql: """
                DELETE FROM item WHERE id IN (
                    SELECT id FROM item
                    WHERE NOT (\(protected))
                    ORDER BY createdAt DESC
                    LIMIT -1 OFFSET ?
                )
                """, arguments: [policy.maxItems])
            total += db.changesCount

            return total
        }

        try blobs.collectGarbage(keeping: repo.liveBlobPaths())
        return removed
    }
}
