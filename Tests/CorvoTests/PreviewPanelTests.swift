import AppKit
import Testing
@testable import Corvo

/// The preview's placement, which is the one part of this feature that cannot be
/// judged by looking at a rendering: a card at the right edge of the carousel
/// must not push the preview off the screen, and the menu bar must not get sat
/// on. `visibleFrame` on a 1920×1080 display with the menu bar and no Dock.
@MainActor
struct PreviewPanelTests {
    private static let area = NSRect(x: 0, y: 0, width: 1920, height: 1055)
    /// Where `PanelController.anchorToBottom` puts it: 85% of the width, centred,
    /// 24pt off the bottom of the usable area.
    private static let panel = NSRect(x: 144, y: 24, width: 1632, height: 420)

    private static func frame(cardMidX: CGFloat,
                              area: NSRect = PreviewPanelTests.area,
                              panel: NSRect = PreviewPanelTests.panel) -> NSRect? {
        PreviewPanel.frame(cardMidX: cardMidX, panelFrame: panel, area: area)
    }

    @Test func sitsAboveThePanelAndIsCentredOnTheCard() throws {
        let frame = try #require(Self.frame(cardMidX: 960))
        #expect(frame.midX == 960)
        #expect(frame.minY >= Self.panel.maxY)
        #expect(frame.width == PreviewPanel.size.width)
        #expect(frame.height == PreviewPanel.size.height)
    }

    @Test func aCardAtTheRightEdgeDoesNotPushItOffTheScreen() throws {
        // The rightmost card of a full carousel, whose centre is close enough to
        // the edge that a centred preview would hang over it.
        let frame = try #require(Self.frame(cardMidX: 1750))
        #expect(frame.maxX <= Self.area.maxX)
        #expect(frame.midX < 1750)   // it had to give ground to stay on screen
    }

    @Test func aCardAtTheLeftEdgeDoesNotPushItOffEither() throws {
        let frame = try #require(Self.frame(cardMidX: 170))
        #expect(frame.minX >= Self.area.minX)
        #expect(frame.midX > 170)
    }

    @Test func itNeverReachesTheMenuBar() throws {
        for midX in stride(from: 150.0, through: 1770.0, by: 90.0) {
            let frame = try #require(Self.frame(cardMidX: midX))
            #expect(frame.maxY <= Self.area.maxY)
            #expect(frame.minX >= Self.area.minX)
            #expect(frame.maxX <= Self.area.maxX)
        }
    }

    /// A second display whose origin is not zero: the panel and the card are in
    /// that screen's coordinates, and so must the preview be.
    @Test func itFollowsThePanelOntoASecondDisplay() throws {
        let right = NSRect(x: 1920, y: 0, width: 1920, height: 1080)
        let panel = NSRect(x: 2064, y: 24, width: 1632, height: 420)
        let frame = try #require(Self.frame(cardMidX: 2880, area: right, panel: panel))
        #expect(right.contains(frame))
    }

    /// A short screen — the panel is 420pt tall and anchored low, so a 1050pt
    /// display leaves plenty, but a small external one may not. The preview
    /// shrinks to fit rather than growing past the top of the screen.
    @Test func aShortScreenShrinksItRatherThanOverflowing() throws {
        let short = NSRect(x: 0, y: 0, width: 1440, height: 700)
        let panel = NSRect(x: 108, y: 24, width: 1224, height: 420)
        let frame = try #require(Self.frame(cardMidX: 720, area: short, panel: panel))
        #expect(frame.height < PreviewPanel.size.height)
        #expect(frame.maxY <= short.maxY)
    }

    /// With almost no headroom the honest answer is not to open at all: there is
    /// no room below either, because the panel is anchored to the bottom.
    @Test func withNoHeadroomItRefusesToOpen() {
        let cramped = NSRect(x: 0, y: 0, width: 1440, height: 520)
        let panel = NSRect(x: 108, y: 24, width: 1224, height: 420)
        #expect(Self.frame(cardMidX: 720, area: cramped, panel: panel) == nil)
    }

    /// Narrower than the preview plus its margins, where clamping has no valid
    /// range. It must still produce a rectangle rather than an inverted one.
    @Test func aScreenNarrowerThanThePreviewStillPlacesIt() throws {
        let narrow = NSRect(x: 0, y: 0, width: 400, height: 900)
        let panel = NSRect(x: 10, y: 24, width: 380, height: 420)
        let frame = try #require(Self.frame(cardMidX: 200, area: narrow, panel: panel))
        #expect(frame.width > 0)
        #expect(frame.height > 0)
        #expect(frame.minX >= narrow.minX)
    }
}

/// The text budget, which is what stops a multi-megabyte clipping from being
/// laid out in full on the main thread.
@MainActor
struct PreviewPayloadTests {
    private static func textItem(_ text: String) -> ClipItem {
        ClipItem(id: 1, kind: .text, text: text, label: nil, blobPath: nil, filePath: nil,
                 url: nil, sourceBundleId: nil, sourceName: nil, contentHash: "h",
                 pinned: false, createdAt: Date(), lastUsedAt: nil)
    }

    private static var blobs: BlobStore {
        BlobStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corvo-preview-tests-\(UUID().uuidString)"))
    }

    @Test func aShortClippingIsNotTruncatedAndIsCountedInFull() {
        let payload = PreviewPayload(item: Self.textItem("hello"), tags: [], blobs: Self.blobs)
        #expect(payload.isTruncated == false)
        #expect(payload.characterCount == 5)
        #expect(payload.text.map { String($0.characters) } == "hello")
    }

    /// The preview shows more than a card does, and stops well short of the
    /// whole thing — the count it reports is of the clipping, not of the excerpt.
    @Test func aHugeClippingIsCutToTheBudgetButCountedInFull() {
        let huge = String(repeating: "a", count: 500_000)
        let payload = PreviewPayload(item: Self.textItem(huge), tags: [], blobs: Self.blobs)
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
        let item = ClipItem(id: 1, kind: .file, text: "gone.md", label: nil, blobPath: nil,
                            filePath: "/nowhere/gone.md", url: nil, sourceBundleId: nil,
                            sourceName: nil, contentHash: "h", pinned: false,
                            createdAt: Date(), lastUsedAt: nil)
        #expect(PreviewPayload(item: item, tags: [], blobs: Self.blobs).fileExists == false)
    }
}
