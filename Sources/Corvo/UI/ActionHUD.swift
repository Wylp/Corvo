import AppKit
import SwiftUI

/// The brief "Copied" that appears after the panel has gone.
///
/// Confirming a clipping closes the panel, so the one moment the user could be
/// told it worked is the moment there is nothing left on screen to tell them
/// with. Without this, copying and the panel simply not responding look
/// identical — which matters more now that copying is what ⏎ does by default.
///
/// A window and not a notification, and the reasons are all about frequency.
/// `UNUserNotificationCenter` needs authorization Corvo asks for lazily, so the
/// first copy would raise a permission prompt; a banner takes about a second to
/// appear, which is late for a confirmation; and every one of them stays in
/// Notification Center, which for something used dozens of times a day is
/// hundreds of entries nobody asked for. This is the shape macOS itself uses to
/// confirm an action — volume, brightness — and it costs the user nothing to
/// ignore.
///
/// One instance, like `PreviewPanel`, because there is one panel and therefore
/// one of these.
@MainActor
final class ActionHUD {
    static let shared = ActionHUD()

    /// **Calibration, both numbers — tune by feel.** Long enough to register
    /// out of the corner of the eye while the hands are already moving back to
    /// the keyboard, short enough that a second copy never queues behind the
    /// first one's fade.
    static let dwell: Duration = .milliseconds(900)
    static let fade: TimeInterval = 0.18

    private var window: NSPanel?
    private var dismissal: Task<Void, Never>?

    private init() {}

    func show(_ message: LocalizedStringKey, icon: String) {
        dismissal?.cancel()
        let panel = window ?? makeWindow()
        window = panel
        panel.contentView = NSHostingView(rootView: Card(message: message, icon: icon))
        place(panel)
        panel.alphaValue = 1
        // `orderFrontRegardless`, not `makeKeyAndOrderFront`: this must never
        // take focus. The whole point is that it appears after Corvo has handed
        // the machine back, and stealing key would put the user's cursor
        // somewhere other than where they are about to type.
        panel.orderFrontRegardless()

        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel = window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above everything, including full-screen apps: the user has just left
        // Corvo for whatever they were doing, and a confirmation behind that
        // window would confirm nothing.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        return panel
    }

    /// Centred horizontally, low on the screen — where macOS puts its own
    /// action HUDs, and out of the way of what the user is about to type into.
    ///
    /// The screen with the mouse on it, not the main one: that is where the user
    /// is looking, and on a two-monitor desk `NSScreen.main` is frequently the
    /// other one.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + frame.height * 0.12))
    }

    private struct Card: View {
        let message: LocalizedStringKey
        let icon: String

        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                Text(message)
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(.primary)
            .frame(width: 180, height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
    }
}
