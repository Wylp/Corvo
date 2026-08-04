import AppKit
import SwiftUI

/// One clipping in the carousel.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            preview
            if !tags.isEmpty { tagRow }
        }
        .padding(12)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Self.radius))
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
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = AppIcon.image(forBundleId: item.sourceBundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)  // the name next to it already says this
            }
            Text(item.sourceName ?? String(localized: "Unknown"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Pinned")
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            // Monospaced on purpose: most of what gets copied is code, paths, IDs
            // and tokens, and the shape of a snippet is half of recognising it.
            Text(item.text ?? "")
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(10)
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
