import AppKit

/// Só o que o monitor precisa do pasteboard. Existe para o teste poder
/// substituir o `NSPasteboard` real, que é estado global do sistema.
///
/// A propriedade se chama `tipos`, não `types`: `NSPasteboard.types` já existe
/// (e é opcional), então redeclarar na extensão daria `invalid redeclaration`.
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var tipos: [NSPasteboard.PasteboardType] { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func fileURLs() -> [URL]
}

extension NSPasteboard: PasteboardReading {
    var tipos: [NSPasteboard.PasteboardType] {
        pasteboardItems?.first?.types ?? []
    }

    func fileURLs() -> [URL] {
        readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
