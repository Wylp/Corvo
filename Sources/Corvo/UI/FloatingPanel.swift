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
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
            styleMask: [.titled, .closable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: content)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }
}
