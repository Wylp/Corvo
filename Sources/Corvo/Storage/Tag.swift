import Foundation
import GRDB

struct Tag: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var name: String
    var color: String?
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
