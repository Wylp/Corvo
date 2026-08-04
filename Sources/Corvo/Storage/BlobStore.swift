import Foundation

/// Keeps binary data (images) on disk, named by the content hash.
/// The database stores only the relative path — a blob never enters a table.
final class BlobStore {
    private let directory: URL
    private let fm = FileManager.default

    init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Idempotent: storing the same hash again neither rewrites nor duplicates.
    func store(_ data: Data, hash: String, ext: String) throws -> String {
        let relativePath = "\(hash).\(ext)"
        let destination = directory.appendingPathComponent(relativePath)
        guard !fm.fileExists(atPath: destination.path) else { return relativePath }
        try data.write(to: destination, options: .atomic)
        return relativePath
    }

    func url(for relativePath: String) -> URL {
        directory.appendingPathComponent(relativePath)
    }

    /// Removes every file in the directory that is not in `live`.
    @discardableResult
    func collectGarbage(keeping live: Set<String>) throws -> Int {
        let existing = try fm.contentsOfDirectory(atPath: directory.path)
        var removed = 0
        for name in existing where !live.contains(name) {
            try fm.removeItem(at: directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }
}
