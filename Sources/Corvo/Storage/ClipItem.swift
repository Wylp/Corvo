import Foundation
import GRDB

enum ClipKind: String, Codable, CaseIterable, DatabaseValueConvertible {
    case text, image, file
}

struct ClipItem: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var kind: ClipKind
    /// Content for `.text`; human-readable name for `.image` and `.file`.
    var text: String?
    /// Path relative to the blob directory, `.image` only.
    var blobPath: String?
    /// Original absolute path, `.file` only. We never copy the file.
    var filePath: String?
    /// `public.url` when it came along with the content.
    var url: String?
    var sourceBundleId: String?
    var sourceName: String?
    var contentHash: String
    var pinned: Bool = false
    var createdAt: Date
    var lastUsedAt: Date?
}

extension ClipItem: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "item"

    enum Columns {
        static let id = Column("id")
        static let kind = Column("kind")
        static let text = Column("text")
        static let sourceBundleId = Column("sourceBundleId")
        static let sourceName = Column("sourceName")
        static let contentHash = Column("contentHash")
        static let pinned = Column("pinned")
        static let createdAt = Column("createdAt")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
