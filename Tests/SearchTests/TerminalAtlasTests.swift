import XCTest
@testable import Search

/// What the atlas holds, what it hands back before it holds it, and what it
/// lets go of when the face changes under it. The cutting itself is CoreText
/// and the blitting is Metal; what is worth pinning down here is the
/// bookkeeping around them — the number a frame is given at once, the slots
/// those numbers name, and which cuts are still the atlas's.
@MainActor
final class TerminalAtlasTests: XCTestCase {
    private let face = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let cell = CGSize(width: 8, height: 16)

    private func atlas() throws -> GlyphAtlas {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "this Mac has no Metal device")
        return try XCTUnwrap(GlyphAtlas(device: device), "no atlas")
    }

    /// The whole of the ASCII set in the four ways a style is set — 94
    /// printable characters — is cut before any frame asks for one, which is
    /// what keeps an `ls` of a directory this terminal has never listed from
    /// showing its letters blank.
    private let ascii = 94 * 4

    // MARK: - the key a glyph is asked for by

    /// A character and the way it is set are one number, and different ones
    /// are different numbers: the whole cache is this being true.
    func testTheKeySaysWhatTheGlyphIs() {
        let plain = GlyphKey.of("A", bold: false, italic: false, wide: false)
        XCTAssertEqual(plain, GlyphKey.of("A", bold: false, italic: false, wide: false), "the same glyph, the same key")
        XCTAssertNotEqual(plain, GlyphKey.of("B", bold: false, italic: false, wide: false))
        XCTAssertNotEqual(plain, GlyphKey.of("A", bold: true, italic: false, wide: false), "bold is another cut")
        XCTAssertNotEqual(plain, GlyphKey.of("A", bold: false, italic: true, wide: false))
        XCTAssertNotEqual(plain, GlyphKey.of("A", bold: false, italic: false, wide: true), "and a wide one spans another slot")
    }

    /// A character that is one scalar is its scalar, however far up the
    /// planes it is: two ideographs are not one glyph because their low
    /// bytes agree.
    func testASingleScalarIsItsOwnNumber() {
        XCTAssertNotEqual(GlyphKey.of("日", bold: false, italic: false, wide: false),
                          GlyphKey.of("本", bold: false, italic: false, wide: false))
        XCTAssertNotEqual(GlyphKey.of("\u{10000}", bold: false, italic: false, wide: false),
                          GlyphKey.of("\u{20000}", bold: false, italic: false, wide: false),
                          "above the basic plane, and still apart")
    }

    /// A cluster — a base with a combining mark, a zero-width joiner and
    /// whatever it joins — is a hash of its scalars, and the hash is marked
    /// as one: the top byte of a cluster's number is clear where a scalar's
    /// is set, so the two can never be read as each other.
    func testAClusterIsAHashAndSaysSo() {
        let cluster = GlyphKey.of("e\u{301}", bold: false, italic: false, wide: false)
        XCTAssertEqual(cluster.word >> 56, 0, "a hash says it is one")
        XCTAssertNotEqual(cluster, GlyphKey.of("e", bold: false, italic: false, wide: false))
        XCTAssertNotEqual(
            cluster, GlyphKey.of("e\u{302}", bold: false, italic: false, wide: false),
            "the marks a cluster is made of are part of it"
        )
        XCTAssertNotEqual(
            cluster, GlyphKey.of("\u{00E9}", bold: false, italic: false, wide: false),
            "and a letter that only looks like one is another glyph"
        )
        for char in ["A", "\u{00E9}", "日", "\u{10000}"] {
            let scalar = GlyphKey.of(Character(char), bold: false, italic: false, wide: false)
            XCTAssertEqual(scalar.word >> 56, 1, "\(char) is one scalar and says so")
        }
    }

    // MARK: - reserving

    /// A slot is named the moment a frame asks for it, whether or not the
    /// glyph has been cut: that is what lets a record be built and a frame
    /// encoded without waiting for CoreText. What is in the slot arrives a
    /// frame or two later (see `drain`).
    func testASlotIsNamedBeforeTheGlyphIsCut() throws {
        let atlas = try atlas()
        atlas.begin(scale: 1, cell: cell, font: face) {}

        let first = atlas.slot("日", bold: false, italic: false, wide: false)
        XCTAssertNotEqual(first, 0, "a slot is reserved and named at once")
        XCTAssertEqual(
            atlas.slot("日", bold: false, italic: false, wide: false), first,
            "and it is the slot the glyph keeps"
        )
        XCTAssertEqual(
            atlas.slot("日", bold: true, italic: false, wide: false), first &+ 1,
            "the same glyph in another style is another slot"
        )

        // The glyph is cut, and waits where the frame will pick it up.
        atlas.settle()
        let landed = atlas.drain()
        let cut = try XCTUnwrap(landed.first { $0.seat == Int(first) - 1 }, "the slot's own cut")
        XCTAssertEqual(cut.bytes.count, cut.across * cut.down, "a square of coverage")
        XCTAssertTrue(cut.bytes.contains { $0 != 0 }, "with the glyph in it")
    }

    /// The printable ASCII set in four styles is cut before any frame asks:
    /// every one of them has ink, and every one of them has a slot of its
    /// own.
    func testAsciiIsCutBeforeAFrameAsksForIt() throws {
        let atlas = try atlas()
        atlas.begin(scale: 1, cell: cell, font: face) {}

        let ready = atlas.drain()
        XCTAssertEqual(ready.count, ascii, "94 characters in four styles")
        XCTAssertEqual(Set(ready.map(\.seat)).count, ready.count, "no two glyphs share a slot")
        XCTAssertEqual(ready.map(\.seat).sorted(), Array(0..<ready.count), "and they fill the atlas from its start")
        for cut in ready {
            XCTAssertTrue(cut.bytes.contains { $0 != 0 }, "slot \(cut.seat) was cut empty")
        }
    }

    /// A wide character takes the pair of slots it spans, so the glyph that
    /// comes after it does not land on the half of it that hangs over.
    func testAWideGlyphTakesThePairOfSlotsItSpans() throws {
        let atlas = try atlas()
        atlas.begin(scale: 1, cell: cell, font: face) {}
        _ = atlas.drain()

        let wide = atlas.slot("日", bold: false, italic: false, wide: true)
        let next = atlas.slot("漢", bold: false, italic: false, wide: false)
        XCTAssertEqual(Int(next), Int(wide) + 2, "the slot beside a wide glyph is the one past both halves")
    }

    /// Each slot is one cell of the frame, rounded up to whole pixels, and
    /// the frame is told the same numbers the blit uses: the atlas and the
    /// shader have to agree about where a slot is.
    func testTheSlotIsTheCellAtTheScaleItIsDrawn() throws {
        let atlas = try atlas()
        atlas.begin(scale: 2, cell: cell, font: face) {}
        XCTAssertEqual(atlas.across, 16, "a cell eight points across, at two pixels a point")
        XCTAssertEqual(atlas.down, 32)
        XCTAssertEqual(atlas.slotsPerRow, GlyphAtlas.side / 16, "whole slots across")
    }

    // MARK: - the generation

    /// A face cut at another scale means every slot in the atlas holds
    /// something else, so the slots are handed out again from its start and
    /// the new scale's ASCII is cut rather than the old scale's re-used.
    func testACutAtAnotherScaleIsCutAgain() throws {
        let atlas = try atlas()
        atlas.begin(scale: 1, cell: cell, font: face) {}
        let before = atlas.slot("A", bold: false, italic: false, wide: false)
        _ = atlas.drain()

        atlas.begin(scale: 2, cell: cell, font: face) {}
        XCTAssertEqual(
            atlas.slot("A", bold: false, italic: false, wide: false), before,
            "the same slot, at the new scale's cut of the letter"
        )
        let ready = atlas.drain()
        XCTAssertEqual(ready.count, ascii, "the whole ASCII set is cut again at the new scale")
        XCTAssertEqual(ready.map(\.across), Array(repeating: 16, count: ascii), "and at the new width")
    }

    /// A glyph that was being cut for the atlas that has just been replaced
    /// is let go rather than blitted into its successor: the slot it was cut
    /// for belongs to another glyph now.
    func testAGlyphCutForAnAtlasThatIsGoneIsLetGo() throws {
        let atlas = try atlas()
        atlas.begin(scale: 1, cell: cell, font: face) {}
        _ = atlas.drain()
        let stale = atlas.slot("日", bold: false, italic: false, wide: false)
        XCTAssertNotEqual(stale, 0)

        atlas.begin(scale: 2, cell: cell, font: face) {}
        atlas.settle()
        let ready = atlas.drain()
        XCTAssertEqual(ready.count, ascii, "the atlas in hand holds its own cuts and no others")
        XCTAssertFalse(
            ready.contains { $0.seat == Int(stale) - 1 },
            "the glyph cut for the atlas that is gone is not blitted into this one"
        )
    }

    /// Nothing in the atlas is a glyph of the one before it, so a snapshot
    /// taken before the first cut of a frame's glyphs arrives is not the
    /// frame — which is why a test settles first. This is the arrangement
    /// the whole step is for, said as a fact about the atlas.
    func testSettlingWaitsForTheCutsThatWereOwed() throws {
        let atlas = try atlas()
        atlas.begin(scale: 1, cell: cell, font: face) {}
        _ = atlas.drain()
        for char in ["日", "本", "語", "\u{1F600}"] {
            _ = atlas.slot(Character(char), bold: false, italic: false, wide: false)
        }
        atlas.settle()
        let ready = atlas.drain()
        XCTAssertEqual(ready.count, 4, "everything asked for is cut, and waiting")
        XCTAssertTrue(ready.allSatisfy { $0.bytes.contains { $0 != 0 } }, "and each is the glyph it was cut for")
    }

    /// A frame blits a frame's worth and no more, so a page in a language
    /// the atlas has not seen — more glyphs than one frame carries — is not
    /// left half drawn: what the frame could not take asks for the next
    /// frame itself, since an idle terminal has nothing else to ask with.
    func testABurstBiggerThanOneFrameIsAskedForAgain() throws {
        let atlas = try atlas()
        var asks = 0
        atlas.onLanded = { asks += 1 }
        atlas.begin(scale: 1, cell: cell, font: face) {}

        // One glyph over a frame's worth, on top of the printable set the
        // atlas cuts before anything asks for it.
        for offset in 0..<(GlyphAtlas.perFrame - ascii + 1) {
            let scalar = UnicodeScalar(0x4E00 + UInt32(offset))!
            _ = atlas.slot(Character(scalar), bold: false, italic: false, wide: false)
        }
        atlas.settle()
        pump()
        XCTAssertEqual(asks, 1, "a burst is one ask, not one ask per glyph")

        let drawing = atlas.drain()
        XCTAssertEqual(drawing.count, GlyphAtlas.perFrame, "the frame takes what one frame blits")
        pump()
        XCTAssertEqual(asks, 2, "and what it could not take asks for another")

        let rest = atlas.drain()
        XCTAssertEqual(rest.count, 1, "which is where the glyph the frame left behind is drawn")
        pump()
        XCTAssertEqual(asks, 2, "and there is nothing left to ask for")
    }

    /// The asks are delivered on the main queue, so a test has to let them
    /// through rather than read the count the moment `settle` returns.
    private func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
