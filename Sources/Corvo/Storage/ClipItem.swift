import Foundation
import GRDB

enum ClipKind: String, Codable, CaseIterable, DatabaseValueConvertible {
    case text, image, file
}

struct ClipItem: Codable, Identifiable, Equatable, Hashable {
    var id: Int64?
    var kind: ClipKind
    /// Conteúdo para `.text`; nome legível para `.image` e `.file`.
    var text: String?
    /// Caminho relativo dentro do diretório de blobs, só para `.image`.
    var blobPath: String?
    /// Caminho absoluto original, só para `.file`. Não copiamos o arquivo.
    var filePath: String?
    /// `public.url` quando veio junto do conteúdo.
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
