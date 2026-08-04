import AppKit

/// Only what the monitor needs from the pasteboard. It exists so tests can
/// replace the real `NSPasteboard`, which is global system state.
///
/// The property is called `availableTypes`, not `types`: `NSPasteboard.types`
/// already exists (and is optional), so redeclaring it in the extension would
/// be an `invalid redeclaration`.
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var availableTypes: [NSPasteboard.PasteboardType] { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func fileURLs() -> [URL]
}

extension NSPasteboard: PasteboardReading {
    var availableTypes: [NSPasteboard.PasteboardType] {
        // flatMap, not first: the secrecy guard has to see the marker on any
        // item, since string(forType:) reads the whole pasteboard.
        pasteboardItems?.flatMap(\.types) ?? []
    }

    func fileURLs() -> [URL] {
        readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
