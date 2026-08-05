import Foundation
import GRDB

struct Tag: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var name: String
    var color: String?
    /// The two halves of the tag's rule, stored flat because a tag has at most
    /// one. Both `nil` is an ordinary manual tag.
    var pattern: String?
    var sourceBundleId: String?
    /// Whether a capture this tag claims should be offered a name. Read by
    /// `AutoTagger`, which reports the matches back to `PasteboardMonitor.poll`,
    /// and again by `ItemCard` to mark a claimed clipping that still has none.
    var promptsForName: Bool = false

    var rule: TagRule { TagRule(pattern: pattern, sourceBundleId: sourceBundleId) }
}

extension Tag: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag"

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ItemTag: Codable, Equatable {
    var itemId: Int64
    var tagId: Int64
}

extension ItemTag: FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemTag"
}
