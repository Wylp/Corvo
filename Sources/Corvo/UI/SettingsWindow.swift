import AppKit
import SwiftUI

/// The Settings window, owned by us rather than by SwiftUI's `Settings` scene.
///
/// `SettingsLink` never opened anything here. Corvo is an accessory app — no
/// Dock icon, never the active application — and the `Settings` scene wants an
/// activation it does not perform itself, so the menu item read as dead. The
/// panel has always managed its own `NSWindow` and has always opened; this is
/// the same pattern, applied to the one window that was left to SwiftUI.
///
/// The window is built on first use and kept: preferences hold live bindings to
/// `Preferences`, and rebuilding on every open would drop whatever was typed and
/// not yet committed.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let makeContent: @MainActor () -> AnyView?

    /// - Parameter makeContent: returns nil until the app environment exists.
    ///   Nothing can open before then, and this is what keeps a half-built app
    ///   from showing an empty window.
    init(makeContent: @escaping @MainActor () -> AnyView?) {
        self.makeContent = makeContent
    }

    func show() {
        if window == nil {
            guard let content = makeContent() else { return }
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = String(localized: "Corvo Settings")
            w.contentView = NSHostingView(rootView: content)
            // Closing must not destroy it: the content holds bindings, and a
            // released window would take an uncommitted edit down with it.
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Both, and in this order: an accessory app is never frontmost on its
        // own, so ordering the window front without activating leaves it behind
        // whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
