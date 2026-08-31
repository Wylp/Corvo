import AppKit
import SwiftUI

/// The hover preview's window, and the timing that decides when it is on screen.
///
/// A window rather than an overlay inside the panel: the panel is 420pt tall and
/// anchored to the bottom of the screen, and a preview worth opening does not fit
/// in it — a screenshot wants most of the screen's height, which is the whole
/// point. It is a *child* window of the panel, which is the trick — AppKit
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

    /// A reading column for a text clipping: about ninety monospaced columns at
    /// `.subheadline`, which is a real line of code with its indentation still
    /// on it, and about thirty lines tall before anything has to be scrolled.
    ///
    /// **Calibration, both numbers.** Wider and the eye loses the line return;
    /// taller and the preview starts covering the panel's own neighbourhood on a
    /// laptop screen.
    static let textSize = CGSize(width: 720, height: 560)

    /// A path and an icon. The least interesting of the three kinds, and sized
    /// like it — there is nothing else true to say about a file, and inventing
    /// something to fill a larger panel is how the header got here in the first
    /// place.
    /// Tall enough for the name and three wrapped lines of path, and not one
    /// point taller — an empty half of a panel reads as something failing to
    /// load.
    static let fileSize = CGSize(width: 440, height: 108)

    /// The most of the usable screen height a picture may take.
    ///
    /// The picture is the reason the preview exists — ten lines and a thumbnail
    /// were never the problem, a screenshot at 160 points wide was. It gets the
    /// biggest share of the three, bounded so the preview still reads as an
    /// overlay on the desktop rather than as a window that took it over.
    static let imageHeightShare: CGFloat = 0.70

    /// Below this a preview is a sliver rather than a preview. Only a very small
    /// picture reaches it, and it exists so that one opens as a small panel
    /// rather than as a 32-point sliver of window furniture.
    static let minimumSize = CGSize(width: 160, height: 108)

    /// Between the panel's top edge and the preview's bottom edge.
    private static let gap: CGFloat = 10
    /// Between the preview and the edges of the usable screen.
    private static let screenMargin: CGFloat = 12
    /// Less headroom than this above the panel and the preview does not open at
    /// all: what would fit is a letterbox. Reached only on a very short screen.
    private static let minimumHeadroom: CGFloat = 140

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
    func hover(item: ClipItem, cardMidX: CGFloat, blobs: BlobStore) {
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
            return present(item: item, blobs: blobs, cardMidX: cardMidX)
        }
        openTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled, let self, self.subject == id else { return }
            self.present(item: item, blobs: blobs, cardMidX: cardMidX)
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

    private func present(item: ClipItem, blobs: BlobStore, cardMidX: CGFloat) {
        guard let parent = Self.parentPanel() else { return dismiss() }
        let area = Self.usableArea(of: parent)
        // The payload is decoded to the size this screen can actually show, so
        // the budget has to be known before the picture is read — which is why
        // the box is computed here and handed down rather than derived inside
        // the payload.
        let payload = PreviewPayload(
            item: item, blobs: blobs,
            imagePixelBudget: Self.imagePixelBudget(panelFrame: parent.frame, area: area,
                                                    scale: parent.backingScaleFactor))
        guard let frame = Self.frame(for: payload, cardMidX: cardMidX,
                                     panelFrame: parent.frame, area: area) else { return }

        let panel = self.panel ?? makePanel()
        host?.rootView = PreviewContent(payload: payload)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        isShowing = true
    }

    /// Moving along the carousel to a card whose preview is already open: only
    /// the anchor changed, so the size the content asked for is kept rather than
    /// recomputed.
    private func reanchor(cardMidX: CGFloat) {
        guard isShowing, let panel, let parent = panel.parent else { return }
        panel.setFrame(Self.place(size: panel.frame.size, cardMidX: cardMidX,
                                  panelFrame: parent.frame, area: Self.usableArea(of: parent)),
                       display: true)
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
        // Any size: `present` sets the real frame before the window is ordered
        // in, and the real one is a property of the clipping.
        let panel = NonKeyPanel(contentRect: NSRect(origin: .zero, size: Self.textSize),
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
    private static func usableArea(of parent: NSWindow) -> NSRect {
        (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
    }

    /// The longest edge, in pixels, that the preview could draw on this screen.
    ///
    /// Handed to `PreviewImage.read` so ImageIO decodes to what will be shown
    /// and no further. That is the same defence it always was — the decode cost
    /// is bounded by the number asked for, not by what is in the file, and
    /// `PreviewImage.maxPixelSize` still caps the number itself. What changed is
    /// only that the number is now the truth: with a fixed 420-point panel a
    /// constant was the truth too, and with a panel sized by its content a
    /// constant is either wasteful or blurry.
    private static func imagePixelBudget(panelFrame: NSRect, area: NSRect,
                                         scale: CGFloat) -> Int {
        let box = self.box(panelFrame: panelFrame, area: area)
        return Int((max(box.width, box.height) * max(scale, 1)).rounded())
    }

    // MARK: - Arithmetic
    //
    // Left `internal` on purpose: this is the one part of the feature that
    // cannot be confirmed by looking at the app, so it is confirmed by tests.

    /// Everything above the panel that is not screen margin. The preview is
    /// sized into this and placed inside it.
    static func box(panelFrame: NSRect, area: NSRect) -> CGSize {
        CGSize(width: area.width - screenMargin * 2,
               height: area.maxY - screenMargin - (panelFrame.maxY + gap))
    }

    /// What the preview should be for this clipping, and where.
    ///
    /// The size follows the content. A fixed box was the mistake this replaces:
    /// at 420×340 a screenshot was barely larger than the thumbnail on the card
    /// and a small icon floated in an empty rectangle, so the preview cost a
    /// window and returned a 1.2× zoom. The jitter a fixed box was protecting
    /// against does not follow, because the size is a property of the clipping:
    /// it changes when the pointer moves to a *different* clipping, which is
    /// exactly when the content changes anyway.
    ///
    /// Above the *panel's top edge* rather than the card's: the card's top is
    /// below the search field, and a preview anchored there would cover the field
    /// the user is typing into. The panel's top edge is above every card in it,
    /// so this is still "above the card" — it just also stays out of the panel's
    /// own way.
    ///
    /// `nil` when the headroom left would be a letterbox rather than a preview.
    static func frame(for payload: PreviewPayload, cardMidX: CGFloat,
                      panelFrame: NSRect, area: NSRect) -> NSRect? {
        let box = self.box(panelFrame: panelFrame, area: area)
        guard box.height >= minimumHeadroom, box.width >= minimumSize.width else { return nil }
        return place(size: size(for: payload, in: box, screenHeight: area.height),
                     cardMidX: cardMidX, panelFrame: panelFrame, area: area)
    }

    /// Aligned to the card, and inside the screen.
    ///
    /// Two ways the naive rectangle escapes `area`, both handled: a card near
    /// the right edge pushes the preview off the side, and a card near the left
    /// edge pushes it off the other one. The clamp always has a valid range,
    /// because `size(for:in:screenHeight:)` never returns anything wider than
    /// the screen minus its two margins.
    static func place(size: CGSize, cardMidX: CGFloat,
                      panelFrame: NSRect, area: NSRect) -> NSRect {
        let width = size.width.rounded(.down)
        let height = size.height.rounded(.down)
        let x = min(max(cardMidX - width / 2, area.minX + screenMargin),
                    area.maxX - width - screenMargin)
        return NSRect(x: x.rounded(), y: (panelFrame.maxY + gap).rounded(),
                      width: width, height: height)
    }

    /// Text gets a reading column, a file gets a plate, and a picture gets its
    /// own shape at its own size.
    static func size(for payload: PreviewPayload, in box: CGSize,
                     screenHeight: CGFloat) -> CGSize {
        switch payload.item.kind {
        case .text: return fit(textSize, in: box)
        case .file: return fit(fileSize, in: box)
        case .image:
            // An unreadable blob shows a one-line apology, which wants the
            // plate, not a screen-filling rectangle.
            guard let image = payload.image else { return fit(fileSize, in: box) }
            let room = CGSize(width: box.width,
                              height: min(box.height, screenHeight * imageHeightShare))
            return fit(imageSize(image, in: room), in: box)
        }
    }

    /// The picture at its own aspect ratio, as large as the room allows and
    /// never larger than it really is: enlarging a 32-pixel icon to fill the
    /// screen shows nothing the card did not already show, only blurrier. The
    /// mat is added after the fitting so that it stays an even width on all four
    /// sides whatever shape the picture is.
    private static func imageSize(_ image: PreviewImage, in room: CGSize) -> CGSize {
        let mat = PreviewContent.imageInset * 2
        let natural = CGSize(width: CGFloat(image.pixelWidth), height: CGFloat(image.pixelHeight))
        guard natural.width > 0, natural.height > 0 else { return room }
        let scale = min((room.width - mat) / natural.width,
                        (room.height - mat) / natural.height, 1)
        return CGSize(width: natural.width * scale + mat, height: natural.height * scale + mat)
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, minimumSize.width), box.width),
               height: min(max(size.height, minimumSize.height), box.height))
    }
}
