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

/// Whether the preview opens at all.
///
/// The rule is that hovering opens a preview only when there is something left
/// to show: a picture and a file always have more, and a text clipping has more
/// only when it did not fit on the card. Everything interesting about that lives
/// in "did it fit", which depends on the real font, the real column and where the
/// lines really break — so it is measured, and measured here rather than judged
/// by eye in a rendering.
@MainActor
struct PreviewGateTests {
    /// `ItemCard` wraps the snippet in a 24-column monospaced field: 190 points
    /// wide, less 12 of padding on each side, at `.subheadline`. Written out
    /// once so the fixtures below say what shape of text they are building.
    private static let columns = 24

    private static func lines(_ count: Int, width: Int = columns) -> String {
        (0..<count).map { _ in String(repeating: "x", count: width) }
            .joined(separator: "\n")
    }

    private static func opens(_ text: String, lines limit: Int = 10) -> Bool {
        ItemCard.previewAddsSomething(for: PreviewFixture.item(.text, text: text),
                                      lines: limit)
    }

    // MARK: - Text that already fits

    @Test func aShortLineIsAlreadyEntirelyOnTheCard() {
        #expect(Self.opens("let x = 1") == false)
    }

    /// The limit is "it fit", not "there was room left over". A snippet that
    /// fills the card's budget to the last line has nothing further to show, so
    /// the window would be a copy of what the pointer is already resting on.
    @Test func fillingTheBudgetExactlyIsStillFitting() {
        #expect(Self.opens(Self.lines(10)) == false)
    }

    @Test func oneLineMoreThanTheBudgetOpensIt() {
        #expect(Self.opens(Self.lines(11)))
    }

    /// Nothing to preview and nothing to say about it.
    @Test func nothingAndWhitespaceOpenNothing() {
        for text in ["", "   ", "\n\n\n", "  \n \t \n  "] {
            #expect(Self.opens(text) == false, "\(text.debugDescription) should stay silent")
        }
    }

    // MARK: - Why it is measured rather than counted

    /// One line in the clipping, eighteen on the card. A character count would
    /// have to call this one line and be wrong; laying it out is what notices
    /// that a 420-character run with nowhere to break wraps down the whole card
    /// and off the bottom of it.
    @Test func aSingleUnbrokenLineWrapsPastTheBudget() {
        #expect(Self.opens(String(repeating: "abcdefghij", count: 42)))
    }

    /// The boundary for a run with nowhere to break — a token, a base64 blob, a
    /// URL. SwiftUI hyphenates one, and the hyphen costs a column, so the run
    /// takes more lines than plain word wrapping would give it. Confirmed
    /// against renderings of the card: 200 characters fill the ten lines to the
    /// last one, and 210 come back with an ellipsis on line ten. Plain wrapping
    /// called both of them comfortable, and the preview would have stayed shut
    /// over text the card had cut off.
    @Test func hyphenationDecidesTheBoundaryForAnUnbrokenRun() {
        let token = { (n: Int) in String(repeating: "abcdefghij", count: n / 10) }
        #expect(Self.opens(token(200)) == false)
        #expect(Self.opens(token(210)))
    }

    /// The pair a character count gets backwards: the longer clipping fits and
    /// the shorter one does not. 200 characters with nowhere to break wrap into
    /// nine lines and stay on the card; 155 characters written one column too
    /// wide wrap into twelve and run off it.
    @Test func theShorterClippingIsTheOneThatOverflows() {
        let fits = String(repeating: "y", count: 200)
        let overflows = Self.lines(6, width: Self.columns + 1)

        #expect(overflows.count < fits.count)
        #expect(Self.opens(fits) == false)
        #expect(Self.opens(overflows))
    }

    // MARK: - The budget is not a constant

    /// A named clipping, or one waiting to be named, shows eight lines instead
    /// of ten — the name takes its line out of the snippet. A nine-line snippet
    /// is therefore complete on one card and truncated on the other, and the
    /// gate has to be told which card it is looking at.
    @Test func aNamedCardTruncatesTwoLinesEarlier() {
        #expect(Self.opens(Self.lines(9), lines: 10) == false)
        #expect(Self.opens(Self.lines(9), lines: 8))
    }

    // MARK: - The kinds that always have more

    /// No measurement is consulted for these two. The card's thumbnail is 166
    /// points wide whatever the picture is, and the file's path is cut to three
    /// lines whatever the path is.
    @Test func aPictureAndAFileAlwaysOpen() {
        let picture = PreviewFixture.item(.image, blobPath: "fixture.png")
        let file = PreviewFixture.item(.file, text: "report.pdf", filePath: "/tmp/report.pdf")
        for lines in [8, 10] {
            #expect(ItemCard.previewAddsSomething(for: picture, lines: lines))
            #expect(ItemCard.previewAddsSomething(for: file, lines: lines))
        }
    }

    /// A picture with no blob and a file that is gone still open: what the
    /// preview has to add there is the apology, which the card only has room to
    /// hint at.
    @Test func anUnreadableBlobAndAMissingFileStillOpen() {
        #expect(ItemCard.previewAddsSomething(for: PreviewFixture.item(.image), lines: 10))
        #expect(ItemCard.previewAddsSomething(
            for: PreviewFixture.item(.file, text: "gone.md", filePath: "/nowhere/gone.md"),
            lines: 10))
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
