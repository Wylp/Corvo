import Foundation
import Testing
import GRDB
@testable import Corvo

private func makeRepo() throws -> (ItemRepository, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-repo-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    return (repo, dir)
}

private func texto(_ s: String) -> CapturedItem {
    CapturedItem(kind: .text, text: s, imageData: nil,
                 filePath: nil, url: nil, contentHash: s)
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func insereEBusca() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(texto("olá mundo"),
                    source: ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
                    now: t0)

    let achados = try repo.search(text: "mundo", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(achados.count == 1)
    #expect(achados[0].sourceName == "Slack")
}

@Test func conteudoRepetidoSobeAoTopoSemDuplicarNemPerderTagOuPin() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = try repo.insert(texto("repetido"), source: nil, now: t0)
    try repo.addTag(named: "trabalho", to: id)
    try repo.setPinned(id, true)

    let idDeNovo = try repo.insert(texto("repetido"), source: nil,
                                   now: t0.addingTimeInterval(60))

    #expect(idDeNovo == id)
    let todos = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(todos.count == 1)
    #expect(todos[0].pinned == true)
    #expect(todos[0].createdAt == t0.addingTimeInterval(60))
    #expect(try repo.tags(forItem: id).map(\.name) == ["trabalho"])
}

@Test func buscaTextualTambemCasaONomeDaFonte() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    try repo.insert(texto("SELECT 1"),
                    source: ItemSource(bundleId: "com.apple.Terminal", name: "Terminal"),
                    now: t0)
    try repo.insert(texto("outra coisa"),
                    source: ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
                    now: t0)

    let achados = try repo.search(text: "slack", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(achados.count == 1)
    #expect(achados[0].text == "outra coisa")
}

@Test func filtrosDeFonteETagCombinamComAnd() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let slack = ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
    let a = try repo.insert(texto("a"), source: slack, now: t0)
    _ = try repo.insert(texto("b"), source: slack, now: t0)
    _ = try repo.insert(texto("c"),
                        source: ItemSource(bundleId: "com.apple.Terminal", name: "Terminal"),
                        now: t0)
    try repo.addTag(named: "importante", to: a)
    let tagId = try #require(try repo.allTags().first?.id)

    let soFonte = try repo.search(text: "", sourceBundleId: slack.bundleId,
                                  tagId: nil, limit: 50)
    #expect(soFonte.count == 2)

    let fonteETag = try repo.search(text: "", sourceBundleId: slack.bundleId,
                                    tagId: tagId, limit: 50)
    #expect(fonteETag.map(\.text) == ["a"])
}

@Test func imagemVaiParaDiscoENaoParaOBanco() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let capturada = CapturedItem(kind: .image, text: "Imagem", imageData: png,
                                 filePath: nil, url: nil, contentHash: "hashpng")
    let id = try repo.insert(capturada, source: nil, now: t0)

    let item = try #require(try repo.search(text: "", sourceBundleId: nil,
                                            tagId: nil, limit: 50).first)
    #expect(item.id == id)
    #expect(item.blobPath == "hashpng.png")
    #expect(try repo.liveBlobPaths() == ["hashpng.png"])
}

@Test func resumoDeFontesContaItensPorApp() throws {
    let (repo, dir) = try makeRepo()
    defer { try? FileManager.default.removeItem(at: dir) }

    let slack = ItemSource(bundleId: "com.tinyspeck.slackmacgap", name: "Slack")
    try repo.insert(texto("a"), source: slack, now: t0)
    try repo.insert(texto("b"), source: slack, now: t0)
    try repo.insert(texto("c"),
                    source: ItemSource(bundleId: "com.apple.Terminal", name: "Terminal"),
                    now: t0)

    let fontes = try repo.sources()
    #expect(fontes.count == 2)
    #expect(fontes[0].name == "Slack")
    #expect(fontes[0].count == 2)
}
