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
    enum Outcome {
        case pasted
        case nothingToWrite
        case noPermission
    }

    /// Writes to the clipboard and pastes into the given app. The content is on
    /// the clipboard in every outcome but `.nothingToWrite`, so a caller that
    /// cannot paste can still tell the user to press ⌘V.
    static func paste(_ item: ClipItem, blobs: BlobStore,
                      into app: NSRunningApplication?) -> Outcome {
        guard writeToClipboard(item, blobs: blobs) else { return .nothingToWrite }
        guard hasPermission else { return .noPermission }

        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCmdV()
        }
        return .pasted
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
