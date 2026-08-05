import AppKit
import UniformTypeIdentifiers

/// Picking a source app that the history has never seen.
///
/// "Tag everything I copy from Claude" has to be writable *before* the first
/// copy from Claude exists, so the apps already in the history are only the
/// likely answers, never the whole set. `NSOpenPanel` is an app browser that is
/// already written, already sandboxed, already keyboard-navigable and already
/// localized — writing a second one would buy nothing.
@MainActor
enum AppChooser {
    /// The value the picker's browse row carries. A menu can only offer a
    /// command as one more tag, and this one has to be a `String` that no app
    /// can own: a bundle identifier is a reverse-DNS name, so a control
    /// character rules out every real one.
    static let browseTag = "\u{7F}browse"

    /// The chosen `.app`, or `nil` if the panel was cancelled. Configured like
    /// the blocklist's picker in Settings, which is the same job: name an app
    /// without making anyone recall its bundle id.
    static func run() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        // The default button says "Open", which reads as "launch this app" —
        // the opposite of what pressing it does here.
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the app this rule should match.")
        // Corvo is an accessory app (`LSUIElement`), so it is not necessarily
        // the active application even with its own window in front. Without
        // this the picker can open behind everything.
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// `nil` for a bundle with no readable identifier. Rare, but a broken or
    /// hand-assembled `.app` has one, and a rule keyed on nothing would match
    /// nothing forever without ever saying so.
    static func bundleId(forApplicationAt url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    /// The app's name on disk. `nil` when nothing is installed under that id,
    /// which is the normal answer for a rule that outlived its app.
    static func name(forBundleId bundleId: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?
            .deletingPathExtension().lastPathComponent
    }

    /// What the picker offers: the apps the history has seen, plus the one the
    /// rule already names when it is not among them — chosen from the panel a
    /// moment ago, or seen once and since gone quiet. Without this the picker
    /// would find its own value missing from the menu and show a blank row.
    static func choices(seen: [SourceSummary], selected: String?) -> [SourceSummary] {
        guard let selected, !seen.contains(where: { $0.bundleId == selected }) else { return seen }
        // The id is the name of last resort: an app that is not installed has no
        // other one, and a blank row would be worse than a reverse-DNS string.
        return seen + [SourceSummary(bundleId: selected,
                                     name: name(forBundleId: selected) ?? selected,
                                     count: 0)]
    }
}
