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
                contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            // A fallback, not the title: `PreferencesView` sets a
            // `navigationTitle` per pane and that is what shows from the first
            // frame on. This is only what the window is called before the
            // hosting view has laid out.
            w.title = String(localized: "Corvo Settings")
            // No `titlebarAppearsTransparent` here, though a source list window
            // usually wants it: `NavigationSplitView` already runs the sidebar
            // to the top of the window on its own. Setting it was tried and
            // rendered identically apart from losing the titlebar separator.
            let hosting = NSHostingView(rootView: content)
            w.contentView = hosting
            // Sized from the content instead of from a number written here. The
            // two used to be set separately, 460 against the view's 420, and the
            // window was 40pt wider than anything in it.
            w.setContentSize(hosting.fittingSize)
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
