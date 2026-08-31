import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts an item back on the clipboard and, when allowed, pastes it into the app
/// the user came from.
///
/// The clipboard write always happens first and never depends on any
/// permission: copying is the useful half of the feature on its own, and the
/// paste is the half that needs Accessibility.
enum Paster {
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Asks the system for Accessibility permission, which also registers Corvo
    /// in the Accessibility list so the user has something to toggle there.
    ///
    /// ponytail: nothing calls this today — the missing-permission path shows
    /// our own alert and opens Settings, which explains more than the system
    /// prompt does. Kept as the specified interface; wire it in if the app ever
    /// asks for permission up front instead of on first paste.
    static func requestPermission() {
        // The literal, not `kAXTrustedCheckOptionPrompt`: the imported constant
        // is a global `var` and strict concurrency rejects reading it. The value
        // is the documented key name and does not change.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Replaces the clipboard contents with `item`. Returns `false` when the
    /// item has nothing left to offer — an image whose blob is gone, a file
    /// whose path is gone — in which case the clipboard is left untouched
    /// rather than cleared, so the user does not lose what was already there.
    @discardableResult
    static func writeToClipboard(_ item: ClipItem, blobs: BlobStore,
                                 to pasteboard: NSPasteboard = .general) -> Bool {
        guard let content = content(of: item, blobs: blobs) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([content])
    }

    /// Replaces the clipboard contents with several clippings at once, and
    /// answers **how many of them actually got there**.
    ///
    /// The clipboard holds one payload per type, so N clippings have to collapse
    /// into one thing. Files are the case that survives intact: `writeObjects`
    /// already takes an array, so a run of file clippings goes over as several
    /// URLs and the receiving app pastes all of them. Everything else collapses
    /// to text joined by newlines, in list order — the order on screen, which is
    /// the order the user read them in.
    ///
    /// A count and not a `Bool`, because the interesting answer is neither
    /// "worked" nor "failed": an image has no text to contribute to a join, so a
    /// run of two notes and a screenshot succeeds *and* carries two. A boolean
    /// cannot say that, and what a boolean cannot say the user never hears.
    @discardableResult
    static func writeToClipboard(_ items: [ClipItem], blobs: BlobStore,
                                 to pasteboard: NSPasteboard = .general) -> Int {
        guard items.count > 1 else {
            guard let only = items.first else { return 0 }
            return writeToClipboard(only, blobs: blobs, to: pasteboard) ? 1 : 0
        }

        let urls = items.compactMap(fileURL(of:))
        if urls.count == items.count {
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls) ? urls.count : 0
        }

        let carried = items.compactMap(plainText(of:))
        // ponytail: a selection of nothing but images has no text to join, so it
        // falls back to the first one rather than clearing the clipboard for
        // nothing. Give images a real multi-image representation if that turns
        // out to matter — no pasteboard type carries N images today. The count
        // is what makes the shortfall reach the user in the meantime.
        guard !carried.isEmpty else {
            return writeToClipboard(items[0], blobs: blobs, to: pasteboard) ? 1 : 0
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([carried.joined(separator: "\n") as NSString])
            ? carried.count : 0
    }

    /// What a clipping contributes to a joined multi-item paste. A file gives up
    /// its path, which is the thing about it that is text; an image has no text
    /// to give and drops out of the join.
    private static func plainText(of item: ClipItem) -> String? {
        switch item.kind {
        case .text: item.text
        case .file: item.filePath
        case .image: nil
        }
    }

    /// `nil` for anything that is not a file still on disk — same check the
    /// single-item path makes, for the same reason: the file is a reference we
    /// never copied.
    private static func fileURL(of item: ClipItem) -> NSURL? {
        guard item.kind == .file, let path = item.filePath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    private static func content(of item: ClipItem, blobs: BlobStore) -> (any NSPasteboardWriting)? {
        switch item.kind {
        case .text:
            guard let text = item.text else { return nil }
            return text as NSString
        case .image:
            guard let path = item.blobPath else { return nil }
            return NSImage(contentsOf: blobs.url(for: path))
        case .file:
            // The file is a reference we never copied, so it may be gone by now.
            guard let path = item.filePath,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path) as NSURL
        }
    }

    /// How long to wait after reactivating `app` before posting the ⌘V.
    ///
    /// Physical calibration, not a magic number: activating an app takes real
    /// time and AppKit offers no reliable "it has the focus now" callback, so
    /// the keystroke has to be aimed slightly ahead of the target. Raise it if
    /// the paste ever lands in the wrong window.
    static let activationDelay: TimeInterval = 0.12

    /// What became of a paste. `Bool` was the wrong shape: the old code answered
    /// `true` — pasted — when there was nothing left to write, so a clipping
    /// whose file had been moved away closed the panel and did nothing at all,
    /// with no way for the caller to say so.
    enum Outcome: Equatable {
        case pasted
        case nothingToWrite
        case noPermission
        /// Part of a run reached the clipboard and the rest could not. The
        /// clipboard holds one payload per type, so several clippings collapse
        /// into one thing, and an image has no text to contribute to that join:
        /// two notes and a screenshot arrive as two. The paste itself went
        /// through — this says what was in it.
        ///
        /// It exists because the alternative is losing a clipping in silence.
        /// The user marked three, watched the panel close, and has no way to
        /// learn that one of them never went anywhere.
        case partial(pasted: Int, of: Int)
    }

    /// Writes to the clipboard and pastes into the given app. The content is on
    /// the clipboard in every outcome but `.nothingToWrite`, so a caller that
    /// cannot paste can still tell the user to press ⌘V.
    static func paste(_ item: ClipItem, blobs: BlobStore,
                      into app: NSRunningApplication?) -> Outcome {
        paste([item], blobs: blobs, into: app)
    }

    /// The multi-item form. One clipping is the same journey as several, so the
    /// singular above is a call into this rather than a second copy of it.
    ///
    /// `.noPermission` outranks `.partial`: a run that reached the clipboard
    /// but could not be pasted anywhere is a worse thing to be told about than
    /// one that pasted less than it held, and the user needs the permission
    /// sentence first. The count is still recoverable — everything written is
    /// on the clipboard for a manual ⌘V.
    @discardableResult
    static func paste(_ items: [ClipItem], blobs: BlobStore,
                      into app: NSRunningApplication?) -> Outcome {
        let written = writeToClipboard(items, blobs: blobs)
        guard written > 0 else { return .nothingToWrite }
        guard hasPermission else { return .noPermission }

        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCmdV()
        }
        return written < items.count
            ? .partial(pasted: written, of: items.count)
            : .pasted
    }

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
