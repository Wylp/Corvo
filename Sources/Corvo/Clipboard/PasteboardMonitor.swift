import AppKit
import CryptoKit
import Foundation

@MainActor
final class PasteboardMonitor {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    private let pasteboard: PasteboardReading
    private let repo: ItemRepository
    private let tracker: SourceTracker
    let prefs: Preferences

    private var ultimoChangeCount: Int
    private var timer: Timer?

    init(pasteboard: PasteboardReading, repo: ItemRepository,
         tracker: SourceTracker, prefs: Preferences) {
        self.pasteboard = pasteboard
        self.repo = repo
        self.tracker = tracker
        self.prefs = prefs
        self.ultimoChangeCount = pasteboard.changeCount
    }

    func start() {
        // ponytail: NSPasteboard não notifica mudanças — poll do changeCount é a
        // única via. Todo gerenciador de clipboard do macOS faz assim.
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                try? self?.poll(now: Date())
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll(now: Date) throws {
        let atual = pasteboard.changeCount
        guard atual != ultimoChangeCount else { return }
        ultimoChangeCount = atual

        let tipos = Set(pasteboard.tipos)

        // Trust boundary: gerenciadores de senha marcam o conteúdo. Descartamos
        // antes de qualquer gravação, sem passar por disco nem por banco.
        guard !tipos.contains(Self.concealed), !tipos.contains(Self.transient) else { return }

        let declarada = pasteboard.string(forType: Self.sourceType)
            .map { ItemSource(bundleId: $0, name: $0) }
        let fonte = declarada ?? tracker.fonteDaCaptura(at: now)

        if let bundleId = fonte?.bundleId, prefs.blocklist.contains(bundleId) { return }

        guard let capturado = capturar(tipos: tipos) else { return }
        try repo.insert(capturado, source: fonte, now: now)
    }

    private func capturar(tipos: Set<NSPasteboard.PasteboardType>) -> CapturedItem? {
        let url = pasteboard.string(forType: .URL)

        let arquivos = pasteboard.fileURLs()
        if let arquivo = arquivos.first {
            return CapturedItem(kind: .file, text: arquivo.lastPathComponent,
                                imageData: nil, filePath: arquivo.path, url: url,
                                contentHash: Self.hash(of: Data(arquivo.path.utf8)))
        }

        if tipos.contains(.tiff) || tipos.contains(.png) {
            let tipo: NSPasteboard.PasteboardType = tipos.contains(.png) ? .png : .tiff
            guard let bruto = pasteboard.data(forType: tipo),
                  let png = Self.paraPNG(bruto) else { return nil }
            return CapturedItem(kind: .image, text: "Imagem", imageData: png,
                                filePath: nil, url: url,
                                contentHash: Self.hash(of: png))
        }

        guard let texto = pasteboard.string(forType: .string),
              !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CapturedItem(kind: .text, text: texto, imageData: nil,
                            filePath: nil, url: url,
                            contentHash: Self.hash(of: Data(texto.utf8)))
    }

    private static func paraPNG(_ dados: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: dados) else { return dados }
        return rep.representation(using: .png, properties: [:])
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
