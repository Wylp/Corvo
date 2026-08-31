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
    /// anyone reads in a preview they opened by resting a pointer, and the last
    /// line of the excerpt says plainly when it was not the whole thing.
    static let characterBudget = 8_000

    let item: ClipItem
    /// Highlighted and bounded. `nil` for a clipping that is not text.
    let text: AttributedString?
    /// Of the whole clipping, not of what is shown.
    let characterCount: Int
    let isTruncated: Bool
    let image: PreviewImage?
    let fileExists: Bool

    /// - Parameter imagePixelBudget: the longest edge, in pixels, that the
    ///   preview could possibly draw on this screen. Passed in rather than
    ///   fixed, because the panel is now sized by its content: a constant
    ///   generous enough for a full-height screenshot on a 5K display would be
    ///   a needlessly large decode everywhere else, and one small enough to be
    ///   cheap everywhere else would show that screenshot blurred.
    init(item: ClipItem, blobs: BlobStore, imagePixelBudget: Int) {
        self.item = item

        let source = item.kind == .text ? (item.text ?? "") : ""
        characterCount = source.count
        isTruncated = characterCount > Self.characterBudget
        text = item.kind == .text
            ? SyntaxHighlighter.highlight(source, as: SyntaxHighlighter.detect(source),
                                          limit: Self.characterBudget)
            : nil

        image = item.kind == .image ? item.blobPath.flatMap {
            PreviewImage.read(blobs.url(for: $0), maxPixelSize: imagePixelBudget)
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
/// asked for. The cost is bounded by the budget, not by what is in the file.
struct PreviewImage {
    /// The hard ceiling on the longest edge decoded, whatever the caller asks
    /// for. The caller's budget is derived from a screen, so it is already
    /// bounded — this is what keeps a future caller, or an absurd display, from
    /// turning "decode to what you need" back into "decode everything".
    static let maxPixelSize = 4_096

    let image: NSImage
    /// The file's real dimensions, read from the header. Not the thumbnail's.
    let pixelWidth: Int
    let pixelHeight: Int

    static func read(_ url: URL, maxPixelSize budget: Int) -> PreviewImage? {
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
            kCGImageSourceThumbnailMaxPixelSize: min(max(budget, 1), maxPixelSize),
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

/// The clipping, larger. Nothing else.
///
/// The card behind it already says where the clipping came from, when, what it
/// was named and what it was filed under, and it is still on screen. Repeating
/// any of that here would spend the only thing the preview has to offer — room —
/// on information the user is already looking at. So there is no header, no
/// title, no footer and no band of the source app's colour: a hairline, a
/// corner radius from the card's own family, the window's shadow, and then the
/// content, edge to edge.
///
/// Opaque, like the card and for a stronger version of the card's reason. This
/// one is a separate window floating over the desktop rather than over the
/// panel's blur, so a translucent surface would take its contrast from whatever
/// wallpaper happens to be underneath.
struct PreviewContent: View {
    let payload: PreviewPayload?

    /// The mat around a picture. `PreviewPanel` adds it to the window's size, so
    /// the border sits an even distance from the image on all four sides no
    /// matter what shape the image is — the whole reason the window is sized by
    /// the image rather than the image fitted into a window.
    static let imageInset: CGFloat = 6

    /// One step tighter than the card's 10, which is what a larger surface needs
    /// to read as the same radius.
    private static let radius: CGFloat = 10
    private static let padding: CGFloat = 14

    var body: some View {
        surface
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Hovering the preview holds it open, which is the only way its text
            // can be scrolled: the pointer has to leave the card to get here.
            .onHover { hovering in
                guard hovering else { return PreviewPanel.shared.endHover() }
                PreviewPanel.shared.keepAlive()
            }
            // Same reason as `ItemCard`: SwiftUI re-resolves a format style
            // against the environment's locale, so the counts need both.
            .environment(\.locale, Locale.app)
    }

    @ViewBuilder
    private var surface: some View {
        if let payload {
            content(payload)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: Self.radius))
                .clipShape(RoundedRectangle(cornerRadius: Self.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
        }
    }

    @ViewBuilder
    private func content(_ payload: PreviewPayload) -> some View {
        switch payload.item.kind {
        case .text: textContent(payload)
        case .image: imageContent(payload)
        case .file: fileContent(payload)
        }
    }

    /// The excerpt, and — only when there was more than the excerpt — one line
    /// saying so. That line is the last thing in the scroll, not a footer band:
    /// it is a property of the text, it appears where the text runs out, and a
    /// clipping that fits says nothing at all.
    private func textContent(_ payload: PreviewPayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(payload.text ?? AttributedString())
                    .font(.system(.subheadline, design: .monospaced))
                if payload.isTruncated {
                    Text("Showing the first \(PreviewPayload.characterBudget) of \(payload.characterCount) characters")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(Self.padding)
        }
    }

    /// The window is already the picture's shape, so the picture only has to
    /// fill it. Capped at its own pixel dimensions in both places — here and in
    /// the window's size — because `scaledToFit` would happily enlarge a
    /// 32-pixel icon to fill the screen, and a blurred icon says less than the
    /// card's thumbnail did.
    @ViewBuilder
    private func imageContent(_ payload: PreviewPayload) -> some View {
        if let image = payload.image {
            Image(nsImage: image.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: CGFloat(image.pixelWidth),
                       maxHeight: CGFloat(image.pixelHeight))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Self.imageInset)
                .accessibilityLabel("Image, \(image.pixelWidth) by \(image.pixelHeight) pixels")
        }
        if payload.image == nil {
            Label("Image unavailable", systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The path in full, which is the answer to the question the card's
    /// truncated name raises — *which* of the four files with that name is this.
    /// There is nothing else true to say about a file, so nothing else is said.
    private func fileContent(_ payload: PreviewPayload) -> some View {
        let path = payload.item.filePath
        return HStack(alignment: .top, spacing: 12) {
            fileIcon(path: path, exists: payload.fileExists)
            VStack(alignment: .leading, spacing: 4) {
                Text(payload.item.text ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(path ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(payload.fileExists ? 1 : 0.6)
    }

    /// The file's real icon when there is a file to ask about, and the card's
    /// `doc.questionmark` when there is not — a generic document icon would say
    /// less than the glyph that means "missing". The glyph carries the words as
    /// its label, so the state survives with colour off and with the screen off.
    @ViewBuilder
    private func fileIcon(path: String?, exists: Bool) -> some View {
        if exists, let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
        }
        if !exists {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)
                .accessibilityLabel("This file no longer exists")
        }
    }
}
