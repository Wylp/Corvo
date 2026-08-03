import Foundation
import Testing
@testable import Corvo

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func gravaEDevolveCaminhoRelativo() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BlobStore(directory: dir)

    let caminho = try store.store(Data([1, 2, 3]), hash: "abc123", ext: "png")

    #expect(caminho == "abc123.png")
    #expect(FileManager.default.fileExists(atPath: store.url(for: caminho).path))
}

@Test func gravarOMesmoHashDuasVezesNaoDuplica() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BlobStore(directory: dir)

    _ = try store.store(Data([1, 2, 3]), hash: "abc123", ext: "png")
    _ = try store.store(Data([1, 2, 3]), hash: "abc123", ext: "png")

    let arquivos = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(arquivos.count == 1)
}

@Test func coletaRemoveOrfaosEPreservaVivos() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = BlobStore(directory: dir)

    let vivo = try store.store(Data([1]), hash: "vivo", ext: "png")
    _ = try store.store(Data([2]), hash: "orfao", ext: "png")

    let removidos = try store.collectGarbage(keeping: [vivo])

    #expect(removidos == 1)
    #expect(FileManager.default.fileExists(atPath: store.url(for: vivo).path))
    let arquivos = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(arquivos == ["vivo.png"])
}
