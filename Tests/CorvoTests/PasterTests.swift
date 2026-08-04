import AppKit
import Foundation
import Testing
@testable import Corvo

/// A private pasteboard, so a test never touches the user's real clipboard.
private func tempPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("corvo-tests-\(UUID().uuidString)"))
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func item(kind: ClipKind, text: String? = nil,
                  blobPath: String? = nil, filePath: String? = nil) -> ClipItem {
    ClipItem(id: 1, kind: kind, text: text, blobPath: blobPath, filePath: filePath,
             url: nil, sourceBundleId: nil, sourceName: nil,
             contentHash: "hash", createdAt: Date())
}

private func pngData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

@Test func textGoesToTheClipboardAsAString() {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let blobs = BlobStore(directory: tempDirectory())

    let written = Paster.writeToClipboard(item(kind: .text, text: "hello"),
                                          blobs: blobs, to: pasteboard)

    #expect(written)
    #expect(pasteboard.string(forType: .string) == "hello")
}

@Test func anImageIsReadBackFromItsBlobOnDisk() throws {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobs = BlobStore(directory: directory)
    let path = try blobs.store(pngData(), hash: "abc123", ext: "png")

    let written = Paster.writeToClipboard(item(kind: .image, blobPath: path),
                                          blobs: blobs, to: pasteboard)

    #expect(written)
    #expect(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
}

@Test func aFileGoesToTheClipboardAsAURL() throws {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blobs = BlobStore(directory: tempDirectory())
    let file = directory.appendingPathComponent("note.txt")
    try Data("x".utf8).write(to: file)

    let written = Paster.writeToClipboard(item(kind: .file, filePath: file.path),
                                          blobs: blobs, to: pasteboard)

    #expect(written)
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    #expect(urls?.first?.path == file.path)
}

/// A file item is a reference we never copied, so the file may be gone. Losing
/// what was already on the clipboard would be a worse outcome than pasting
/// nothing, so a vanished item must leave the clipboard alone.
@Test func aFileThatNoLongerExistsLeavesTheClipboardUntouched() {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let blobs = BlobStore(directory: tempDirectory())
    Paster.writeToClipboard(item(kind: .text, text: "keep me"), blobs: blobs, to: pasteboard)

    let written = Paster.writeToClipboard(item(kind: .file, filePath: "/nope/gone.txt"),
                                          blobs: blobs, to: pasteboard)

    #expect(!written)
    #expect(pasteboard.string(forType: .string) == "keep me")
}

@Test func anImageWhoseBlobIsGoneLeavesTheClipboardUntouched() {
    let pasteboard = tempPasteboard()
    defer { pasteboard.releaseGlobally() }
    let blobs = BlobStore(directory: tempDirectory())
    Paster.writeToClipboard(item(kind: .text, text: "keep me"), blobs: blobs, to: pasteboard)

    let written = Paster.writeToClipboard(item(kind: .image, blobPath: "missing.png"),
                                          blobs: blobs, to: pasteboard)

    #expect(!written)
    #expect(pasteboard.string(forType: .string) == "keep me")
}
