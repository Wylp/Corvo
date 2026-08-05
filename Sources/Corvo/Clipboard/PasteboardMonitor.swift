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
    private let autoTagger: AutoTagger
    let prefs: Preferences

    /// A tag that asks to name what it catches just caught something. Carries
    /// the item, the tag that spoke, and the captured text for the prompt to
    /// quote back. `nil` wherever nothing is listening, which is every test and
    /// every build without a notification centre behind it.
    var onNeedsName: ((Int64, Tag, String?) -> Void)?

    private var lastChangeCount: Int
    private var timer: Timer?

    init(pasteboard: PasteboardReading, repo: ItemRepository,
         tracker: SourceTracker, prefs: Preferences) {
        self.pasteboard = pasteboard
        self.repo = repo
        self.tracker = tracker
        self.autoTagger = AutoTagger(repo: repo, prefs: prefs)
        self.prefs = prefs
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        // ponytail: NSPasteboard does not notify on change — polling changeCount
        // is the only way. Every macOS clipboard manager does it like this.
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                do {
                    try self?.poll(now: Date())
                } catch {
                    // A transient database write failure should not stop the
                    // timer or bother the user, but must leave a trace.
                    NSLog("Corvo: poll failed: \(error)")
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Corvo just wrote to the pasteboard itself; do not capture that write.
    /// Text would merely dedupe, but an image goes back out as TIFF and
    /// re-encodes to a PNG whose bytes differ from the stored blob — a fresh
    /// hash, a new row and a new blob on every single paste.
    func ignoreCurrentContents() {
        lastChangeCount = pasteboard.changeCount
    }

    func poll(now: Date) throws {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let types = Set(pasteboard.availableTypes)

        // Trust boundary: password managers mark their content. We discard it
        // before any write, so it never touches disk or database.
        guard !types.contains(Self.concealed), !types.contains(Self.transient) else { return }

        let declared = pasteboard.string(forType: Self.sourceType)
            .map { ItemSource(bundleId: $0, name: $0) }
        let inferred = tracker.captureSource(at: now)
        let source = declared ?? inferred

        // The blocklist checks BOTH identities: an app declaring an id that is
        // not its own must not bypass the block the user configured.
        if [declared?.bundleId, inferred?.bundleId].compactMap({ $0 })
            .contains(where: prefs.blocklist.contains) { return }

        guard let captured = capture(types: types) else { return }
        let id = try repo.insert(captured, source: source, now: now)

        // Last, and on purpose: every guard above decides whether this content
        // may exist at all, and rules only ever see what survived them.
        //
        // The item is already stored by this point, so a rule that fails must
        // not take the capture down with it — same reasoning as the catch in
        // `start()`. Losing a tag is an annoyance; losing the clipping is the
        // one thing this app exists to prevent.
        do {
            let promptable = try autoTagger.apply(toItem: id, kind: captured.kind,
                                                  text: captured.text,
                                                  sourceBundleId: source?.bundleId)
            // `.first`, not all of them: two tags asking about one clipping is
            // still one question — "what is this?" — and there is one name to
            // give in answer. A prompt per matching tag would be two banners
            // writing to the same column.
            if let tag = promptable.first {
                onNeedsName?(id, tag, captured.text)
            }
        } catch {
            NSLog("Corvo: auto-tagging failed: \(error)")
        }
    }

    private func capture(types: Set<NSPasteboard.PasteboardType>) -> CapturedItem? {
        let url = pasteboard.string(forType: .URL)

        // ponytail: only the first file of a multi-file copy is captured; the
        // rest are dropped silently. Upgrade: one CapturedItem per file, or
        // serialize the list, if multi-file copies become a common case.
        let files = pasteboard.fileURLs()
        if let file = files.first {
            return CapturedItem(kind: .file, text: file.lastPathComponent,
                                imageData: nil, filePath: file.path, url: url,
                                contentHash: Self.hash(of: Data(file.path.utf8)))
        }

        if types.contains(.tiff) || types.contains(.png) {
            let type: NSPasteboard.PasteboardType = types.contains(.png) ? .png : .tiff
            guard let raw = pasteboard.data(forType: type),
                  let png = Self.toPNG(raw) else { return nil }
            // "Image" is stored content, not UI copy: it is the row's readable
            // name. UI strings go through the String Catalog (Task 10).
            return CapturedItem(kind: .image, text: "Image", imageData: png,
                                filePath: nil, url: url,
                                contentHash: Self.hash(of: png))
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CapturedItem(kind: .text, text: text, imageData: nil,
                            filePath: nil, url: url,
                            contentHash: Self.hash(of: Data(text.utf8)))
    }

    private static func toPNG(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return data }
        return rep.representation(using: .png, properties: [:])
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
