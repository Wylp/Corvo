import AppKit
import ImageIO
import SwiftUI

/// Everything the preview shows, resolved once when the preview opens rather
/// than in `body`.
///
/// This is where the work happens — reading a blob off disk, decoding a picture,
/// tokenising a snippet — and it happens exactly once per hover, after the dwell
/// has already elapsed. Doing any of it in `body` would repeat it on every
/// redraw, which is the mistake `AppIcon`'s cache exists to avoid on the card.
struct PreviewPayload {
    /// The preview's own ceiling on how much text it will colour and lay out,
    /// against `SyntaxHighlighter.characterLimit`'s 1,200 for a card.
    ///
    /// A clipping can be megabytes; rendering one whole would freeze the app for
    /// exactly as long as it took to lay out. At `.subheadline` monospaced this
    /// budget is roughly seven screenfuls of scrolling, which is more than
    /// anyone reads in a preview they opened by resting a pointer, and the
    /// footer says plainly when it was not the whole thing.
    static let characterBudget = 8_000

    let item: ClipItem
    let tags: [Tag]
    /// Highlighted and bounded. `nil` for a clipping that is not text.
    let text: AttributedString?
    /// Of the whole clipping, not of what is shown.
    let characterCount: Int
    let isTruncated: Bool
    let image: PreviewImage?
    let fileExists: Bool

    init(item: ClipItem, tags: [Tag], blobs: BlobStore) {
        self.item = item
        self.tags = tags

        let source = item.kind == .text ? (item.text ?? "") : ""
        characterCount = source.count
        isTruncated = characterCount > Self.characterBudget
        text = item.kind == .text
            ? SyntaxHighlighter.highlight(source, as: SyntaxHighlighter.detect(source),
                                          limit: Self.characterBudget)
            : nil

        image = item.kind == .image ? item.blobPath.flatMap {
            PreviewImage.read(blobs.url(for: $0))
        } : nil

        fileExists = item.kind == .file
            && item.filePath.map { FileManager.default.fileExists(atPath: $0) } == true
    }
}

/// A picture's true size, and a copy of it small enough to draw.
///
/// `NSImage(contentsOf:)` — which is what the card uses — decodes the file at
/// full resolution, and the security review already measured a 16,000×16,000
/// TIFF freezing the app for 1.4 seconds. The capture side now refuses anything
/// above 40 MPx, but blobs written before that guard existed are still on disk,
/// and the preview reads them.
///
/// `CGImageSource` avoids the problem rather than mitigating it: the properties
/// come from the file's header without decoding a single pixel, and
/// `kCGImageSourceThumbnailMaxPixelSize` makes ImageIO decode *only* to the size
/// asked for. The cost is bounded by `maxPixelSize`, not by what is in the file.
struct PreviewImage {
    /// The longest edge decoded, in pixels. Covers the preview's 420pt width on
    /// a 2× display with headroom, and nothing larger is ever drawn.
    static let maxPixelSize = 1_200

    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int

    static func read(_ url: URL) -> PreviewImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honours the EXIF orientation, so a photo shot sideways is not
            // previewed sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                  options as CFDictionary)
        else { return nil }
        return PreviewImage(
            image: NSImage(cgImage: thumbnail,
                           size: NSSize(width: thumbnail.width, height: thumbnail.height)),
            pixelWidth: width, pixelHeight: height)
    }
}

/// The clipping at reading size.
///
/// Deliberately the card's own vocabulary, scaled up rather than restyled: the
/// same header band carrying the same wash of the source app's colour over the
/// same 2pt rule, the same monospaced and syntax-coloured content, the same tag
/// capsules, the same opaque surface. The claim it makes is "this is the card,
/// closer", so there is no second visual language to learn — and the one thing
/// it adds is the thing the card had no room for: the measurements, in the
/// footer.
///
/// Opaque, like the card and for a stronger version of the card's reason. This
/// one is a separate window floating over the desktop rather than over the
/// panel's blur, so a translucent surface would take its contrast from whatever
/// wallpaper happens to be underneath.
struct PreviewContent: View {
    let payload: PreviewPayload?

    private static let radius: CGFloat = 12

    var body: some View {
        surface
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Hovering the preview holds it open, which is the only way its text
            // can be scrolled: the pointer has to leave the card to get here.
            .onHover { hovering in
                guard hovering else { return PreviewPanel.shared.endHover() }
                PreviewPanel.shared.keepAlive()
            }
            // Same reason as `ItemCard`: SwiftUI re-resolves a format style
            // against the environment's locale, so the date needs both.
            .environment(\.locale, Locale.app)
    }

    @ViewBuilder
    private var surface: some View {
        if let payload {
            VStack(alignment: .leading, spacing: 0) {
                header(payload)
                titleRow(payload)
                content(payload)
                footer(payload)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: Self.radius))
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.radius)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
        }
    }

    /// The card's header at the preview's scale, down to the 16% wash and the
    /// 2pt rule. Nothing here is new; recognising the preview as the same object
    /// as the card it came from is the point.
    private func header(_ payload: PreviewPayload) -> some View {
        let accent = DominantColor.of(bundleId: payload.item.sourceBundleId)
        return HStack(spacing: 8) {
            if let icon = AppIcon.image(forBundleId: payload.item.sourceBundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)  // the name next to it already says this
            }
            Text(payload.item.sourceName ?? String(localized: "Unknown"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            if payload.item.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Pinned")
            }
            Text(payload.item.createdAt,
                 format: .relative(presentation: .numeric).locale(Locale.app))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent?.opacity(0.16) ?? Color.primary.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(accent ?? Color.primary.opacity(0.12))
                .frame(height: 2)
        }
    }

    /// Name and tags share one line here, where the card has to stack them. The
    /// extra 230 points of width is exactly what buys that, and it keeps the row
    /// reading as one statement: what this is, and what it was filed under.
    @ViewBuilder
    private func titleRow(_ payload: PreviewPayload) -> some View {
        let name = payload.item.label.flatMap { $0.isEmpty ? nil : $0 }
        if name != nil || !payload.tags.isEmpty {
            HStack(spacing: 8) {
                if let name {
                    // The proportional face against the monospaced content
                    // below, for the reason the card gives: this is the one line
                    // a human wrote.
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    // Only when there is a name to push away from. Without one,
                    // a lone capsule pinned to the right edge reads as a stray
                    // badge rather than as a label on the thing below it.
                    Spacer(minLength: 4)
                }
                ForEach(payload.tags) { tag in
                    Text(tag.name)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func content(_ payload: PreviewPayload) -> some View {
        switch payload.item.kind {
        case .text:
            ScrollView {
                Text(payload.text ?? AttributedString())
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image:
            imageContent(payload)
        case .file:
            fileContent(payload)
        }
    }

    @ViewBuilder
    private func imageContent(_ payload: PreviewPayload) -> some View {
        if let image = payload.image {
            Image(nsImage: image.image)
                .resizable()
                // Never distorted: the whole picture, at its own aspect ratio,
                // as large as the box allows.
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(14)
        }
        if payload.image == nil {
            Label("Image unavailable", systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The card shows a truncated name and dims the whole thing when the file is
    /// gone. Here there is room for the path in full, which is the answer to the
    /// question a truncated name raises — *which* one of the four files with
    /// that name is this.
    private func fileContent(_ payload: PreviewPayload) -> some View {
        let path = payload.item.filePath
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                fileIcon(path: path, exists: payload.fileExists)
                Text(payload.item.text ?? "")
                    .font(.headline)
                    .lineLimit(2)
            }
            ScrollView {
                Text(path ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(payload.fileExists ? 1 : 0.6)
    }

    /// The file's real icon when there is a file to ask about, and the card's
    /// `doc.questionmark` when there is not — a generic document icon would say
    /// less than the glyph that means "missing".
    @ViewBuilder
    private func fileIcon(path: String?, exists: Bool) -> some View {
        if exists, let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
        }
        if !exists {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
        }
    }

    /// The measurements — the facts the card has no room to state.
    ///
    /// A card can only show you the clipping; at this size the preview can also
    /// tell you how big it is, which is the whole reason the feature exists.
    /// Absent entirely when there is nothing true to say, rather than padded out
    /// with a line that says everything is fine.
    @ViewBuilder
    private func footer(_ payload: PreviewPayload) -> some View {
        if Self.hasFooter(payload) {
            Divider()
            footerLine(payload)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A text clipping always has a length worth stating. A picture has its
    /// dimensions only if it could be read at all, and a file that is still
    /// where it was left has nothing to report — silence is the correct answer
    /// there, not a line saying everything is fine.
    private static func hasFooter(_ payload: PreviewPayload) -> Bool {
        switch payload.item.kind {
        case .text: return true
        case .image: return payload.image != nil
        case .file: return !payload.fileExists
        }
    }

    @ViewBuilder
    private func footerLine(_ payload: PreviewPayload) -> some View {
        switch payload.item.kind {
        case .text where payload.isTruncated:
            Text("Showing the first \(PreviewPayload.characterBudget) of \(payload.characterCount) characters")
        case .text:
            Text("\(payload.characterCount) characters")
        case .image:
            // The one fact a thumbnail cannot carry, and the reason a screenshot
            // is worth previewing at all.
            if let image = payload.image {
                Text("\(image.pixelWidth) × \(image.pixelHeight) pixels")
            }
        case .file:
            // Glyph, colour and words together, so it survives with colour off.
            Label("This file no longer exists", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
