import AppKit
import GRDB
import SwiftUI
import Testing
@testable import Corvo

/// What a card costs is per card built, so what matters is how many get built.
/// The row is lazy for that reason, and this is the measurement that says so —
/// asserted rather than described, because "it only builds what is visible" is
/// exactly the kind of claim that stays in a comment long after a refactor has
/// stopped making it true.
///
/// Tag queries were the probe because they were countable from outside: every
/// built card asked for its own, so counting the queries counted the cards.
///
/// They no longer are. The list's tags are read once in `reload` now and the
/// cards look them up in a map, so an arrow press asks nothing — which is the
/// point of that change, and it leaves this measuring the absence rather than
/// the count. Kept as the regression guard for the per-card query coming back:
/// if anything under here starts asking the database per card again, this is
/// what fails. The laziness of the row itself is guarded by the highlighting
/// and image work that still ride on a card being built, which nothing here
/// can count from outside.
@Test @MainActor func theCarouselOnlyAsksAboutTheCardsItIsShowing() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-carousel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let blobs = BlobStore(directory: dir)
    let repo = ItemRepository(dbQueue: try AppDatabase.make(at: nil), blobs: blobs)

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let safari = ItemSource(bundleId: "com.apple.Safari", name: "Safari")
    // The limit `reload` fetches, so the list is as long as the panel ever
    // makes it and the eager and lazy answers are as far apart as they get.
    let clippings = 200
    for i in 0..<clippings {
        _ = try repo.insert(CapturedItem(kind: .text, text: "clipping number \(i)",
                                         imageData: nil, filePath: nil, url: nil,
                                         contentHash: "hash-\(i)"),
                            source: safari, now: start.addingTimeInterval(Double(i)))
    }

    let model = HistoryModel(repo: repo,
                             prefs: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    model.reload()
    #expect(model.items.count == clippings)

    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                         styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: HistoryView(
        model: model, blobs: blobs, onPaste: { _ in }, onCopy: { _ in }))
    defer { window.orderOut(nil) }
    window.makeKeyAndOrderFront(nil)
    settleCarousel()

    // Traced after the first layout, so what is counted is the cost of moving
    // the cursor and not the cost of opening the panel.
    let queries = QueryCounter()
    try repo.dbQueue.writeWithoutTransaction { db in
        db.trace(options: .statement) { event in
            if "\(event)".contains("FROM tag") { queries.count += 1 }
        }
    }

    model.arrow(1, extending: false)
    settleCarousel()

    // Deliberately loose: how many cards fit is a function of the window, and
    // SwiftUI is free to keep a few more around than it draws. The number this
    // is guarding against is one per clipping in the history, which is what an
    // eager row costs and what it costs again on the next key.
    #expect(queries.count < clippings / 4,
            "one arrow press asked the database \(queries.count) times over \(clippings) clippings")
}

/// `db.trace` hands its events to a closure the compiler cannot see the
/// isolation of, so the count lives behind a reference rather than in a `var`
/// captured across that boundary.
private final class QueryCounter: @unchecked Sendable {
    var count = 0
}

@MainActor
private func settleCarousel() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
}


/// The card decodes to the size it draws, not to the size of the file.
///
/// `NSImage(contentsOf:)` decoded at full resolution: a screenshot off a large
/// display cost tens of megabytes of bitmap to fill 166 points of card, on the
/// main thread, as the card scrolled into view. The measurement is the decoded
/// image's own dimensions, which is the thing that was wrong — asserting on time
/// would be asserting on the machine.
@Test @MainActor func theCardDecodesAThumbnailRatherThanTheWholeImage() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corvo-thumb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 4000×3000 is an ordinary screenshot off a large display.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4_000, pixelsHigh: 3_000,
                              bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let url = dir.appendingPathComponent("big.png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)

    let thumbnail = try #require(PreviewImage.read(url, maxPixelSize: ItemCard.thumbnailPixels))

    // The header still reports the real size, so nothing is lying about what
    // the file holds.
    #expect(thumbnail.pixelWidth == 4_000)
    #expect(thumbnail.pixelHeight == 3_000)

    // What was decoded is bounded by the card, not by the file.
    let longestEdge = max(thumbnail.image.size.width, thumbnail.image.size.height)
    #expect(longestEdge <= CGFloat(ItemCard.thumbnailPixels))
    #expect(longestEdge > 0)
}
