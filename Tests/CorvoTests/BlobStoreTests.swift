import Foundation
import Testing
@testable import Corvo

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func storesAndReturnsARelativePath() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BlobStore(directory: dir)

    let path = try store.store(Data([1, 2, 3]), hash: "abc123", ext: "png")

    #expect(path == "abc123.png")
    #expect(FileManager.default.fileExists(atPath: store.url(for: path).path))
}

@Test func storingTheSameHashTwiceDoesNotDuplicate() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BlobStore(directory: dir)

    _ = try store.store(Data([1, 2, 3]), hash: "abc123", ext: "png")
    _ = try store.store(Data([1, 2, 3]), hash: "abc123", ext: "png")

    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files.count == 1)
}

@Test func garbageCollectionRemovesOrphansAndKeepsLiveFiles() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BlobStore(directory: dir)

    let live = try store.store(Data([1]), hash: "live", ext: "png")
    _ = try store.store(Data([2]), hash: "orphan", ext: "png")

    let removed = try store.collectGarbage(keeping: [live])

    #expect(removed == 1)
    #expect(FileManager.default.fileExists(atPath: store.url(for: live).path))
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files == ["live.png"])
}
