import XCTest
@testable import Search

/// The pointer turned into bytes: the two encodings a program can ask for,
/// the buttons, the modifiers, and the edge the old encoding has and SGR
/// does not.
///
/// Nothing here has a view, a window or a shell behind it. What a click
/// does — who gets it, and when the selection gets it instead — is the
/// view's, and is written where the view is; this is the arithmetic, which
/// is the part a program on the other end of a pty will read literally.
final class TerminalMouseTests: XCTestCase {
    /// The old encoding is a character, then three bytes with 32 in them:
    /// the code, the column from one, and the row from one.
    func testTheOldEncodingIsThreeBytesWithThirtyTwoInThem() {
        let said = MouseReport.bytes(button: 0, column: 0, row: 0, format: .legacy)
        XCTAssertEqual(said, [0x1b, 0x5b, 0x4d, 32, 33, 33], "a press of the left button at the top left")
        let far = MouseReport.bytes(button: 0, column: 79, row: 23, format: .legacy)
        XCTAssertEqual(far, [0x1b, 0x5b, 0x4d, 32, 32 + 80, 32 + 24], "and one eighty columns in")
    }

    /// The release is a code of its own: three, meaning "the button that
    /// was down came up", which is all the old encoding can say.
    func testTheOldEncodingSaysOnlyThatAButtonCameUp() {
        let said = MouseReport.bytes(button: 0, column: 4, row: 2, release: true, format: .legacy)
        XCTAssertEqual(said[3], 32 + 3)
        let right = MouseReport.bytes(button: 2, column: 4, row: 2, release: true, format: .legacy)
        XCTAssertEqual(right[3], 32 + 3, "and it cannot say which button it was")
    }

    /// SGR writes the numbers in decimal and ends in `m` for a release, so
    /// the button it was is never lost.
    func testSGRWritesTheNumbersAndKeepsTheButtonThroughARelease() {
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 0, row: 0, format: .sgr), as: UTF8.self),
            "\u{1b}[<0;1;1M"
        )
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 2, column: 11, row: 4, release: true, format: .sgr), as: UTF8.self),
            "\u{1b}[<2;12;5m", "the right button, still saying which one it was as it comes up"
        )
    }

    /// Past column 223 the old encoding's byte runs out. It clamps rather
    /// than carrying into the field next door — a click reported at the
    /// edge is wrong, and one reported at the wrong place entirely is
    /// worse.
    func testTheOldEncodingClampsWhereItsBytesRunOut() {
        let said = MouseReport.bytes(button: 0, column: 300, row: 400, format: .legacy)
        XCTAssertEqual(said[4], 255)
        XCTAssertEqual(said[5], 255)
        XCTAssertEqual(said.count, 6, "still three fields, and the click still lands on the screen")
    }

    /// SGR has no such edge: the numbers are decimal and as long as they
    /// need to be.
    func testSGRHasNoEdgeToClampAt() {
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 300, row: 400, format: .sgr), as: UTF8.self),
            "\u{1b}[<0;301;401M"
        )
    }

    /// A move with no button held is the protocol's button 3 — and with a
    /// button held, the button it was, flagged as motion.
    func testMotionIsFlaggedAndSaysWhichButtonIsHeld() {
        let free = MouseReport.bytes(button: MouseReport.noButton, column: 1, row: 1, dragging: true, format: .sgr)
        XCTAssertEqual(String(decoding: free, as: UTF8.self), "\u{1b}[<35;2;2M", "3 + 32: moved, nothing held")
        let held = MouseReport.bytes(button: 0, column: 1, row: 1, dragging: true, format: .sgr)
        XCTAssertEqual(String(decoding: held, as: UTF8.self), "\u{1b}[<32;2;2M", "0 + 32: moved with the left button down")
    }

    /// The modifiers are bits in the code: four, eight and sixteen, added
    /// to whichever button it is, in both encodings.
    func testTheModifiersAreBitsInTheCode() {
        XCTAssertEqual(MouseReport.held(), 0)
        XCTAssertEqual(MouseReport.held(shift: true), 4)
        XCTAssertEqual(MouseReport.held(shift: true, option: true, control: true), 28)
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 0, row: 0, held: 4, format: .sgr), as: UTF8.self),
            "\u{1b}[<4;1;1M", "shift-click is the left button with four in it"
        )
        XCTAssertEqual(MouseReport.bytes(button: 0, column: 0, row: 0, held: 4, format: .legacy)[3], 32 + 4)
        XCTAssertEqual(MouseReport.bytes(button: 0, column: 0, row: 0, held: 4, release: true, format: .legacy)[3], 32 + 7,
                       "and a released shift-click is three plus the shift")
    }

    /// AppKit and the protocol number the buttons differently past the
    /// first: AppKit's 1 is the right button and its 2 the middle one, and
    /// the protocol has them the other way round.
    func testTheButtonsAreRenumbered() {
        XCTAssertEqual(MouseReport.number(for: 0), 0, "left is left")
        XCTAssertEqual(MouseReport.number(for: 1), 2, "AppKit's right is the protocol's 2")
        XCTAssertEqual(MouseReport.number(for: 2), 1, "and AppKit's middle is the protocol's 1")
        XCTAssertEqual(MouseReport.number(for: 3), 3, "and the ones past them are left alone")
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: MouseReport.number(for: 1), column: 0, row: 0, format: .sgr), as: UTF8.self),
            "\u{1b}[<2;1;1M"
        )
    }

    /// The wheel is buttons 4 and 5, up and down, and always a press: a
    /// wheel does not come back up.
    func testTheWheelIsButtonsFourAndFive() {
        XCTAssertEqual(
            String(decoding: MouseReport.wheel(up: true, column: 0, row: 0, format: .sgr), as: UTF8.self),
            "\u{1b}[<64;1;1M"
        )
        XCTAssertEqual(
            String(decoding: MouseReport.wheel(up: false, column: 0, row: 0, format: .sgr), as: UTF8.self),
            "\u{1b}[<65;1;1M"
        )
        XCTAssertEqual(MouseReport.wheel(up: true, column: 0, row: 0, format: .legacy)[3], 32 + 64)
    }

    // MARK: - urxvt's encoding, and pixels

    /// 1015 is SGR's decimal numbers without the `<`, ending in `M`
    /// always — so it fixes the byte fields and the wrong-place click that
    /// comes of them, and nothing else.
    func testUrxvtWritesTheNumbersWithoutTheAngleBracket() {
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 0, row: 0, format: .urxvt), as: UTF8.self),
            "\u{1b}[0;1;1M"
        )
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 300, row: 400, format: .urxvt), as: UTF8.self),
            "\u{1b}[0;301;401M", "no byte runs out here: the numbers are written whole"
        )
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 4, row: 2, release: true, format: .urxvt), as: UTF8.self),
            "\u{1b}[3;5;3M", "and a release is the old code, so the button it was is lost as before"
        )
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 1, row: 1, dragging: true, format: .urxvt), as: UTF8.self),
            "\u{1b}[32;2;2M"
        )
    }

    /// 1016 is SGR's encoding and SGR's bytes for a release; what it
    /// changes is what the numbers count, which is the caller's to have
    /// counted — the encoding writes what it is handed.
    func testSGRPixelsIsSGRWithThePixelItWasHanded() {
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 0, column: 0, row: 0, format: .sgrPixels), as: UTF8.self),
            "\u{1b}[<0;1;1M"
        )
        XCTAssertEqual(
            String(decoding: MouseReport.bytes(button: 2, column: 400, row: 300, release: true, format: .sgrPixels), as: UTF8.self),
            "\u{1b}[<2;401;301m", "a release still says which button it was, as SGR's does"
        )
    }

    /// And the modes say which of them counts pixels, since that is the
    /// one thing the caller has to do differently.
    func testOnlyThePixelModeCountsPixels() {
        XCTAssertTrue(MouseReport.Format.sgrPixels.pixels, "1016 is the one that reports pixels")
        XCTAssertFalse(MouseReport.Format.legacy.pixels)
        XCTAssertFalse(MouseReport.Format.sgr.pixels)
        XCTAssertFalse(MouseReport.Format.urxvt.pixels, "1015's coordinates are cells: it fixes the fields, not the unit")
    }

    /// The pointer, placed: a cell for the ordinary modes, and — for 1016 —
    /// the pixel of the frame it is over, which is finer than a cell and is
    /// the whole of what the mode is for. The room the frame leaves around
    /// the grid is before the first of either.
    @MainActor
    func testThePointerIsPlacedInTheUnitThatWasAskedFor() {
        let cell = CGSize(width: 8, height: 16)
        let inset = CGFloat(TerminalDraw.inset)
        // Two and a half cells across, one and a quarter down, at a scale
        // of two — so twenty pixels in, four pixels down within the cell.
        let point = NSPoint(x: inset + 2.5 * cell.width, y: inset + 1.25 * cell.height)

        let squares = MouseReport.place(of: point, inset: inset, cell: cell, scale: 2, pixels: false)
        XCTAssertEqual(squares.column, 2, "the cell the pointer is over")
        XCTAssertEqual(squares.row, 1)

        let pixels = MouseReport.place(of: point, inset: inset, cell: cell, scale: 2, pixels: true)
        XCTAssertEqual(pixels.column, 40, "and the pixel of the frame: two and a half cells of eight, at two a point")
        XCTAssertEqual(pixels.row, 40, "one and a quarter cells of sixteen")

        let before = MouseReport.place(
            of: NSPoint(x: inset - 3, y: inset - 3), inset: inset, cell: cell, scale: 2, pixels: true
        )
        XCTAssertEqual(before.column, 0, "the room around the grid is the first pixel, not the one before it")
        XCTAssertEqual(before.row, 0)
    }
}
