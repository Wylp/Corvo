import AppKit
import SwiftUI

/// One clipping in the carousel: a header naming where it came from and when,
/// over a content region showing what it is.
///
/// The surface is deliberately opaque while the panel behind it is blurred: a
/// translucent card sits on whatever wallpaper happens to be there, and its text
/// contrast becomes unpredictable. Solid card, blurred panel, contrast holds in
/// both themes.
struct ItemCard: View {
    let item: ClipItem
    let tags: [Tag]
    let isSelected: Bool
    /// In the ⇧-extended run but not under the cursor. Takes the accent border
    /// so the run reads as one block, and none of the lift: exactly one card is
    /// the cursor, and raising the whole run would lose which one.
    var isMarked: Bool = false
    /// The key that pastes this card, or `nil` for the ones past the ninth. See
    /// `HistoryModel.number(forIndex:)`.
    var number: Int? = nil
    let blobs: BlobStore
    /// The pointer is on this card, with the card's horizontal centre in screen
    /// coordinates. Fires on every movement across the card, not only on entry,
    /// so that the anchor keeps up while the carousel scrolls underneath.
    let onHover: (CGFloat) -> Void
    /// The pointer left. Not the same as "close the preview" — the caller
    /// decides that, because the gutter between two cards is also a departure.
    let onHoverEnd: () -> Void

    static let width: CGFloat = 190
    static let height: CGFloat = 250

    /// The longest edge ImageIO is asked to decode for the card's thumbnail.
    ///
    /// The preview area is 166 points wide, so this is that at 2×, rounded up —
    /// enough for a Retina panel and nothing beyond it. `NSImage(contentsOf:)`
    /// was decoding the file at full resolution to draw into this space: a
    /// screenshot off a 5K display is ~60 MB of bitmap for 166 points of card,
    /// paid on the main thread as the card scrolls into view.
    ///
    /// `PreviewImage.read` was written for the hover preview and its own comment
    /// names the card as the other place with this problem; this is that place.
    /// The size comes out of the header and only the thumbnail is decoded, so
    /// the cost is bounded by this number rather than by what is in the file.
    ///
    /// ponytail: read per card build, not cached. #6 made the row lazy, so that
    /// is the few cards on screen rather than all 200. Cache by blob path if a
    /// trace ever shows the decode itself.
    static let thumbnailPixels = 360

    private static let radius: CGFloat = 10

    /// Around the content region, and therefore what the snippet's line breaks
    /// are decided by: `width` minus twice this is the column the text wraps in.
    ///
    /// A constant rather than a literal on the `.padding` below because
    /// `previewAddsSomething(for:lines:)` measures the snippet in that same
    /// column to decide whether the preview opens at all. Change the padding and
    /// the measurement follows; write the number twice and one day it will not.
    private static let contentPadding: CGFloat = 12

    /// The snippet's font as AppKit sees it. `.system(.subheadline, design:
    /// .monospaced)` on the `Text` below resolves to exactly this, and the two
    /// have to stay in step for the same reason `contentPadding` is shared —
    /// the gate lays the text out in this font to find out whether the card
    /// already showed all of it.
    private static var textFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular)
    }

    private var fileIsMissing: Bool {
        guard item.kind == .file, let path = item.filePath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// `nil` for an app with a monochrome icon, and for a clipping with no known
    /// source. Both take the neutral header.
    private var accent: Color? { DominantColor.of(bundleId: item.sourceBundleId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Self.radius))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(isSelected || isMarked
                              ? Color.accentColor : Color.primary.opacity(0.09),
                              lineWidth: isSelected || isMarked ? 2 : 1)
        }
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0.10),
                radius: isSelected ? 12 : 3, y: isSelected ? 5 : 1)
        // The selected card is lifted out of the row. Arrow-key browsing needs a
        // selection you can read without looking for it.
        .offset(y: isSelected ? -6 : 0)
        .opacity(fileIsMissing ? 0.5 : 1)
        // Not belt and braces with `Locale.app` on the format style: SwiftUI
        // re-resolves a format style against the environment's locale, which
        // silently wins over the one the style was given. Setting both is what
        // makes the date come out in English on a Portuguese machine.
        .environment(\.locale, Locale.app)
        .accessibilityElement(children: .combine)
        // `onContinuousHover` rather than `onHover`, for the coordinates: the
        // preview has to be anchored to this card, and the phase carries the
        // pointer's position *inside* the card. Subtracting it from the
        // pointer's position on screen gives the card's own left edge, and the
        // width gives its centre — live as the carousel scrolls, with no
        // geometry reader, no stored frame and no window lookup.
        //
        // Silent when the preview would have nothing to add — see
        // `previewAddsSomething(for:lines:)`. The gate is here rather than in
        // `PreviewPanel` so that such a card starts no dwell and cancels no
        // timer: the panel never hears about the hover, and "nothing happens"
        // is nothing happening rather than something undone. A preview already
        // open on a neighbouring card still closes, because that card's own
        // `.ended` phase fired on the way out.
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { return onHoverEnd() }
            guard Self.previewAddsSomething(for: item, lines: textLineLimit) else { return }
            onHover(NSEvent.mouseLocation.x - point.x + Self.width / 2)
        }
    }

    /// The source app's colour arrives as a wash behind the header, never as a
    /// fill under the text. It is extracted from a third party's icon and could
    /// be pale yellow or near black, so nothing legible is allowed to depend on
    /// it: at this strength the label keeps its own contrast against the card in
    /// either theme. Full strength goes to the rule at the bottom edge, which
    /// carries no text and therefore no contrast requirement.
    private var header: some View {
        HStack(spacing: 6) {
            // First, and carrying the ⌘ rather than the bare digit: a lone "3"
            // in the corner of a card is a number, not an instruction, and the
            // rail at the foot of the panel is already ten hints long without
            // an eleventh explaining what the numbers are. Written on the card,
            // the hint is where the thing it applies to is.
            if let number {
                Text(verbatim: "⌘\(number)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 3)
                    .frame(minHeight: 15)
                    .background(Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.12))
                    }
                    .accessibilityLabel("Paste with command \(number)")
            }
            if let icon = AppIcon.image(forBundleId: item.sourceBundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)  // the name next to it already says this
            }
            Text(item.sourceName ?? String(localized: "Unknown"))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Pinned")
            }
            // Tabular digits: the carousel redraws on every keystroke, and the
            // ages tick while it is open.
            Text(item.createdAt,
                 format: .relative(presentation: .numeric).locale(Locale.app))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent?.opacity(0.16) ?? Color.primary.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(accent ?? Color.primary.opacity(0.12))
                .frame(height: 2)
        }
    }

    private var label: String? {
        guard let label = item.label, !label.isEmpty else { return nil }
        return label
    }

    /// A rule claimed this clipping for a tag that asks to name what it catches,
    /// and no name has been given. Derived from what the card already holds —
    /// no column, no extra query, and no state to keep in sync: it is true
    /// whether the notification was never authorized, never seen, or dismissed,
    /// and it stops being true the moment a name is saved.
    private var awaitsName: Bool {
        label == nil && tags.contains(where: \.promptsForName)
    }

    /// How many lines of the snippet this card shows.
    ///
    /// The name takes its line out of the preview, not out of the tag row: the
    /// card is a fixed 250pt and something has to give. Losing the tenth line of
    /// a snippet costs less than losing the tags, which are the whole reason the
    /// card was named.
    ///
    /// The invitation to name it costs the same line as the name itself, on
    /// purpose: answering the prompt must not shuffle the card it is printed on.
    private var textLineLimit: Int { label == nil && !awaitsName ? 10 : 8 }

    /// Whether the hover preview would show anything this card does not already
    /// show. When it would not, hovering does nothing at all — no dwell, no
    /// window, no hint. A preview that repeats what is already on screen is
    /// noise, and the card is right there behind it.
    ///
    /// Static and free of SwiftUI so that the one genuinely uncertain part of
    /// this — where the lines actually break — is decided by measurement in a
    /// test rather than by eye in a screenshot.
    ///
    /// - Parameter lines: the card's snippet budget, which is not a constant.
    ///   See `textLineLimit`.
    static func previewAddsSomething(for item: ClipItem, lines: Int) -> Bool {
        // A thumbnail 166 points wide and a path cut to three lines are never
        // the whole story — those two always have more to give. Text is the one
        // kind that can already be complete on the card.
        guard item.kind == .text else { return true }
        // The same prefix the card draws: `SyntaxHighlighter.highlight` cuts
        // there, so measuring past it would be measuring text the card never
        // laid out. It also bounds the cost, which matters because this runs on
        // every pointer movement across a card.
        //
        // ponytail: laid out on every such movement, not cached. Measured at
        // 25µs for a typical short clipping, 45µs for one that fills the card,
        // and 580µs at the ceiling — 1,200 characters with no break opportunity
        // in them, a base64 blob or a minified line, where hyphenation has to
        // try every position. That worst case is still a fraction of a frame,
        // and mouse-moved events arrive at the refresh rate. Upgrade path: the
        // answer is a function of the text and the line budget alone, so it
        // caches by item id if this ever shows up in a trace.
        let text = String((item.text ?? "").prefix(SyntaxHighlighter.characterLimit))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Half a point of slack, well under a line: it keeps a snippet that
        // fills its budget exactly from being called an overflow.
        return laidOutHeight(text) > laidOutHeight("M") * CGFloat(lines) + 0.5
    }

    /// The height `text` occupies in the card's snippet font across the card's
    /// usable column. `.usesLineFragmentOrigin` is the option that makes this a
    /// wrapped multi-line layout rather than one long line measured end to end —
    /// without it a hundred-character line reports the width of a hundred
    /// characters and the height of one.
    ///
    /// A single "M" is the unit the result is read in, rather than
    /// `NSLayoutManager.defaultLineHeight(for:)`, which disagrees with what this
    /// call actually produces (13 against 14 at `.subheadline`). Measuring the
    /// unit the same way it measures the text is what makes the ratio a line
    /// count instead of an approximation of one.
    ///
    /// Hyphenation is on because SwiftUI's is: a run with nowhere to break — a
    /// token, a base64 blob, a URL — gets a hyphen at each break, and the hyphen
    /// costs a column, so the same run takes more lines than plain word wrapping
    /// says. Measured against renderings of the card, an unbroken 210-character
    /// run truncates on screen while plain wrapping called it nine lines and
    /// comfortable. That is the false negative that matters — the preview
    /// staying shut over text the card cut off.
    private static func laidOutHeight(_ text: String) -> CGFloat {
        let wrapping = NSMutableParagraphStyle()
        wrapping.usesDefaultHyphenation = true
        return NSAttributedString(string: text,
                                  attributes: [.font: textFont, .paragraphStyle: wrapping])
            .boundingRect(with: CGSize(width: width - contentPadding * 2,
                                       height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin])
            .height
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Never both — `awaitsName` requires the absence of a label — so
            // these are two conditions rather than a branch.
            if let label { nameLine(label) }
            if awaitsName { namePrompt }
            preview
            if !tags.isEmpty { tagRow }
        }
        .padding(Self.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The name the user gave this clipping, in the content region rather than
    /// the header: the header answers "where did this come from", and a name is
    /// not provenance — it is what the thing *is*, so it belongs on top of the
    /// thing.
    ///
    /// Set in the proportional system face, deliberately, against the
    /// monospaced preview directly below it. Everything else on the card is
    /// machine text; this is the one line a human wrote, and the change of
    /// typeface says so before a word of it is read. That is the whole
    /// treatment — no colour, no capsule, no icon. The header wash and the
    /// syntax highlighting already spend the card's colour budget, and a third
    /// loud region on 190 points would cost more than it bought.
    private func nameLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The name slot before there is a name, in the exact place the name will
    /// go: the card does not reflow when the answer arrives, it just stops
    /// asking.
    ///
    /// Deliberately quiet — secondary weight, no colour, no badge. Nothing is
    /// wrong here. The clipping is saved and tagged; this is an invitation, and
    /// a warning colour would say the opposite. Glyph and words carry it
    /// together, so it survives with colour turned off, and the shortcut is
    /// written into the line because a hint the user has to already know is not
    /// a hint.
    private var namePrompt: some View {
        Label("Name this (⌘R)", systemImage: "pencil.line")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            // Monospaced on purpose: most of what gets copied is code, paths, IDs
            // and tokens, and the shape of a snippet is half of recognising it.
            // The colouring finishes that thought — a curl, a JSON body and a
            // paragraph are told apart before any of them is read.
            Text(SyntaxHighlighter.highlight(item.text ?? "",
                                             as: SyntaxHighlighter.detect(item.text ?? "")))
                // `Self.textFont` is this same face, and has to stay that way.
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(textLineLimit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            if let path = item.blobPath,
               let img = PreviewImage.read(blobs.url(for: path),
                                           maxPixelSize: Self.thumbnailPixels)?.image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Label("Image unavailable", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: fileIsMissing ? "doc.questionmark" : "doc.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(item.text ?? "")
                    .font(.callout)
                    .lineLimit(3)
                if fileIsMissing {
                    // Dimming alone would carry this in opacity only, which is the
                    // same mistake as carrying it in colour only.
                    Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var tagRow: some View {
        HStack(spacing: 4) {
            ForEach(tags) { tag in
                Text(tag.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
