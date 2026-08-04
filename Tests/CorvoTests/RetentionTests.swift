import Foundation
import Testing
@testable import Corvo

private let agora = Date(timeIntervalSince1970: 1_700_000_000)

private func ambiente() throws -> (ItemRepository, BlobStore, Retention, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-ret-\(UUID().uuidString)")
    let blobs = BlobStore(directory: dir)
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil), blobs: blobs)
    return (repo, blobs, Retention(repo: repo, blobs: blobs), dir)
}

private func texto(_ s: String) -> CapturedItem {
    CapturedItem(kind: .text, text: s, imageData: nil,
                 filePath: nil, url: nil, contentHash: s)
}

@Test func podaPorIdadeRemoveOsAntigos() throws {
    let (repo, _, retencao, dir) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(texto("velho"), source: nil, now: agora.addingTimeInterval(-40 * 86400))
    try repo.insert(texto("novo"), source: nil, now: agora)

    let removidos = try retencao.prune(policy: .padrao, now: agora)

    #expect(removidos == 1)
    let restantes = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(restantes.map(\.text) == ["novo"])
}

@Test func fixadosEItensComTagNuncaExpiram() throws {
    let (repo, _, retencao, dir) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    let antigo = agora.addingTimeInterval(-40 * 86400)
    let fixado = try repo.insert(texto("fixado"), source: nil, now: antigo)
    let comTag = try repo.insert(texto("com tag"), source: nil, now: antigo)
    try repo.insert(texto("descartável"), source: nil, now: antigo)
    try repo.setPinned(fixado, true)
    try repo.addTag(named: "guardar", to: comTag)

    let removidos = try retencao.prune(policy: .padrao, now: agora)

    #expect(removidos == 1)
    let restantes = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(Set(restantes.compactMap(\.text)) == ["fixado", "com tag"])
}

@Test func podaPorQuantidadeNaoContaProtegidos() throws {
    let (repo, _, retencao, dir) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    let fixado = try repo.insert(texto("fixado"), source: nil, now: agora)
    try repo.setPinned(fixado, true)
    for i in 0..<5 {
        try repo.insert(texto("item \(i)"), source: nil,
                        now: agora.addingTimeInterval(Double(i)))
    }

    let politica = RetentionPolicy(maxItems: 3, maxAge: .greatestFiniteMagnitude)
    let removidos = try retencao.prune(policy: politica, now: agora)

    // 5 desprotegidos, teto 3 → remove os 2 mais antigos. Fixado permanece.
    #expect(removidos == 2)
    let restantes = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(restantes.count == 4)
}

@Test func podaApagaBlobsQueFicaramOrfaos() throws {
    let (repo, blobs, retencao, dir) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    let png = Data([0x89, 0x50])
    try repo.insert(CapturedItem(kind: .image, text: "img", imageData: png,
                                 filePath: nil, url: nil, contentHash: "velha"),
                    source: nil, now: agora.addingTimeInterval(-40 * 86400))

    #expect(FileManager.default.fileExists(atPath: blobs.url(for: "velha.png").path))

    try retencao.prune(policy: .padrao, now: agora)

    #expect(!FileManager.default.fileExists(atPath: blobs.url(for: "velha.png").path))
}
