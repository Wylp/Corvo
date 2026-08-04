import AppKit
import Foundation
import Testing
@testable import Corvo

final class PasteboardFalso: PasteboardReading, @unchecked Sendable {
    var changeCount = 0
    var tipos: [NSPasteboard.PasteboardType] = []
    var strings: [NSPasteboard.PasteboardType: String] = [:]
    var datas: [NSPasteboard.PasteboardType: Data] = [:]
    var urls: [URL] = []

    func data(forType t: NSPasteboard.PasteboardType) -> Data? { datas[t] }
    func string(forType t: NSPasteboard.PasteboardType) -> String? { strings[t] }
    func fileURLs() -> [URL] { urls }

    func copiarTexto(_ s: String) {
        changeCount += 1
        tipos = [.string]
        strings = [.string: s]
        datas = [:]
        urls = []
    }
}

@MainActor
private func ambiente() throws
    -> (PasteboardFalso, ItemRepository, PasteboardMonitor, URL, SourceTracker, Preferences) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-mon-\(UUID().uuidString)")
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil),
                              blobs: BlobStore(directory: dir))
    let pb = PasteboardFalso()
    let tracker = SourceTracker()
    let prefs = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let monitor = PasteboardMonitor(pasteboard: pb, repo: repo,
                                    tracker: tracker, prefs: prefs)
    return (pb, repo, monitor, dir, tracker, prefs)
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor @Test func capturaTextoQuandoOChangeCountMuda() throws {
    let (pb, repo, monitor, dir, _, _) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copiarTexto("olá")
    try monitor.poll(now: t0)

    let itens = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(itens.map(\.text) == ["olá"])
}

@MainActor @Test func naoRecapturaSeOChangeCountNaoMudou() throws {
    let (pb, repo, monitor, dir, _, _) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copiarTexto("olá")
    try monitor.poll(now: t0)
    try monitor.poll(now: t0.addingTimeInterval(0.3))

    let itens = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(itens.count == 1)
}

@MainActor @Test func descartaConteudoMarcadoComoSigiloso() throws {
    let (pb, repo, monitor, dir, _, _) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copiarTexto("senha-secreta")
    pb.tipos.append(.init(rawValue: "org.nspasteboard.ConcealedType"))
    try monitor.poll(now: t0)

    let itens = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(itens.isEmpty)
}

@MainActor @Test func descartaConteudoTransitorio() throws {
    let (pb, repo, monitor, dir, _, _) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copiarTexto("temporário")
    pb.tipos.append(.init(rawValue: "org.nspasteboard.TransientType"))
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

@MainActor @Test func descartaConteudoDeAppNaBlocklist() throws {
    let (pb, repo, monitor, dir, _, _) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    monitor.prefs.blocklist = ["com.apple.keychainaccess"]
    pb.copiarTexto("segredo")
    pb.tipos.append(.init(rawValue: "org.nspasteboard.source"))
    pb.strings[.init(rawValue: "org.nspasteboard.source")] = "com.apple.keychainaccess"
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

@MainActor @Test func descartaTextoVazio() throws {
    let (pb, repo, monitor, dir, _, _) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    pb.copiarTexto("   \n  ")
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

// O caminho que roda de verdade: quase nenhum app declara a própria fonte via
// "org.nspasteboard.source" — a fonte real vem do SourceTracker (foco do
// sistema). Os dois testes abaixo cobrem esse caminho, um por vez, e o
// segundo é o controle positivo: sem ele, o primeiro passaria mesmo com o
// `poll` quebrado e não gravando nada.
@MainActor @Test func descartaQuandoAFonteInferidaEstaNaBlocklist() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = ["com.agilebits.onepassword7"]
    tracker.registrarAtivacao(
        ItemSource(bundleId: "com.agilebits.onepassword7", name: "1Password"), at: t0)
    pb.copiarTexto("segredo")
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}

@MainActor @Test func gravaQuandoAFonteInferidaNaoEstaNaBlocklist() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = ["com.agilebits.onepassword7"]
    tracker.registrarAtivacao(ItemSource(bundleId: "com.apple.Safari", name: "Safari"), at: t0)
    pb.copiarTexto("texto normal")
    try monitor.poll(now: t0)

    let itens = try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50)
    #expect(itens.map(\.text) == ["texto normal"])
    #expect(itens.map(\.sourceBundleId) == ["com.apple.Safari"])
}

// Cobre a Correção 1: a fonte declarada não pode encobrir a inferida na
// checagem da blocklist. O tracker aponta para um app bloqueado; o
// pasteboard declara um id que não está na blocklist. Antes da correção
// (`fonte = declarada ?? inferida` avaliado sozinho) este teste falhava — o
// id declarado vencia e o item era gravado.
@MainActor @Test func fonteDeclaradaNaoEncobreFonteInferidaNaBlocklist() throws {
    let (pb, repo, monitor, dir, tracker, prefs) = try ambiente()
    defer { try? FileManager.default.removeItem(at: dir) }

    prefs.blocklist = ["com.agilebits.onepassword7"]
    tracker.registrarAtivacao(
        ItemSource(bundleId: "com.agilebits.onepassword7", name: "1Password"), at: t0)
    pb.copiarTexto("segredo")
    pb.tipos.append(.init(rawValue: "org.nspasteboard.source"))
    pb.strings[.init(rawValue: "org.nspasteboard.source")] = "com.apple.Safari"
    try monitor.poll(now: t0)

    #expect(try repo.search(text: "", sourceBundleId: nil, tagId: nil, limit: 50).isEmpty)
}
