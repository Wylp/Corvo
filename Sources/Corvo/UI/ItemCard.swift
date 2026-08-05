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
    let blobs: BlobStore

    static let width: CGFloat = 190
    static let height: CGFloat = 250

    private static let radius: CGFloat = 10

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
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.09),
                              lineWidth: isSelected ? 2 : 1)
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
    }

    /// The source app's colour arrives as a wash behind the header, never as a
    /// fill under the text. It is extracted from a third party's icon and could
    /// be pale yellow or near black, so nothing legible is allowed to depend on
    /// it: at this strength the label keeps its own contrast against the card in
    /// either theme. Full strength goes to the rule at the bottom edge, which
    /// carries no text and therefore no contrast requirement.
    private var header: some View {
        HStack(spacing: 6) {
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Never both — `awaitsName` requires the absence of a label — so
            // these are two conditions rather than a branch.
            if let label { nameLine(label) }
            if awaitsName { namePrompt }
            preview
            if !tags.isEmpty { tagRow }
        }
        .padding(12)
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
                .font(.system(.subheadline, design: .monospaced))
                // The name takes its line out of the preview, not out of the
                // tag row: the card is a fixed 250pt and something has to give.
                // Losing the tenth line of a snippet costs less than losing the
                // tags, which are the whole reason the card was named.
                //
                // The invitation to name it costs the same line as the name
                // itself, on purpose: answering the prompt must not shuffle the
                // card it is printed on.
                .lineLimit(label == nil && !awaitsName ? 10 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            if let path = item.blobPath,
               let img = NSImage(contentsOf: blobs.url(for: path)) {
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
