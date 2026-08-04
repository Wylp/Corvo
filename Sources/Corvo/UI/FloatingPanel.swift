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

    init(content: some View) {
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
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: content)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    /// Breathing room between the panel and the bottom of the usable screen. On
    /// the same 8pt rhythm as the rest of the UI, and wide enough that the
    /// panel's shadow reads as a gap rather than as the panel resting on the Dock.
    private static let bottomInset: CGFloat = 24

    func show() {
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
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                                     y: area.minY + Self.bottomInset))
    }

    func hide() { panel.orderOut(nil) }
}
