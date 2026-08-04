import AppKit
import SwiftUI

/// The characteristic colour of a source app's icon, used to tint a card's
/// header so the carousel can be sorted by origin before a word is read.
///
/// The *average* of an icon is not that colour. Averaging every pixel of a
/// colourful icon lands on a brownish grey, which is where Slack, Figma and
/// Photoshop would all end up. This takes the largest family of hues instead and
/// averages only that.
@MainActor
enum DominantColor {
    /// Misses are stored too: a monochrome icon never yields a colour, and
    /// without a stored `nil` every visible card would rasterise its icon again
    /// on every redraw.
    ///
    /// ponytail: never expires, the same ceiling and upgrade path as
    /// `AppIcon.cache` — a re-themed app keeps its old colour until relaunch.
    private static var cache: [String: Color?] = [:]

    static func of(bundleId: String?) -> Color? {
        guard let bundleId else { return nil }
        if let cached = cache[bundleId] { return cached }
        let color = AppIcon.image(forBundleId: bundleId).flatMap(characteristicColor)
        // `cache[bundleId] = color` would *remove* the key when `color` is nil —
        // assigning nil into a dictionary of optionals is a delete, not a store,
        // and the negative caching above would silently never happen.
        cache.updateValue(color, forKey: bundleId)
        return color
    }

    /// 16×16 is plenty — we want the icon's colour family, not its drawing.
    private static let side = 16

    /// Hue is bucketed rather than averaged as a whole: the mean of red and green
    /// is yellow, a colour that appears nowhere in the icon.
    private static let hueBuckets = 12

    private static func characteristicColor(_ icon: NSImage) -> Color? {
        guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = bitmap.bitmapData else { return nil }

        var counts = [Int](repeating: 0, count: hueBuckets)
        var hues = [CGFloat](repeating: 0, count: hueBuckets)
        var saturations = [CGFloat](repeating: 0, count: hueBuckets)
        var brightnesses = [CGFloat](repeating: 0, count: hueBuckets)
        var visiblePixels = 0

        for offset in stride(from: 0, to: side * side * 4, by: 4) {
            let alpha = CGFloat(pixels[offset + 3]) / 255
            // Nearly transparent pixels carry no colour worth counting.
            guard alpha >= 0.5 else { continue }
            visiblePixels += 1
            // The bitmap is premultiplied, so every partly transparent pixel
            // reads darker than the colour actually painted there. Undoing that
            // is not a detail: an icon of thin shapes on a clear background —
            // Slack, Figma — is nearly all soft edge once it is 16pt wide, and
            // without this the whole icon reads as a dark grey and is discarded.
            let pixel = NSColor(deviceRed: min(CGFloat(pixels[offset]) / 255 / alpha, 1),
                                green: min(CGFloat(pixels[offset + 1]) / 255 / alpha, 1),
                                blue: min(CGFloat(pixels[offset + 2]) / 255 / alpha, 1),
                                alpha: 1)
            // Grey, white and the black of an outline carry no identity.
            guard pixel.saturationComponent >= 0.25, pixel.brightnessComponent >= 0.2
            else { continue }
            let bucket = min(Int(pixel.hueComponent * CGFloat(hueBuckets)), hueBuckets - 1)
            counts[bucket] += 1
            hues[bucket] += pixel.hueComponent
            saturations[bucket] += pixel.saturationComponent
            brightnesses[bucket] += pixel.brightnessComponent
        }

        // The test is how much of the icon carries colour at all, not how big the
        // winning hue is on its own. Slack is four brand colours in equal
        // measure: no single one of them reaches a tenth of the icon, and
        // judging the winner against the whole icon threw away every icon that
        // was colourful in more than one way.
        let colouredPixels = counts.reduce(0, +)
        guard visiblePixels > 0,
              // A handful of coloured pixels in an otherwise grey icon is a
              // detail, not an identity. Under a tenth, the card takes the
              // neutral treatment instead.
              colouredPixels * 10 >= visiblePixels,
              // ponytail: buckets do not wrap, so a red brand splits between the
              // first and last of them and can lose to a smaller secondary hue.
              // Upgrade path: merge the two end buckets before picking.
              let winner = counts.indices.max(by: { counts[$0] < counts[$1] })
        else { return nil }

        let total = CGFloat(counts[winner])
        return Color(hue: hues[winner] / total,
                     // Clamped rather than reported as measured. The hue is the
                     // identity; saturation and brightness are legibility — the
                     // colour also has to show as a 2pt rule on a white card and
                     // on a near-black one, and a pale yellow or a near-black
                     // icon fails one of those two at its measured value.
                     saturation: min(max(saturations[winner] / total, 0.45), 0.95),
                     brightness: min(max(brightnesses[winner] / total, 0.5), 0.85))
    }
}
