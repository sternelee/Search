import XCTest
@testable import Search

/// What a frame really painted, read back from the GPU. The layer's own
/// drawables cannot be read after they are presented, so the renderer draws
/// the same frame into a texture of its own and the test reads that —
/// the only honest way to know a glyph landed where a cell said one should.
@MainActor
final class TerminalRenderTests: XCTestCase {
    /// A scene of plain words, drawn at a scale of two, paints words: pixels
    /// well off the ground, enough of them to be letters and not specks.
    func testWordsPaintFarOffTheGround() throws {
        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)

        var line = Row(width: 10)
        for (column, letter) in "Metal!".enumerated() {
            line.cells[column] = Cell(char: letter, wide: false, ink: Ink())
        }
        let scene = Terminal.Scene(
            lines: [line, Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let frame = try pixels(of: paint)

        // The theme, as the frame was painted with it.
        let theme = TerminalDraw.Theme.current()
        var words = 0
        for offset in stride(from: 0, to: frame.count, by: 4) {
            let red = Double(frame[offset]) / 255
            let green = Double(frame[offset + 1]) / 255
            let blue = Double(frame[offset + 2]) / 255
            let gap = abs(red - Double(theme.ground.x))
                + abs(green - Double(theme.ground.y))
                + abs(blue - Double(theme.ground.z))
            if gap > 0.3 { words += 1 }
        }
        XCTAssertGreaterThan(words, 300, "a word of six letters at scale two paints more than specks; painted \(words)")
    }

    /// A caret, strong, paints its block: a cell's worth of the ink.
    func testStrongCaretPaintsItsBlock() throws {
        let previous = TerminalLook.cursor
        defer { TerminalLook.cursor = previous }
        TerminalLook.cursor = .block

        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)

        let scene = Terminal.Scene(
            lines: [Row(width: 10), Row(width: 10)], marks: [], caret: (0, 0),
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let (pixels, across: width) = try frame(of: paint)

        let theme = TerminalDraw.Theme.current()
        // The cursor's cell: the inset over, the first cell square. Any pixel
        // within a letter of the ink is the block.
        let inset = Int(TerminalDraw.inset * 2)
        var block = 0
        for y in inset..<(inset + Int(paint.cell.height * 2) - 2) {
            for x in inset..<(inset + Int(paint.cell.width * 2) - 2) {
                let o = (y * width + x) * 4
                let gap = abs(Double(pixels[o]) / 255 - Double(theme.ink.x))
                    + abs(Double(pixels[o + 1]) / 255 - Double(theme.ink.y))
                    + abs(Double(pixels[o + 2]) / 255 - Double(theme.ink.z))
                if gap < 0.2 { block += 1 }
            }
        }
        XCTAssertGreaterThan(block, 40, "a strong caret paints a solid block of ink; painted \(block)")
    }

    /// A bar caret paints a bar, not a block: the ink of the cursor's cell
    /// stays at its left edge, and the rest of the cell is left as it was.
    func testBarCaretPaintsOnlyItsBar() throws {
        let previous = TerminalLook.cursor
        defer { TerminalLook.cursor = previous }
        TerminalLook.cursor = .bar

        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)

        let scene = Terminal.Scene(
            lines: [Row(width: 10), Row(width: 10)], marks: [], caret: (0, 0),
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let (pixels, across: width) = try frame(of: paint)

        let theme = TerminalDraw.Theme.current()
        let inset = Int(TerminalDraw.inset * 2)
        var painted = 0, reached = 0
        for y in inset..<(inset + Int(paint.cell.height * 2) - 2) {
            for x in inset..<(inset + Int(paint.cell.width * 2) - 2) {
                let o = (y * width + x) * 4
                let gap = abs(Double(pixels[o]) / 255 - Double(theme.ink.x))
                    + abs(Double(pixels[o + 1]) / 255 - Double(theme.ink.y))
                    + abs(Double(pixels[o + 2]) / 255 - Double(theme.ink.z))
                guard gap < 0.2 else { continue }
                painted += 1
                reached = max(reached, x - inset)
            }
        }
        XCTAssertGreaterThan(painted, 10, "a bar caret paints a bar of ink; painted \(painted)")
        // Two points wide at a scale of two, with a pixel of slack for the
        // rounding of a cell that is not a whole number of points across.
        XCTAssertLessThanOrEqual(reached, 5, "the bar is at the cell's left edge, not across it; reached \(reached) pixels in")
    }

    // MARK: The caret a program gave a colour to (OSC 12)

    /// A block caret takes the colour the program named — the one thing a
    /// program can say about a caret it otherwise has no say in.
    func testAProgramsCaretColourIsWhatTheBlockPaints() throws {
        let previous = TerminalLook.cursor
        defer { TerminalLook.cursor = previous }
        TerminalLook.cursor = .block

        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)

        var scene = Terminal.Scene(
            lines: [Row(width: 10), Row(width: 10)], marks: [], caret: (0, 0),
            width: 10, height: 2, back: 0
        )
        scene.cursorInk = .rgb(255, 0, 0)
        let cell = try caretCell(paint, scene: scene, strong: true)

        let red = cell.filter { $0.red > 200 && $0.green < 60 && $0.blue < 60 }.count
        XCTAssertGreaterThan(red, 40, "the block is the program's colour, not the theme's ink; painted \(red) red pixels of it")
    }

    /// A bar takes it too, and half of it in a window that has lost the
    /// keyboard — the same half-mix the shader makes of a block, so the
    /// two shapes agree.
    func testABarCaretTakesTheColourTheProgramGaveIt() throws {
        let previous = TerminalLook.cursor
        defer { TerminalLook.cursor = previous }
        TerminalLook.cursor = .bar

        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)

        var scene = Terminal.Scene(
            lines: [Row(width: 10), Row(width: 10)], marks: [], caret: (0, 0),
            width: 10, height: 2, back: 0
        )
        scene.cursorInk = .rgb(255, 128, 0)

        // The colour, to a hair: a quad with no antialiasing paints one
        // colour whole, and the byte it was packed into and back out of
        // loses nothing.
        func close(_ cell: [(red: Int, green: Int, blue: Int)], _ want: (Double, Double, Double)) -> Int {
            cell.filter {
                abs(Double($0.red) / 255 - want.0) < 0.02
                    && abs(Double($0.green) / 255 - want.1) < 0.02
                    && abs(Double($0.blue) / 255 - want.2) < 0.02
            }.count
        }

        let strong = try caretCell(paint, scene: scene, strong: true)
        XCTAssertGreaterThan(close(strong, (1, 128.0 / 255, 0)), 10, "the bar is the colour the program named")

        let theme = TerminalDraw.Theme.current()
        let faint = try caretCell(paint, scene: scene, strong: false)
        let want = ((theme.ground.x + 1) / 2, (theme.ground.y + 128.0 / 255) / 2, theme.ground.z / 2)
        XCTAssertGreaterThan(
            close(faint, (Double(want.0), Double(want.1), Double(want.2))), 10,
            "and half of it when the window has lost the keyboard"
        )
    }

    /// The caret's cell, corner to corner, in red-green-blue order: the
    /// layer is bgra8Unorm, so a pixel's red is its third byte.
    private func caretCell(
        _ paint: TerminalDraw, scene: Terminal.Scene, strong: Bool
    ) throws -> [(red: Int, green: Int, blue: Int)] {
        paint.refresh(scene: scene, selection: nil, strong: strong)
        let (pixels, across: width) = try frame(of: paint)

        let inset = Int(TerminalDraw.inset * 2)
        var cell: [(red: Int, green: Int, blue: Int)] = []
        for y in inset..<(inset + Int(paint.cell.height * 2) - 2) {
            for x in inset..<(inset + Int(paint.cell.width * 2) - 2) {
                let o = (y * width + x) * 4
                cell.append((Int(pixels[o + 2]), Int(pixels[o + 1]), Int(pixels[o])))
            }
        }
        return cell
    }

    // MARK: - the cells a frame keeps

    /// A renderer of the size the tests above use, for the frames below.
    private func renderer() throws -> TerminalDraw {
        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
        return paint
    }

    /// A row of letters, as a scene hands one over.
    private func line(_ text: String) -> Row {
        var row = Row(width: 10)
        for (column, letter) in text.prefix(10).enumerated() {
            row.cells[column] = Cell(char: letter, wide: false, ink: Ink())
        }
        return row
    }

    /// The frame the renderer last drew into a texture of its own: every
    /// pixel of it, and how many there are across a row, which is what a
    /// test indexes it by. `landed` is passed on to `snapshot`: false is the
    /// frame drawn without waiting for the glyphs it asked for.
    private func frame(
        of paint: TerminalDraw, landed: Bool = true
    ) throws -> (pixels: [UInt8], across: Int) {
        let texture = try XCTUnwrap(paint.snapshot(landed: landed), "the frame did not draw")
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (bytes, width)
    }

    /// The same, for a test that reads the pixels in one run and never needs
    /// to know how wide a row is.
    private func pixels(of paint: TerminalDraw, landed: Bool = true) throws -> [UInt8] {
        try frame(of: paint, landed: landed).pixels
    }

    /// How many of a frame's pixels are not the ground, which for a frame
    /// that has nothing to draw is none of them.
    private func specks(_ frame: [UInt8]) -> Int {
        let theme = TerminalDraw.Theme.current()
        var count = 0
        for offset in stride(from: 0, to: frame.count, by: 4) {
            let gap = abs(Double(frame[offset]) / 255 - Double(theme.ground.x))
                + abs(Double(frame[offset + 1]) / 255 - Double(theme.ground.y))
                + abs(Double(frame[offset + 2]) / 255 - Double(theme.ground.z))
            if gap > 0.3 { count += 1 }
        }
        return count
    }

    /// How many bytes of one frame are not the other's, as a number for a
    /// failure message rather than three hundred thousand of them.
    private func apart(_ one: [UInt8], _ other: [UInt8]) -> Int {
        guard one.count == other.count else { return max(one.count, other.count) }
        return zip(one, other).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    // MARK: - the glyphs the atlas had to cut

    // MARK: - the shape of a quad

    /// Every quad the renderer draws — a background, a caret, a glyph — is a
    /// rectangle, and a rectangle has no wedge cut out of it. A triangle
    /// strip takes its corners two at a time, though, so a corner order that
    /// walks round the quad's edge instead of zigzagging leaves the strip's
    /// second triangle sharing an edge with the first: the two of them then
    /// overlap down one side of the cell and leave a wedge of the other side
    /// bare, widest at the middle rows. That wedge took a slice out of every
    /// glyph, so this is the test for the order of the corners: a cell
    /// filled with a full block is filled from the same left edge on every
    /// row it is filled at all.
    func testACellFilledWithABlockHasNoWedgeCutOutOfIt() throws {
        let paint = try renderer()
        let scene = Terminal.Scene(
            lines: [line("█"), Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.update(scene: scene, damage: Damage(), selection: nil, strong: true)
        let (frame, width) = try frame(of: paint)

        let theme = TerminalDraw.Theme.current()
        let inset = Int(TerminalDraw.inset * 2)
        let across = Int(paint.cell.width * 2), down = Int(paint.cell.height * 2)

        // Each row of the cell: how many of its pixels are ink, and where
        // the ink that row has starts.
        var starts: [Int] = [], filled: [Int] = []
        for row in 0..<down {
            let inked = (0..<across).filter { column in
                let offset = ((inset + row) * width + inset + column) * 4
                let red = Double(frame[offset + 2]) / 255
                let cover = (Double(theme.ground.x) - red) / (Double(theme.ground.x) - Double(theme.ink.x))
                return cover > 0.5
            }
            filled.append(inked.count)
            if let first = inked.first { starts.append(first) }
        }

        // The block is most of the cell: a full block is the one glyph that
        // is a rectangle, so it is the one that can be measured as one.
        let rows = filled.filter { $0 > 4 }.count
        XCTAssertGreaterThan(rows, 20, "a full block fills row after row of its cell; filled \(rows) of \(down)")
        XCTAssertGreaterThanOrEqual(
            filled.max() ?? 0, across - 3,
            "and it fills them across: the widest row is \(filled.max() ?? 0) of \(across) pixels"
        )
        XCTAssertEqual(
            Set(starts).count, 1,
            "the rows of a filled cell start at one edge, not at the widest part of a wedge; they start at \(Set(starts).sorted())"
        )
    }

    /// Letters the atlas was not born with — anything but ASCII — are cut
    /// while the frame that asks for them is being made, and are in their
    /// slot by the frame after it. The blit is what puts them there: the
    /// atlas is a private texture the CPU never writes, so a glyph that is
    /// in it at all got there through the frame's own command buffer.
    ///
    /// The upper bound is what makes this a test of that and not just of
    /// "something was painted": an atlas nobody had written to paints most
    /// of every cell that names a slot — three quarters of it, measured on
    /// this Mac (4320 of 5760 pixels, where the glyph is 1688) — so a
    /// letter that fills less than half its cell is a letter.
    func testALetterTheAtlasHadToCutPaints() throws {
        let paint = try renderer()
        let scene = Terminal.Scene(
            lines: [line("日本語日本語日本語日本語日本語"), Row(width: 10)],
            marks: [], caret: nil, width: 10, height: 2, back: 0
        )
        paint.update(scene: scene, damage: Damage(), selection: nil, strong: true)
        let drawn = try pixels(of: paint)

        let words = specks(drawn)
        let cells = 10 * Int(paint.cell.width * 2) * Int(paint.cell.height * 2)
        XCTAssertGreaterThan(words, 300, "ten ideographs paint more than specks; painted \(words)")
        XCTAssertLessThan(words, cells / 2, "and they are letters, not blocks; painted \(words) of \(cells)")

        // And the frame is the frame it is: the same scene said whole, by
        // the same renderer, is the same pixels — the cut landed and stayed.
        paint.refresh(scene: scene, selection: nil, strong: true)
        XCTAssertEqual(apart(drawn, try pixels(of: paint)), 0, "a glyph that has landed is a glyph like any other")
    }

    /// The frame a terminal draws while the cutting queue is behind it: a
    /// square whose glyph is still being cut shows nothing at all. Not the
    /// glyph, which is not cut yet — and not the noise of a private texture
    /// nobody has written to, which is what that square holds unless the
    /// atlas is emptied when it is made, and what it would then draw.
    ///
    /// A frame like this is real: it is the one between an ask and its
    /// answer. A snapshot settles before it encodes, so a test has to ask
    /// for the unsettled one; the frame after it is the frame the test above
    /// is about, and the second half here says so — this is a frame that is
    /// a frame behind, not a renderer that has lost the glyphs.
    func testASquareWhoseGlyphIsStillBeingCutDrawsNothing() throws {
        let paint = try renderer()
        let scene = Terminal.Scene(
            lines: [line("日本語日本語日本語日本語日本語"), Row(width: 10)],
            marks: [], caret: nil, width: 10, height: 2, back: 0
        )
        paint.update(scene: scene, damage: Damage(), selection: nil, strong: true)

        let early = specks(try pixels(of: paint, landed: false))
        XCTAssertEqual(early, 0, "a glyph that has not been cut yet is drawn as nothing, not as whatever a fresh private texture held; painted \(early) pixels")

        let words = specks(try pixels(of: paint))
        XCTAssertGreaterThan(words, 300, "and the frame after it has them; painted \(words)")
    }

    /// A row the program rewrote where it stood — the same place, other
    /// words — is drawn again. The screen's own report of what it wrote is
    /// deliberately not passed on here at all: this is the regression test
    /// for the cell cache, and it fails if a frame draws what some earlier
    /// frame left on that row.
    func testARowRewrittenInPlaceIsDrawnAgain() throws {
        let paint = try renderer()
        let blank = Row(width: 10)
        let before = Terminal.Scene(
            lines: [line("iiiiiiiiii"), blank], marks: [], caret: nil,
            width: 10, height: 2, back: 0, top: 100
        )
        // Four frames of the same words: the ring is three slots deep, so
        // the fifth frame lands on a slot that already holds this one.
        for _ in 0..<4 {
            paint.update(scene: before, damage: Damage(), selection: nil, strong: true)
        }
        let stale = try pixels(of: paint)

        // The screen wrote over that row and nothing else — the row beside
        // it is the very row it was — and nothing said so.
        let after = Terminal.Scene(
            lines: [line("WWWWWWWWWW"), blank], marks: [], caret: nil,
            width: 10, height: 2, back: 0, top: 100
        )
        paint.update(scene: after, damage: Damage(), selection: nil, strong: true)
        let drawn = try pixels(of: paint)
        XCTAssertGreaterThan(apart(stale, drawn), 0, "the rewritten row has to be drawn again")

        // And what it drew is that frame: the same frame said whole, by the
        // same renderer, is the same pixels.
        paint.refresh(scene: after, selection: nil, strong: true)
        XCTAssertEqual(apart(drawn, try pixels(of: paint)), 0, "the row drawn is the row the frame is about")
    }

    /// A scroll is a move, not a rebuild: the rows that scrolled are still
    /// themselves afterwards, and the frame that moved them says what a
    /// frame built from nothing at all says.
    func testAScrolledFrameKeepsWhatTheScrollKept() throws {
        let paint = try renderer()
        let rows = [line("alpha"), line("bravo"), line("charlie"), line("delta")]
        let start = Terminal.Scene(
            lines: rows, marks: [], caret: nil, width: 10, height: 4, back: 0, top: 100
        )
        for _ in 0..<4 {
            paint.update(scene: start, damage: Damage(), selection: nil, strong: true)
        }

        // The screen scrolled by one: the content moved a row up it, and
        // the bottom row is new. The rows are the very rows they were.
        let moved = Terminal.Scene(
            lines: [rows[1], rows[2], rows[3], line("echo")], marks: [], caret: nil,
            width: 10, height: 4, back: 0, top: 101
        )
        paint.update(scene: moved, damage: Damage(scrolled: true), selection: nil, strong: true)
        let scrolled = try pixels(of: paint)

        paint.refresh(scene: moved, selection: nil, strong: true)
        XCTAssertEqual(
            apart(scrolled, try pixels(of: paint)), 0,
            "a moved row is the same row: the frame says what a whole rebuild says"
        )
    }

    /// A program's output, drawn the way the view draws it: a frame for each
    /// batch of bytes the screen took, through the real parser and the real
    /// places, each frame saying only what the one before it did not. What a
    /// `cat` of a long file comes to, and what each of those frames has to
    /// come to is the frame the screen is showing.
    func testAFramePerBatchOfOutputIsTheFrameTheScreenShows() throws {
        let paint = try renderer()
        let screen = Screen(width: 10, height: 4)
        let parser = Parser(screen: screen)

        // Four frames of the empty screen first, so every slot of the ring
        // has been written from one: the fifth is the first that can be
        // converted in part.
        for _ in 0..<4 {
            paint.update(scene: screen.scene(lifted: 0), damage: Damage(), selection: nil, strong: true)
        }

        // More words than rows, so the screen scrolls a few times on the way.
        for word in ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"] {
            parser.feed(Array((word + "\r\n").utf8))
            let frame = screen.scene(lifted: 0)
            paint.update(scene: frame, damage: Damage(scrolled: true), selection: nil, strong: true)
            let drawn = try pixels(of: paint)

            paint.refresh(scene: frame, selection: nil, strong: true)
            XCTAssertEqual(
                apart(drawn, try pixels(of: paint)), 0,
                "the frame after \(word) is the frame the screen shows"
            )
        }
    }

    // MARK: - the lines a word can wear

    /// A word that asked for a line under it gets one, in the colour the
    /// program named for the line (SGR 58) when it named one, and in the
    /// ink of the words it runs under when it named none.
    func testALineUnderAWordPaintsInTheColourTheProgramNamed() throws {
        let paint = try renderer()
        var ink = Ink()
        ink.underline = true
        ink.line = .rgb(255, 0, 0)
        var row = Row(width: 10)
        for column in 0..<10 { row.cells[column] = Cell(char: "W", ink: ink) }
        let scene = Terminal.Scene(
            lines: [row, Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let (pixels, across: width) = try frame(of: paint)

        // The line sits under the words, at the bottom of the first row:
        // red pixels there — the pure red a program named, which nothing
        // else in the frame is.
        let inset = Int(TerminalDraw.inset * 2)
        var red = 0
        var redRow = 0
        for y in inset..<(inset + Int(paint.cell.height * 2) - 1) {
            var rowRed = 0
            for x in inset..<(inset + Int(paint.cell.width * 2 * 10)) {
                let o = (y * width + x) * 4
                // The drawable is BGRA: red is the third byte.
                if pixels[o + 2] > 200, pixels[o] < 60, pixels[o + 1] < 60 { rowRed += 1 }
            }
            if rowRed > red { red = rowRed; redRow = y }
        }
        XCTAssertGreaterThan(red, 10, "the line under the words wears the colour the program named it; painted \(red) red pixels at row \(redRow)")
    }

    /// A curly line (4:3) is drawn as the heavier one — a line that carries
    /// more weight than the straight one beside it, which is the shorthand
    /// a quad holds for a wave at cell sizes.
    func testACurlyLineIsDrawnHeavierThanAStraightOne() throws {
        let paint = try renderer()
        var straight = Ink(); straight.underline = true
        var curly = straight; curly.curl = true
        var row = Row(width: 10)
        for column in 0..<5 { row.cells[column] = Cell(char: "i", ink: straight) }
        for column in 5..<10 { row.cells[column] = Cell(char: "i", ink: curly) }
        let scene = Terminal.Scene(
            lines: [row, Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let (pixels, across: width) = try frame(of: paint)

        let theme = TerminalDraw.Theme.current()
        let inset = Int(TerminalDraw.inset * 2)
        let cell = Int(paint.cell.width * 2)
        func lined(_ from: Int, _ to: Int) -> Int {
            var painted = 0
            for y in inset..<(inset + Int(paint.cell.height * 2) - 1) {
                for x in (inset + from * cell)..<(inset + to * cell) {
                    let o = (y * width + x) * 4
                    let gap = abs(Double(pixels[o]) / 255 - Double(theme.ink.x))
                        + abs(Double(pixels[o + 1]) / 255 - Double(theme.ink.y))
                        + abs(Double(pixels[o + 2]) / 255 - Double(theme.ink.z))
                    if gap < 0.2 { painted += 1 }
                }
            }
            return painted
        }
        let heavy = lined(5, 10), plain = lined(0, 5)
        XCTAssertGreaterThan(
            Double(heavy) / Double(max(1, plain)), 1.3,
            "the curly line carries more weight than the straight one; \(heavy) pixels against \(plain)"
        )
    }

    /// A hidden word (SGR 8) wears nothing at all — not the glyph, and not
    /// the line under it, which is the one thing that would give it away.
    func testAHiddenWordWearsNoLineEither() throws {
        let paint = try renderer()
        var ink = Ink()
        ink.hidden = true
        ink.underline = true
        var row = Row(width: 10)
        for column in 0..<10 { row.cells[column] = Cell(char: "W", ink: ink) }
        let scene = Terminal.Scene(
            lines: [row, Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let (pixels, across: width) = try frame(of: paint)

        let theme = TerminalDraw.Theme.current()
        // The whole first row is the ground — the words are hidden, and so
        // are the lines that would have run under them.
        let inset = Int(TerminalDraw.inset * 2)
        var stray = 0
        for y in inset..<(inset + Int(paint.cell.height * 2) - 1) {
            for x in inset..<(inset + Int(paint.cell.width * 2 * 10)) {
                let o = (y * width + x) * 4
                let gap = abs(Double(pixels[o]) / 255 - Double(theme.ground.x))
                    + abs(Double(pixels[o + 1]) / 255 - Double(theme.ground.y))
                    + abs(Double(pixels[o + 2]) / 255 - Double(theme.ground.z))
                if gap > 0.1 { stray += 1 }
            }
        }
        XCTAssertEqual(stray, 0, "a hidden word is hidden whole — glyph and line both; \(stray) pixels off the ground")
    }

    // MARK: - DECSCNM

    /// A reversed screen (DECSCNM) turns a square over: the words that
    /// named no ink paint in it, and the ground behind them is the ground
    /// — the whole screen the negative of the one it was.
    func testAReversedScreenPaintsTheNegativeOfItself() throws {
        let paint = try renderer()
        let words = line("Metal!")
        let scene = Terminal.Scene(
            lines: [words, Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true, reversed: true)
        let (pixels, across: width) = try frame(of: paint)

        // The ground behind the words is the ink of the theme — every
        // square that named nothing is named for its ink — and the words
        // themselves paint in the ground's colour.
        let theme = TerminalDraw.Theme.current()
        let inset = Int(TerminalDraw.inset * 2)
        var inky = 0
        for y in inset..<(inset + Int(paint.cell.height * 2) - 1) {
            for x in (inset + Int(paint.cell.width * 2 * 6))..<(inset + Int(paint.cell.width * 2 * 10)) {
                let o = (y * width + x) * 4
                let gap = abs(Double(pixels[o]) / 255 - Double(theme.ink.x))
                    + abs(Double(pixels[o + 1]) / 255 - Double(theme.ink.y))
                    + abs(Double(pixels[o + 2]) / 255 - Double(theme.ink.z))
                if gap < 0.1 { inky += 1 }
            }
        }
        let empty = Int(paint.cell.width * 2 * 4) * (Int(paint.cell.height * 2) - 1)
        XCTAssertGreaterThan(inky, empty * 9 / 10, "the squares behind the words are the theme's ink, not its ground; painted \(inky) of \(empty)")
    }

    // MARK: - SGR 5

    /// A word wearing SGR 5 paints on one half of the blink and hides on
    /// the other — and only the word: the square it sits on is whatever the
    /// ground says of it.
    func testABlinkingWordHidesOnTheHalfItBlinkedOff() throws {
        let paint = try renderer()
        var ink = Ink()
        ink.blink = true
        var row = Row(width: 10)
        for column in 0..<10 { row.cells[column] = Cell(char: "W", ink: ink) }
        let scene = Terminal.Scene(
            lines: [row, Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true, blinking: false)
        var hidden = specks(try pixels(of: paint))
        XCTAssertEqual(hidden, 0, "a blinked-off word is not on the screen at all; painted \(hidden) pixels")

        paint.refresh(scene: scene, selection: nil, strong: true, blinking: true)
        hidden = specks(try pixels(of: paint))
        XCTAssertGreaterThan(hidden, 300, "the same word, blinked back on, is; painted \(hidden) pixels")
    }
}
