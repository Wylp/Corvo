import AppKit
import Testing
@testable import Corvo

/// Payloads to size a preview from, without a database. The image ones need a
/// real file, because the dimensions are read from its header.
@MainActor
enum PreviewFixture {
    static var blobs: BlobStore {
        BlobStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corvo-preview-tests-\(UUID().uuidString)"))
    }

    static func item(_ kind: ClipKind, text: String? = nil, blobPath: String? = nil,
                     filePath: String? = nil) -> ClipItem {
        ClipItem(id: 1, kind: kind, text: text, label: nil, blobPath: blobPath,
                 filePath: filePath, url: nil, sourceBundleId: nil, sourceName: nil,
                 contentHash: "h", pinned: false, createdAt: Date(), lastUsedAt: nil)
    }

    static func payload(_ item: ClipItem, blobs: BlobStore = PreviewFixture.blobs,
                        budget: Int = 2_000) -> PreviewPayload {
        PreviewPayload(item: item, blobs: blobs, imagePixelBudget: budget)
    }

    static func text(_ body: String = "let x = 1") -> PreviewPayload {
        payload(item(.text, text: body))
    }

    static func file(_ path: String = "/tmp/report.pdf") -> PreviewPayload {
        payload(item(.file, text: "report.pdf", filePath: path))
    }

    /// A real PNG of the given pixel size, written into a real blob store, so
    /// that `PreviewImage.read` has a header to read.
    static func image(_ width: Int, _ height: Int, budget: Int = 2_000) throws
        -> PreviewPayload {
        let store = blobs
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: store.url(for: "fixture.png"))
        return payload(item(.image, blobPath: "fixture.png"), blobs: store, budget: budget)
    }
}

/// The preview's placement and its size, which is the one part of this feature
/// that cannot be judged by looking at a rendering: a card at the right edge of
/// the carousel must not push the preview off the screen, the menu bar must not
/// get sat on, and — since the rework — the rectangle is different for every
/// kind of clipping, so none of that can be assumed from one measurement.
/// `visibleFrame` on a 1920×1080 display with the menu bar and no Dock.
@MainActor
struct PreviewPanelTests {
    private static let area = NSRect(x: 0, y: 0, width: 1920, height: 1055)
    /// Where `PanelController.anchorToBottom` puts it: 85% of the width, centred,
    /// 24pt off the bottom of the usable area.
    private static let panel = NSRect(x: 144, y: 24, width: 1632, height: 420)

    private static func frame(_ payload: PreviewPayload, cardMidX: CGFloat,
                              area: NSRect = PreviewPanelTests.area,
                              panel: NSRect = PreviewPanelTests.panel) -> NSRect? {
        PreviewPanel.frame(for: payload, cardMidX: cardMidX, panelFrame: panel, area: area)
    }

    // MARK: - Placement

    @Test func sitsAboveThePanelAndIsCentredOnTheCard() throws {
        let frame = try #require(Self.frame(PreviewFixture.text(), cardMidX: 960))
        #expect(frame.midX == 960)
        #expect(frame.minY >= Self.panel.maxY)
        #expect(frame.width == PreviewPanel.textSize.width)
        #expect(frame.height == PreviewPanel.textSize.height)
    }

    @Test func aCardAtTheRightEdgeDoesNotPushItOffTheScreen() throws {
        // The rightmost card of a full carousel, whose centre is close enough to
        // the edge that a centred preview would hang over it.
        let frame = try #require(Self.frame(PreviewFixture.text(), cardMidX: 1750))
        #expect(frame.maxX <= Self.area.maxX)
        #expect(frame.midX < 1750)   // it had to give ground to stay on screen
    }

    @Test func aCardAtTheLeftEdgeDoesNotPushItOffEither() throws {
        let frame = try #require(Self.frame(PreviewFixture.text(), cardMidX: 170))
        #expect(frame.minX >= Self.area.minX)
        #expect(frame.midX > 170)
    }

    /// Every kind, every position along the carousel. The rectangle is no longer
    /// one size, so staying on screen has to hold for all of them rather than
    /// for the one that used to be fixed.
    @Test func itNeverReachesTheMenuBar() throws {
        let images = try [PreviewFixture.image(3_000, 1_200),
                          PreviewFixture.image(900, 2_400),
                          PreviewFixture.image(32, 32)]
        for payload in [PreviewFixture.text(), PreviewFixture.file()] + images {
            for midX in stride(from: 150.0, through: 1770.0, by: 90.0) {
                let frame = try #require(Self.frame(payload, cardMidX: midX))
                #expect(frame.maxY <= Self.area.maxY)
                #expect(frame.minX >= Self.area.minX)
                #expect(frame.maxX <= Self.area.maxX)
            }
        }
    }

    /// A second display whose origin is not zero: the panel and the card are in
    /// that screen's coordinates, and so must the preview be.
    @Test func itFollowsThePanelOntoASecondDisplay() throws {
        let right = NSRect(x: 1920, y: 0, width: 1920, height: 1080)
        let panel = NSRect(x: 2064, y: 24, width: 1632, height: 420)
        let frame = try #require(Self.frame(PreviewFixture.text(), cardMidX: 2880,
                                            area: right, panel: panel))
        #expect(right.contains(frame))
    }

    /// A short screen — the panel is 420pt tall and anchored low, so a 1050pt
    /// display leaves plenty, but a small external one may not. The preview
    /// shrinks to fit rather than growing past the top of the screen.
    @Test func aShortScreenShrinksItRatherThanOverflowing() throws {
        let short = NSRect(x: 0, y: 0, width: 1440, height: 700)
        let panel = NSRect(x: 108, y: 24, width: 1224, height: 420)
        let frame = try #require(Self.frame(PreviewFixture.text(), cardMidX: 720,
                                            area: short, panel: panel))
        #expect(frame.height < PreviewPanel.textSize.height)
        #expect(frame.maxY <= short.maxY)
    }

    /// With almost no headroom the honest answer is not to open at all: there is
    /// no room below either, because the panel is anchored to the bottom.
    @Test func withNoHeadroomItRefusesToOpen() {
        let cramped = NSRect(x: 0, y: 0, width: 1440, height: 520)
        let panel = NSRect(x: 108, y: 24, width: 1224, height: 420)
        #expect(Self.frame(PreviewFixture.text(), cardMidX: 720,
                           area: cramped, panel: panel) == nil)
    }

    /// Narrower than the preview's preferred width, where the old fixed box had
    /// no valid range to clamp into and simply overhung the screen. Now the
    /// column narrows instead, so the rectangle is genuinely inside the area.
    @Test func aScreenNarrowerThanThePreviewNarrowsItInstead() throws {
        let narrow = NSRect(x: 0, y: 0, width: 400, height: 900)
        let panel = NSRect(x: 10, y: 24, width: 380, height: 420)
        let frame = try #require(Self.frame(PreviewFixture.text(), cardMidX: 200,
                                            area: narrow, panel: panel))
        #expect(frame.width < PreviewPanel.textSize.width)
        #expect(narrow.contains(frame))
    }

    // MARK: - Size by content

    /// The complaint that started the rework: the preview was a 1.2× zoom of a
    /// 190×250 card. Every kind has to be worth the window it costs, and the
    /// picture — the one that motivated it — has to beat the other two.
    @Test func everyKindIsSubstantiallyLargerThanACard() throws {
        let card = ItemCard.width * ItemCard.height
        let screenshot = try PreviewFixture.image(2_880, 1_800)
        let text = try #require(Self.frame(PreviewFixture.text(), cardMidX: 960))
        let image = try #require(Self.frame(screenshot, cardMidX: 960))
        let file = try #require(Self.frame(PreviewFixture.file(), cardMidX: 960))

        #expect(text.width * text.height > card * 6)
        #expect(image.width * image.height > card * 8)
        #expect(image.width * image.height > text.width * text.height)
        // The least interesting kind, and deliberately not inflated to match.
        #expect(file.width * file.height < text.width * text.height)
    }

    /// A wide screenshot and a tall one produce differently shaped windows, both
    /// at the picture's own aspect ratio. This is what "sized by the content"
    /// means, and a fixed box could not do it at all.
    @Test func theWindowTakesThePicturesShape() throws {
        let mat = PreviewContent.imageInset * 2
        let wide = try #require(Self.frame(PreviewFixture.image(3_000, 1_000), cardMidX: 960))
        let tall = try #require(Self.frame(PreviewFixture.image(1_000, 3_000), cardMidX: 960))

        #expect(abs((wide.width - mat) / (wide.height - mat) - 3) < 0.05)
        #expect(abs((tall.width - mat) / (tall.height - mat) - 1.0 / 3) < 0.05)
        #expect(wide.width > wide.height)
        #expect(tall.height > tall.width)
    }

    /// A picture is allowed most of the screen's height, and no more. Measured
    /// on a tall display, where the share is what binds rather than the headroom
    /// above the panel.
    @Test func aLargePictureTakesMostOfTheHeightButNotAllOfIt() throws {
        let tall = NSRect(x: 0, y: 0, width: 2560, height: 1600)
        let panel = NSRect(x: 192, y: 24, width: 2176, height: 420)
        let frame = try #require(Self.frame(PreviewFixture.image(2_000, 4_000),
                                            cardMidX: 1_280, area: tall, panel: panel))
        #expect(frame.height <= tall.height * PreviewPanel.imageHeightShare + 1)
        #expect(frame.height > tall.height * 0.6)
    }

    /// The other half of the same rule: a small picture opens small. Blowing a
    /// 32-pixel icon up to fill the screen shows nothing the card did not show,
    /// only blurrier.
    @Test func aSmallPictureIsNotEnlargedPastItsOwnSize() throws {
        let icon = try PreviewFixture.image(32, 32)
        let frame = try #require(Self.frame(icon, cardMidX: 960))
        #expect(frame.width <= PreviewPanel.minimumSize.width)
        #expect(frame.height <= PreviewPanel.minimumSize.height)
        // But not a sliver of window furniture either.
        #expect(frame.width >= PreviewPanel.minimumSize.width)
    }

    /// Sweeping along the carousel from one card to another that is already
    /// showing only moves the window; it must not resize under the pointer.
    @Test func reanchoringKeepsTheSize() {
        let size = CGSize(width: 640, height: 480)
        let a = PreviewPanel.place(size: size, cardMidX: 400,
                                   panelFrame: Self.panel, area: Self.area)
        let b = PreviewPanel.place(size: size, cardMidX: 1_200,
                                   panelFrame: Self.panel, area: Self.area)
        #expect(a.size == b.size)
        #expect(a.minX != b.minX)
        #expect(a.minY == b.minY)
    }
}

/// The budgets: the one that stops a multi-megabyte clipping from being laid out
/// in full on the main thread, and the one that stops a decompression bomb from
/// being decoded in full to draw it.
@MainActor
struct PreviewPayloadTests {
    @Test func aShortClippingIsNotTruncatedAndIsCountedInFull() {
        let payload = PreviewFixture.text("hello")
        #expect(payload.isTruncated == false)
        #expect(payload.characterCount == 5)
        #expect(payload.text.map { String($0.characters) } == "hello")
    }

    /// The preview shows more than a card does, and stops well short of the
    /// whole thing — the count it reports is of the clipping, not of the excerpt.
    @Test func aHugeClippingIsCutToTheBudgetButCountedInFull() {
        let payload = PreviewFixture.text(String(repeating: "a", count: 500_000))
        #expect(payload.isTruncated)
        #expect(payload.characterCount == 500_000)
        #expect(payload.text?.characters.count == PreviewPayload.characterBudget)
        #expect(PreviewPayload.characterBudget > SyntaxHighlighter.characterLimit)
    }

    /// The card's budget is untouched by the preview's: raising the shared
    /// constant would have made every visible card pay on every redraw.
    @Test func theCardsBudgetIsUnchanged() {
        let long = String(repeating: "b", count: 5_000)
        #expect(SyntaxHighlighter.highlight(long, as: .plain).characters.count
                == SyntaxHighlighter.characterLimit)
    }

    @Test func aMissingFileIsReportedAsMissing() {
        #expect(PreviewFixture.file("/nowhere/gone.md").fileExists == false)
    }

    /// The true dimensions come from the header, and the thumbnail that gets
    /// drawn is decoded only to the budget — that is the whole defence against a
    /// 16,000-square blob, and it has to survive the budget becoming a variable.
    @Test func aHugePictureReportsItsRealSizeButDecodesOnlyToTheBudget() throws {
        let image = try #require(PreviewFixture.image(5_000, 2_500, budget: 800).image)
        #expect(image.pixelWidth == 5_000)
        #expect(image.pixelHeight == 2_500)
        #expect(max(image.image.size.width, image.image.size.height) <= 800)
    }

    /// However large a caller's screen, the decode is capped. A budget is
    /// derived from a display, and a display is not a trust boundary.
    @Test func theDecodeIsCappedAboveAnyBudget() throws {
        let image = try #require(PreviewFixture.image(6_000, 6_000, budget: 100_000).image)
        #expect(max(image.image.size.width, image.image.size.height)
                <= CGFloat(PreviewImage.maxPixelSize))
    }
}
