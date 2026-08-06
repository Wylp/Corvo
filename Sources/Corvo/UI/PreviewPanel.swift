import AppKit
import SwiftUI

/// The hover preview's window, and the timing that decides when it is on screen.
///
/// A window rather than an overlay inside the panel: the panel is 420pt tall and
/// anchored to the bottom of the screen, and a preview worth opening does not fit
/// in it. It is a *child* window of the panel, which is the whole trick — AppKit
/// orders a child out with its parent, so the preview cannot outlive the panel on
/// screen no matter which of the several ways the panel goes away (Esc, ⏎, ⌘C,
/// the hotkey, or `hidesOnDeactivate` taking it away with no call of ours in it).
///
/// One instance, reached through `shared`, because there is exactly one panel and
/// therefore exactly one preview. `HistoryView` drives it from hover, and
/// `CorvoApp` hands it to `PanelController` as transient state to clear — the
/// same mechanism the tag sheet uses, for the same reason.
@MainActor
final class PreviewPanel {
    static let shared = PreviewPanel()

    private init() {}

    // MARK: - Calibration

    /// How long the pointer has to stay on a card before the preview opens.
    ///
    /// **This is a calibration knob, not a constant — tune it by feel.** Too
    /// short and sweeping the carousel strobes: every card the pointer crosses
    /// flashes a window. Too long and the feature reads as broken, because the
    /// user has already decided they want to look and nothing is happening.
    /// 400ms sits between the two: a pointer travelling across the carousel
    /// spends well under 200ms on any one card, so a sweep opens nothing, while
    /// a deliberate stop pays a pause short enough to feel like a response.
    static let hoverDelay: Duration = .milliseconds(400)

    /// How long the preview survives the pointer leaving.
    ///
    /// **Also calibration.** Its only job is to stop the preview blinking as the
    /// pointer crosses the 12pt gutter between two cards, or the gap between the
    /// panel's top edge and the preview itself. Long enough to cross either,
    /// short enough that leaving the carousel feels like closing it.
    static let dismissGrace: Duration = .milliseconds(150)

    /// Fixed, and deliberately so: sizing the window to its content would make
    /// it jump as the pointer moves from a one-line clipping to a long one,
    /// which is both visible jitter and a window relayout per card. A constant
    /// box costs some whitespace under a short clipping and buys stability while
    /// sweeping. Roughly three times the card's area, which is what turns "ten
    /// lines and a thumbnail" into something worth reading.
    static let size = CGSize(width: 420, height: 340)

    /// Between the panel's top edge and the preview's bottom edge.
    private static let gap: CGFloat = 10
    /// Between the preview and the edges of the usable screen.
    private static let screenMargin: CGFloat = 12
    /// Below this the preview would be a letterbox rather than a preview, so it
    /// does not open at all. Reached only on a very short screen.
    private static let minimumHeight: CGFloat = 140

    // MARK: - State

    private var panel: NSPanel?
    private var host: NSHostingView<PreviewContent>?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// The clipping the preview is showing, or is counting down to show. Keyed
    /// on this rather than on a boolean so that moving along the carousel
    /// *replaces* the content instead of closing and reopening.
    private var subject: Int64?
    private var isShowing = false

    // MARK: - Hover

    /// The pointer is on `item`, with the card's horizontal centre at `cardMidX`
    /// in screen coordinates. Called on every pointer movement over the card, so
    /// it has to be cheap and idempotent: for a card that is already showing or
    /// already counting down, this only updates the anchor.
    ///
    /// - Parameter tags: read lazily, because this runs on every mouse move and
    ///   the tags come from a database query. It is called only when the preview
    ///   actually opens.
    func hover(item: ClipItem, cardMidX: CGFloat, blobs: BlobStore,
               tags: @escaping () -> [Tag]) {
        guard let id = item.id else { return }
        // Whatever was scheduled to close is no longer wanted: the pointer is
        // back on a card.
        closeTask?.cancel()
        closeTask = nil

        guard subject != id else { return reanchor(cardMidX: cardMidX) }
        subject = id
        openTask?.cancel()

        // Already on screen for a different card, so there is no dwell to pay a
        // second time — the user has demonstrated they are reading previews, and
        // making them wait again on every card is what makes a preview feel slow.
        guard !isShowing else {
            return present(item: item, tags: tags(), blobs: blobs, cardMidX: cardMidX)
        }
        openTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled, let self, self.subject == id else { return }
            self.present(item: item, tags: tags(), blobs: blobs, cardMidX: cardMidX)
        }
    }

    /// The pointer left a card. Not a dismissal on its own — the gutter between
    /// two cards counts as leaving one of them.
    func endHover() {
        openTask?.cancel()
        openTask = nil
        subject = nil
        guard isShowing, closeTask == nil else { return }
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dismissGrace)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// The pointer is on the preview itself, which is how its text gets scrolled.
    func keepAlive() {
        closeTask?.cancel()
        closeTask = nil
    }

    /// Takes the preview down now and forgets what it was showing.
    ///
    /// The one entry point for every non-hover reason to close: a keyboard
    /// shortcut, and `PanelController`'s transient-state clearing.
    func dismiss() {
        openTask?.cancel()
        openTask = nil
        closeTask?.cancel()
        closeTask = nil
        subject = nil
        isShowing = false
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Drops the decoded thumbnail and the highlighted text rather than
        // holding them until the next hover replaces them.
        host?.rootView = PreviewContent(payload: nil)
    }

    // MARK: - Presentation

    private func present(item: ClipItem, tags: [Tag], blobs: BlobStore, cardMidX: CGFloat) {
        guard let parent = Self.parentPanel() else { return dismiss() }
        guard let frame = Self.frame(cardMidX: cardMidX, parent: parent) else { return }

        let panel = self.panel ?? makePanel()
        host?.rootView = PreviewContent(payload: PreviewPayload(item: item, tags: tags,
                                                                blobs: blobs))
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        isShowing = true
    }

    private func reanchor(cardMidX: CGFloat) {
        guard isShowing, let panel, let parent = panel.parent,
              let frame = Self.frame(cardMidX: cardMidX, parent: parent) else { return }
        panel.setFrame(frame, display: true)
    }

    /// Never key, never main, never activating: the search field holds focus the
    /// entire time the panel is open, and a preview that took it would kill the
    /// one interaction the panel exists for. `nonactivatingPanel` also means
    /// showing it does not switch the frontmost app.
    ///
    /// It is not `ignoresMouseEvents`, though, and that is deliberate — the text
    /// has to be scrollable, and scroll wheel events reach a window that cannot
    /// become key. It can only ever be hovered and scrolled; it has no controls,
    /// so there is nothing in it to click.
    private func makePanel() -> NSPanel {
        let panel = NonKeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the panel's own `.floating`, so it is never drawn behind the
        // window it belongs to.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: PreviewContent(payload: nil))
        panel.contentView = host
        self.host = host
        self.panel = panel
        return panel
    }

    private final class NonKeyPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static func parentPanel() -> NSWindow? {
        NSApp.windows.first { $0 is FloatingPanel && $0.isVisible }
    }

    /// The screen the panel is on — which `PanelController` already chose by the
    /// pointer — and `visibleFrame`, which already excludes the menu bar and the
    /// Dock.
    private static func frame(cardMidX: CGFloat, parent: NSWindow) -> NSRect? {
        frame(cardMidX: cardMidX, panelFrame: parent.frame,
              area: (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame)
    }

    /// Above the panel, aligned to the card, and inside the screen.
    ///
    /// Above the *panel's top edge* rather than the card's: the card's top is
    /// below the search field, and a preview anchored there would cover the field
    /// the user is typing into. The panel's top edge is above every card in it,
    /// so this is still "above the card" — it just also stays out of the panel's
    /// own way.
    ///
    /// Three ways the naive rectangle escapes `area`, all handled: a card near
    /// the right edge pushes the preview off the side, a card near the left edge
    /// pushes it off the other one, and a short screen leaves less headroom above
    /// the panel than the preview wants. `nil` when what is left would be a
    /// letterbox rather than a preview.
    ///
    /// Split from the screen lookup above and left `internal` on purpose: this
    /// arithmetic is the one part of the feature that cannot be confirmed by
    /// looking at the app, so it is confirmed by a test instead.
    static func frame(cardMidX: CGFloat, panelFrame: NSRect, area: NSRect) -> NSRect? {
        let y = panelFrame.maxY + gap
        let height = min(size.height, area.maxY - screenMargin - y)
        guard height >= minimumHeight else { return nil }

        let lowest = area.minX + screenMargin
        let highest = area.maxX - size.width - screenMargin
        let wanted = cardMidX - size.width / 2
        // `highest < lowest` on a screen narrower than the preview plus its
        // margins, where clamping has no valid range to clamp into.
        let x = highest < lowest ? lowest : min(max(wanted, lowest), highest)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: height.rounded())
    }
}
