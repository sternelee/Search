import AppKit
import XCTest

@testable import Search

/// What an attachment is allowed to cost, and what it is not allowed to
/// lose.
///
/// The numbers here are the policy: a picture pasted into the chat is
/// bounded before it goes anywhere, an image already small enough is
/// handed on untouched, and a picture that has to be shrunk says so. What
/// cannot be checked here is whether the shrunk picture *looks* right —
/// that is a claim about pixels, and it needs a probe, not a test.
@MainActor
final class AgentAttachTests: XCTestCase {
    private var litter: [URL] = []

    override func tearDown() {
        for url in litter { try? FileManager.default.removeItem(at: url) }
        litter = []
        super.tearDown()
    }

    // MARK: - making pictures to attach

    private func rep(_ wide: Int, _ tall: Int, clear: Bool = false) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: tall,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: wide, height: tall)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let fill = clear
            ? NSColor.clear
            : NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        fill.setFill()
        NSRect(x: 0, y: 0, width: wide, height: tall).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func picture(_ wide: Int, _ tall: Int, clear: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: wide, height: tall))
        image.addRepresentation(rep(wide, tall, clear: clear))
        return image
    }

    // MARK: - the edge cap

    /// Down, never up: a picture smaller than the cap is already fine, and
    /// stretching it would spend bytes on pixels that were never there.
    func testFitLeavesASmallImageExactlyAlone() {
        let small = NSSize(width: 100, height: 50)
        XCTAssertEqual(Attach.fit(small), small)
        XCTAssertEqual(Attach.fit(NSSize(width: 1400, height: 10)), NSSize(width: 1400, height: 10))
    }

    /// The long edge lands on the cap and the shape is kept.
    func testFitBringsTheLongEdgeDownAndKeepsTheShape() {
        let fitted = Attach.fit(NSSize(width: 3000, height: 2000))
        XCTAssertEqual(fitted.width, 1400)
        XCTAssertEqual(fitted.height, 933)  // 2000 × 1400/3000, rounded
        XCTAssertEqual(fitted.width / fitted.height, 1.5, accuracy: 0.01)
    }

    func testFitWorksOnAPortraitImage() {
        XCTAssertEqual(Attach.fit(NSSize(width: 600, height: 2400)), NSSize(width: 350, height: 1400))
    }

    /// A zero-sized or empty image must not divide by zero on its way out.
    func testFitSurvivesAnEmptySize() {
        XCTAssertEqual(Attach.fit(.zero), .zero)
    }

    // MARK: - what a provider is charged for

    /// Base64 is a third larger than the file, and the cap is on the
    /// encoded payload — the thing that actually rides every later turn.
    func testBase64LengthMatchesWhatEncodingProduces() {
        for count in [0, 1, 2, 3, 4, 5, 6, 7, 300, 4096] {
            let data = Data(repeating: 0x41, count: count)
            XCTAssertEqual(
                Attach.base64Length(count), data.base64EncodedString().count,
                "\(count) bytes"
            )
        }
    }

    func testTheCapsAreTheDocumentedOnes() {
        XCTAssertEqual(Attach.maxEdge, 1400)
        XCTAssertEqual(Attach.maxBytes, 512 * 1024)
        XCTAssertEqual(Attach.quality, 0.75)
        XCTAssertEqual(Attach.leastQuality, 0.40)
        XCTAssertLessThan(Attach.leastQuality, Attach.quality)
    }

    // MARK: - an image already inside both bounds

    /// The bytes that came in are the bytes that go out: a JPEG keeps its
    /// own quality and its EXIF, and nothing is re-encoded for nothing.
    func testASmallOpaqueImagePassesThroughUntouched() throws {
        let source = try XCTUnwrap(rep(20, 10).representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(NSImage(data: source))
        let prepared = try XCTUnwrap(Attach.prepare(image, source: source))

        XCTAssertEqual(prepared.data, source)
        XCTAssertEqual(prepared.suffix, "png")
        XCTAssertFalse(prepared.resized)
        XCTAssertEqual(prepared.size, NSSize(width: 20, height: 10))
        XCTAssertEqual(prepared.sourceBytes, source.count)
    }

    /// Without the original bytes there is nothing to pass through, so the
    /// picture is written out afresh rather than dropped.
    func testASmallImageWithNoSourceIsStillWrittenOut() throws {
        let prepared = try XCTUnwrap(Attach.prepare(picture(20, 10)))
        XCTAssertFalse(prepared.data.isEmpty)
        XCTAssertEqual(prepared.suffix, "jpg")
        XCTAssertFalse(prepared.resized)
        XCTAssertEqual(prepared.size, NSSize(width: 20, height: 10))
    }

    // MARK: - an image that has to be shrunk

    /// Out of bounds: shrunk to the cap, turned into JPEG, and flagged as
    /// no longer the size it arrived at.
    func testABigOpaqueImageIsShrunkAndBecomesJPEG() throws {
        let prepared = try XCTUnwrap(Attach.prepare(picture(3000, 2000)))

        XCTAssertEqual(prepared.suffix, "jpg")
        XCTAssertEqual(prepared.size, NSSize(width: 1400, height: 933))
        XCTAssertTrue(prepared.resized)
        XCTAssertLessThanOrEqual(Attach.base64Length(prepared.data.count), Attach.maxBytes)
        XCTAssertEqual(Attach.suffix(of: prepared.data), "jpg")
    }

    /// Transparency survives only losslessly, so a picture with any of it
    /// stays PNG even though JPEG would be smaller.
    func testATransparentImageStaysPNG() throws {
        let prepared = try XCTUnwrap(Attach.prepare(picture(40, 40, clear: true)))
        XCTAssertEqual(prepared.suffix, "png")
        XCTAssertEqual(Attach.suffix(of: prepared.data), "png")
    }

    /// `resized` is about the bytes as well as the pixels: an image that
    /// kept its shape but had to be re-encoded smaller still gave
    /// something up, and the view says so.
    func testAResizedImageReportsItself() throws {
        let prepared = try XCTUnwrap(Attach.prepare(picture(2800, 2800)))
        XCTAssertTrue(prepared.resized)
        XCTAssertEqual(prepared.size, NSSize(width: 1400, height: 1400))
    }

    // MARK: - transparency, asked the cheap way

    func testOpaquePixelsAreNotMistakenForTransparency() {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(rep(8, 8))
        XCTAssertFalse(Attach.hasAlpha(image))
    }

    func testAClearPixelIsFound() {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(rep(8, 8, clear: true))
        XCTAssertTrue(Attach.hasAlpha(image))
    }

    // MARK: - probes: what the bytes really hold

    /// A resized attachment measured off the file it produced, not off the
    /// number it reported.
    ///
    /// This is the one claim a formula cannot make. `NSImage` will happily
    /// describe a rep at one size while holding pixels at another —
    /// `rep.size` *is* that trap — so the only proof that the picture was
    /// really shrunk is to write it, read it back, and count the pixels
    /// that came out. The colours are the second half: a resize that kept
    /// the dimensions but drew nothing (or drew the wrong region) would
    /// pass a size check and fail this.
    ///
    /// Rows run top-down in a rep read back through `tiffRepresentation`,
    /// so the picture's bottom is at the *end* of the scan — the green
    /// block drawn at AppKit's origin is looked for down there.
    func testProbeAResizedAttachmentHoldsTheShrunkPicture() throws {
        let image = NSImage(size: NSSize(width: 2800, height: 1400))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2800, pixelsHigh: 1400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: 2800, height: 1400)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 2800, height: 1400).fill()
        NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1400, height: 1400).fill()
        NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 280, height: 140).fill()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)

        let prepared = try XCTUnwrap(Attach.prepare(image))
        XCTAssertLessThanOrEqual(Attach.base64Length(prepared.data.count), Attach.maxBytes)

        let url = try XCTUnwrap(Attach.write(prepared, at: Date(timeIntervalSince1970: 1_700_000_000)))
        litter.append(url)

        // Read back off the disk, through the file the agent would open.
        let back = try XCTUnwrap(NSImage(contentsOf: url))
        let landed = try XCTUnwrap(back.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(landed.pixelsWide, 1400, "the file must hold 1400 px, not the size it was described at")
        XCTAssertEqual(landed.pixelsHigh, 700)

        func pixel(_ x: Int, _ y: Int) throws -> NSColor {
            try XCTUnwrap(landed.colorAt(x: x, y: y))
        }
        // Bottom-left: the green block, still green, still at the corner.
        let green = try pixel(60, 660)
        XCTAssertGreaterThan(green.greenComponent, 0.6)
        XCTAssertLessThan(green.redComponent, 0.5)
        // Middle-left: the red half.
        let red = try pixel(200, 350)
        XCTAssertGreaterThan(red.redComponent, 0.6)
        XCTAssertLessThan(red.blueComponent, 0.5)
        // Right: the blue half — so nothing was cropped to the left edge.
        let blue = try pixel(1300, 350)
        XCTAssertGreaterThan(blue.blueComponent, 0.6)
        XCTAssertLessThan(blue.redComponent, 0.5)
    }

    /// An image already inside the bounds is handed on byte for byte —
    /// checked on the file, because that is what the agent reads.
    func testProbeAnUnshrunkAttachmentIsByteIdenticalToItsSource() throws {
        let source = try XCTUnwrap(rep(64, 48).representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(NSImage(data: source))
        let (url, _) = try XCTUnwrap(Attach.attach(image, source: source))
        litter.append(url)
        XCTAssertEqual(try Data(contentsOf: url), source)
    }

    // MARK: - the suffix describes the bytes, not the wish

    /// The extension is what the agent's Read tool goes by, so it has to
    /// come off the file's own first bytes.
    func testSuffixIsReadOffTheMagicBytes() {
        let cases: [(String, [UInt8])] = [
            ("png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            ("jpg", [0xFF, 0xD8, 0xFF, 0xE0]),
            ("gif", [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
            ("bmp", [0x42, 0x4D, 0x00, 0x00]),
            ("tiff", [0x49, 0x49, 0x2A, 0x00]),
            ("tiff", [0x4D, 0x4D, 0x00, 0x2A]),
            ("heic", [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]),
            ("svg", Array("<?xml version".utf8)),
            ("svg", Array("<svg xmlns".utf8)),
        ]
        for (expected, bytes) in cases {
            XCTAssertEqual(Attach.suffix(of: Data(bytes)), expected, "\(expected)")
        }
    }

    func testSuffixSaysNothingAboutBytesItDoesNotKnow() {
        XCTAssertNil(Attach.suffix(of: Data()))
        XCTAssertNil(Attach.suffix(of: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(Attach.suffix(of: Data("just some words".utf8)))
    }

    /// A real PNG this app made must sniff as the PNG it is.
    func testARealPNGSniffsAsPNG() throws {
        let png = try XCTUnwrap(rep(12, 12).representation(using: .png, properties: [:]))
        XCTAssertEqual(Attach.suffix(of: png), "png")
    }

    // MARK: - the file the agent reads

    func testWriteLandsInTheAttachmentFolderUnderItsOwnSuffix() throws {
        let prepared = Attach.Prepared(
            data: Data("pretend jpeg".utf8), suffix: "jpg", size: NSSize(width: 10, height: 10),
            resized: false, sourceBytes: 12
        )
        let url = try XCTUnwrap(Attach.write(prepared, at: Date(timeIntervalSince1970: 1_700_000_000)))
        litter.append(url)

        XCTAssertEqual(url.deletingLastPathComponent(), Attach.folder)
        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("shot-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), prepared.data)
    }

    /// Two attachments in the same second are two files, not one.
    func testTwoAttachmentsInTheSameSecondDoNotCollide() throws {
        let prepared = Attach.Prepared(
            data: Data("same".utf8), suffix: "png", size: NSSize(width: 1, height: 1),
            resized: false, sourceBytes: 4
        )
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(Attach.write(prepared, at: when))
        let second = try XCTUnwrap(Attach.write(prepared, at: when))
        litter.append(contentsOf: [first, second])
        XCTAssertNotEqual(first, second)
    }

    /// The whole act, end to end: an image becomes a path in a file that
    /// exists and holds exactly the bytes that were prepared.
    func testAttachAnswersAPathThatHoldsThePreparedBytes() throws {
        let source = try XCTUnwrap(rep(24, 16).representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(NSImage(data: source))
        let (url, prepared) = try XCTUnwrap(Attach.attach(image, source: source))
        litter.append(url)

        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), prepared.data)
        XCTAssertEqual(prepared.data, source)
    }

    /// An image with nothing in it is not an attachment, and the view says
    /// so rather than writing an empty file.
    func testAnEmptyImageAttachesNothing() {
        XCTAssertNil(Attach.prepare(NSImage(size: .zero)))
        XCTAssertNil(Attach.attach(NSImage(size: .zero)))
    }

    // MARK: - where a picture comes from

    /// The pasteboard's own two shapes, on a board of our own so the
    /// person's clipboard is left as it was.
    func testAPasteboardCarryingPNGIsRead() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("attach-test-\(UUID().uuidString)"))
        board.clearContents()
        let png = try XCTUnwrap(rep(16, 16).representation(using: .png, properties: [:]))
        board.setData(png, forType: .png)

        let (image, data) = try XCTUnwrap(Attach.onPasteboard(board))
        XCTAssertEqual(data, png)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        board.releaseGlobally()
    }

    func testAnEmptyPasteboardCarriesNothing() {
        let board = NSPasteboard(name: NSPasteboard.Name("attach-empty-\(UUID().uuidString)"))
        board.clearContents()
        XCTAssertNil(Attach.onPasteboard(board))
        XCTAssertNil(Attach.dragged(board))
        board.releaseGlobally()
    }

    // MARK: - the one line said about it

    func testSayingIsTheSizeAndTheWeight() {
        let prepared = Attach.Prepared(
            data: Data(repeating: 0, count: 96 * 1024), suffix: "jpg",
            size: NSSize(width: 1204, height: 832), resized: true, sourceBytes: 4 * 1024 * 1024
        )
        XCTAssertEqual(prepared.saying, "1204×832 · 96 KB")
    }

    /// A picture under a kilobyte is not "0 KB" — it is still a picture.
    func testSayingNeverSaysZeroKB() {
        let prepared = Attach.Prepared(
            data: Data(repeating: 0, count: 10), suffix: "png",
            size: NSSize(width: 2, height: 2), resized: false, sourceBytes: 10
        )
        XCTAssertEqual(prepared.saying, "2×2 · 1 KB")
    }
}
