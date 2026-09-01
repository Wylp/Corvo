import AppKit
import SwiftUI

/// `NSPanel` needs the `canBecomeKey` override so the search field can take
/// focus — a plain panel never becomes the key window.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)   // Esc closes
    }
}

@MainActor
final class PanelController {
    private let panel: FloatingPanel
    private let clearTransientState: @MainActor () -> Void
    private let resetToDefaultView: @MainActor () -> Void
    /// `nonisolated(unsafe)` only so that `deinit` may read it: it is written
    /// once, on the main actor, and read after the last reference is gone.
    private nonisolated(unsafe) var deactivation: (any NSObjectProtocol)?

    /// - Parameter clearTransientState: run before every opening, and again
    ///   whenever the app resigns active — which is the one moment the panel
    ///   leaves the screen without a call of ours in it. Between the two, no
    ///   sheet can survive a round trip: the panel is only ever on screen after
    ///   `show()`, or after an activation that a deactivation came before.
    /// - Parameter resetToDefaultView: run only on a deliberate opening. The two
    ///   are separate because they answer to different moments, and giving them
    ///   one closure quietly gives the wider one the narrower one's timing. A
    ///   sheet must not survive a round trip at all, so it is cleared on both.
    ///   What the user is looking *at* is not transient in that sense: losing a
    ///   search and a filter because another app took focus for a moment is the
    ///   same interruption this reset exists to prevent, pointed the other way.
    init(content: some View,
         clearTransientState: @escaping @MainActor () -> Void = {},
         resetToDefaultView: @escaping @MainActor () -> Void = {}) {
        self.clearTransientState = clearTransientState
        self.resetToDefaultView = resetToDefaultView
        // Borderless: a quick-paste panel that hides on deactivate has no use for
        // close/minimise/zoom — Esc is the way out, and the key rail says so. The
        // window itself is transparent so the content's rounded corners show.
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
            styleMask: [.nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Deliberately NOT `hidesOnDeactivate`. The panel still goes away when
        // the app resigns active — see the observer below — but it goes away
        // because we say so, which is the whole point.
        //
        // AppKit enforces "a hidesOnDeactivate window is not on screen while its
        // app is inactive" by ordering such a window straight back out, and
        // `show()` orders this one front immediately after
        // `NSApp.activate(ignoringOtherApps:)` — which does not activate
        // synchronously. Lose that race and the press opens nothing, while the
        // next press finds the app already active and works. That is the
        // "sometimes I have to hit the hotkey twice" bug: the second half of the
        // same sentence the observer below is about, AppKit moving this window
        // with no call of ours in it.
        //
        // ponytail: our hide runs on `didResignActive`, which can be a frame
        // later than AppKit's own. If switching apps ever shows the panel
        // lingering, that is the cost — revert this line and put the orderFront
        // behind the activation instead.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: content)

        // The panel leaves the screen when the user goes somewhere else, and
        // this is where that happens now — `hidesOnDeactivate` used to do it,
        // along with restoring the window on the way back, both without a call
        // of ours anywhere in them. Clearing here is also what stops a sheet
        // coming back over a window that can no longer dismiss it.
        //
        // Not `didResignKey`, which is the tempting one: a sheet and the tag
        // editor's open panel both take key away from this window while it is
        // still very much on screen. Not KVO on `isVisible` either —
        // `makeKeyAndOrderFront` posts true, false and true again, so "became
        // invisible" cannot be told from "is opening".
        deactivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak panel] _ in
                MainActor.assumeIsolated {
                    clearTransientState()
                    panel?.orderOut(nil)
                }
            }
    }

    deinit {
        guard let deactivation else { return }
        NotificationCenter.default.removeObserver(deactivation)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    /// Breathing room between the panel and the bottom of the usable screen. On
    /// the same 8pt rhythm as the rest of the UI, and wide enough that the
    /// panel's shadow reads as a gap rather than as the panel resting on the Dock.
    private static let bottomInset: CGFloat = 24
    private static let widthFraction: CGFloat = 0.85

    func show() {
        // Before the window is on screen, not after: the panel opens on the
        // history, never on whatever sheet was up when it was last put away.
        clearTransientState()
        resetToDefaultView()
        anchorToBottom()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Centred horizontally and anchored low, on the screen holding the pointer.
    /// With two displays the panel belongs where the work is, not on whichever
    /// one macOS calls main. `visibleFrame`, not `frame`: it already excludes the
    /// Dock and the menu bar, so the panel never opens behind the Dock.
    private func anchorToBottom() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        // The panel is sized per screen rather than fixed: a card carousel is
        // only as useful as the number of cards it can show at once.
        let width = (area.width * Self.widthFraction).rounded()
        let height = panel.frame.height
        panel.setFrame(NSRect(x: area.midX - width / 2,
                              y: area.minY + Self.bottomInset,
                              width: width, height: height),
                       display: true)
    }

    func hide() { panel.orderOut(nil) }
}
