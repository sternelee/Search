import XCTest
@testable import Search

/// The screen without the terminal: everything it does to itself — the
/// wraparound at its edge, the scrollback behind its top, the region an
/// editor sets inside it, the alternate it keeps for the programs that
/// take the whole thing over — done to it directly, and taken apart the
/// same way.
final class TerminalGridTests: XCTestCase {
    private func type(_ screen: Screen, _ text: String) {
        // A line's ends are two scalars wearing one character — iterate
        // the scalars so both of them are seen.
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r": screen.carriageReturn()
            case "\n": screen.lineFeed()
            default:
                let char = Character(scalar)
                screen.put(char, wide: Parser.isWide(char))
            }
        }
    }

    // MARK: Writing

    func testWraparoundAtWidthEdge() {
        let screen = Screen(width: 5, height: 3)
        type(screen, "abcde")
        XCTAssertEqual(screen.rows[0].text, "abcde")
        XCTAssertEqual(screen.x, 4)
        XCTAssertTrue(screen.pendingWrap)
        type(screen, "f")
        // The wrap happens on the next character, not on touching the
        // edge — a program that means to can move back and use the square.
        XCTAssertEqual(screen.y, 1)
        XCTAssertEqual(screen.rows[1].text, "f")
    }

    func testWideCharacterTakesTwoSquaresAndClipsAtEdge() {
        let screen = Screen(width: 5, height: 3)
        type(screen, "ab你")
        XCTAssertEqual(screen.rows[0].cells[2].char, "你")
        XCTAssertTrue(screen.rows[0].cells[2].wide)
        XCTAssertEqual(screen.rows[0].cells[3].char, " ")
        XCTAssertEqual(screen.x, 4)
        // A wide character at the last square fits in its one square,
        // the same square the next character would have to wrap past.
        type(screen, "你")
        XCTAssertEqual(screen.rows[0].cells[4].char, "你")
        XCTAssertTrue(screen.pendingWrap)
        XCTAssertEqual(screen.y, 0)
    }

    func testCarriageReturnAndBackspace() {
        let screen = Screen(width: 10, height: 3)
        type(screen, "abc")
        screen.carriageReturn()
        XCTAssertEqual(screen.x, 0)
        type(screen, "x")
        XCTAssertEqual(screen.rows[0].text, "xbc")
        screen.backspace()
        XCTAssertEqual(screen.x, 0, "backspace never moves past the first square")
        screen.backspace()
        XCTAssertEqual(screen.x, 0)
    }

    func testTabMovesToNextStop() {
        let screen = Screen(width: 40, height: 3)
        screen.tab()
        XCTAssertEqual(screen.x, 8)
        screen.clearTabStop(at: 16)
        screen.tab()
        XCTAssertEqual(screen.x, 24, "the stop taken away is skipped")
        screen.clearTabStops()
        screen.tab()
        XCTAssertEqual(screen.x, 39, "no stops left: the last square")
        screen.setTabStop()
        XCTAssertEqual(screen.tabStops, [39])
    }

    // MARK: Scrolling

    func testLineFeedAtBottomScrollsIntoBack() {
        let screen = Screen(width: 5, height: 3)
        type(screen, "one\r\ntwo\r\nthr")
        screen.lineFeed()
        XCTAssertEqual(screen.back.map(\.text), ["one"])
        XCTAssertEqual(screen.rows.map(\.text).dropLast(1), ["two", "thr"])
        XCTAssertEqual(screen.backBase, 0)
        XCTAssertEqual(screen.place(0), 1, "the top row is now the second place there ever was")
        let taken = screen.take()
        XCTAssertTrue(taken.scrolled)
    }

    func testScrollRegionHoldsItsBounds() {
        let screen = Screen(width: 5, height: 6)
        type(screen, "a\r\nb\r\nc\r\nd\r\ne\r\nf")
        screen.setRegion(top: 2, bottom: 3)
        XCTAssertEqual(screen.top, 2)
        XCTAssertEqual(screen.bottom, 3)
        screen.move(to: 0, row: 3)
        screen.lineFeed()
        // The rows above and below the region are not the region's to
        // move; only its own leave and enter it.
        XCTAssertEqual(screen.rows.map(\.text), ["a", "b", "d", "", "e", "f"])
        XCTAssertTrue(screen.back.isEmpty, "a scroll inside a region below the top is not the scrollback's")
    }

    func testReverseFeedScrollsRegionDownAtTop() {
        let screen = Screen(width: 5, height: 3)
        type(screen, "one\r\ntwo\r\nthr")
        screen.move(to: 0, row: 0)
        screen.reverseFeed()
        XCTAssertEqual(screen.rows.map(\.text), ["", "one", "two"])
        XCTAssertEqual(screen.y, 0)
    }

    func testBackLimitDropsOldestRowsAndBlocksGoneWithThem() {
        let screen = Screen(width: 5, height: 2)
        screen.backLimit = 3
        type(screen, "one\r\ntwo")
        screen.markPrompt()
        for _ in 0..<5 {
            screen.lineFeed()
            type(screen, "x")
        }
        XCTAssertEqual(screen.back.count, 3)
        XCTAssertEqual(screen.backBase, 2)
        XCTAssertTrue(screen.blocks.isEmpty, "the block was in the rows that fell out of the scrollback")
        XCTAssertTrue(screen.take().blocks)
    }

    /// Trimming to a limit set after the fact — what turning the scrollback
    /// down in Settings does — drops the rows scrolling past that limit
    /// would have dropped.
    func testTrimDropsRowsPastALoweredLimit() {
        let screen = Screen(width: 5, height: 2)
        type(screen, "one\r\ntwo")
        screen.markPrompt()
        for _ in 0..<5 {
            screen.lineFeed()
            type(screen, "x")
        }
        XCTAssertEqual(screen.back.count, 5, "no limit was in force while the rows went past")

        screen.backLimit = 3
        screen.trim()
        XCTAssertEqual(screen.back.count, 3)
        XCTAssertEqual(screen.backBase, 2)
        XCTAssertTrue(screen.blocks.isEmpty, "the block was in the rows that fell out of the scrollback")
        XCTAssertTrue(screen.take().blocks)
    }

    // MARK: Erasing and rearranging

    func testEraseDisplayModes() {
        let screen = Screen(width: 4, height: 3)
        type(screen, "aaaa\r\nbbbb\r\ncccc")
        screen.move(to: 1, row: 1)
        screen.eraseDisplay(1)
        XCTAssertEqual(screen.rows.map(\.text), ["", "  bb", "cccc"])
        screen.eraseDisplay(0)
        XCTAssertEqual(screen.rows.map(\.text), ["", "", ""])
        XCTAssertEqual(screen.x, 1, "the cursor stays where the erasing found it")
        XCTAssertEqual(screen.y, 1)
        screen.eraseDisplay(2)
        XCTAssertEqual(screen.rows.map(\.text), ["", "", ""])
    }

    func testEraseDisplay3ClearsScrollback() {
        let screen = Screen(width: 5, height: 2)
        type(screen, "gone\r\nhere")
        screen.lineFeed()
        XCTAssertEqual(screen.back.count, 1)
        screen.eraseDisplay(3)
        XCTAssertTrue(screen.back.isEmpty)
        XCTAssertEqual(screen.backBase, 1)
        XCTAssertEqual(screen.rows.map(\.text), ["here", ""])
    }

    func testEraseRowModes() {
        let screen = Screen(width: 5, height: 2)
        type(screen, "abcde")
        screen.move(to: 2, row: 0)
        screen.eraseRow(0)
        XCTAssertEqual(screen.rows[0].text, "ab")
        // 1 erases from the beginning through the cursor's square —
        // typed over again, the same row from the same place.
        type(screen, "cde")
        screen.move(to: 2, row: 0)
        screen.eraseRow(1)
        XCTAssertEqual(screen.rows[0].text, "   de", "1 blanks through the cursor's square, spaces kept — a prompt's dent matters")
        screen.eraseRow(2)
        XCTAssertEqual(screen.rows[0].text, "")
    }

    func testInsertAndDeleteChars() {
        let screen = Screen(width: 6, height: 2)
        type(screen, "abcdef")
        screen.carriageReturn()
        screen.insertChars(2)
        XCTAssertEqual(screen.rows[0].text, "  abcd")
        screen.deleteChars(3)
        XCTAssertEqual(screen.rows[0].text, "bcd", "the blanks and the a went, the tail padded with blanks")
        XCTAssertEqual(screen.x, 0)
    }

    func testInsertAndDeleteRows() {
        let screen = Screen(width: 4, height: 5)
        type(screen, "aa\r\nbb\r\ncc\r\ndd\r\nee")
        screen.move(to: 0, row: 1)
        screen.insertRows(2)
        XCTAssertEqual(screen.rows.map(\.text), ["aa", "", "", "bb", "cc"])
        screen.deleteRows(3)
        XCTAssertEqual(screen.rows.map(\.text), ["aa", "cc", "", "", ""])
    }

    // MARK: The alternate screen

    func testAlternateScreenKeepsAndRestores() {
        let screen = Screen(width: 6, height: 3)
        type(screen, "main")
        screen.enterAlternate()
        XCTAssertTrue(screen.alternate)
        XCTAssertEqual(screen.rows[0].text, "")
        type(screen, "alt")
        screen.exitAlternate()
        XCTAssertFalse(screen.alternate)
        XCTAssertEqual(screen.rows[0].text, "main")
        XCTAssertTrue(screen.back.isEmpty, "the alternate never scrolls into the scrollback")
    }

    func testAlternateRebuildsAfterResize() {
        let screen = Screen(width: 4, height: 2)
        type(screen, "main")
        screen.enterAlternate()
        screen.resize(width: 7, height: 3)
        type(screen, "alt")
        screen.exitAlternate()
        XCTAssertEqual(screen.rows.map(\.text), ["main", "", ""])
    }

    // MARK: Resizing

    func testResizeClipsPadsAndRebuildsRegion() {
        let screen = Screen(width: 4, height: 2)
        type(screen, "abcd\r\nefgh")
        screen.setRegion(top: 0, bottom: 0)
        screen.resize(width: 3, height: 3)
        XCTAssertEqual(screen.width, 3)
        XCTAssertEqual(screen.height, 3)
        XCTAssertEqual(screen.rows.map(\.text), ["abc", "efg", ""])
        XCTAssertEqual(screen.top, 0)
        XCTAssertEqual(screen.bottom, 2, "a resize gives the region back the whole screen")
        XCTAssertEqual(screen.x, 0)
        let taken = screen.take()
        XCTAssertTrue(taken.overturned)
        XCTAssertTrue(taken.scrolled)
    }

    // MARK: Blocks

    func testBlocksMarkedOutByPlace() {
        let screen = Screen(width: 5, height: 4)
        type(screen, "$ ")
        screen.markPrompt()
        screen.markCommand()
        type(screen, "run")
        screen.lineFeed()
        screen.markEnd(exit: 1)
        XCTAssertEqual(screen.blocks.count, 1)
        let block = screen.blocks[0]
        XCTAssertEqual(block.first, 0)
        XCTAssertEqual(block.last, 1)
        XCTAssertEqual(block.state, .done)
        XCTAssertEqual(block.exit, 1)
        XCTAssertTrue(block.failed)
        screen.markPrompt()
        XCTAssertEqual(screen.blocks.count, 2)
        XCTAssertEqual(screen.blocks[1].state, .prompt)
        XCTAssertEqual(screen.blocks[1].first, 1)
    }

    // MARK: Damage

    func testDamageTakenIsDrained() {
        let screen = Screen(width: 5, height: 3)
        XCTAssertTrue(screen.take().empty)
        type(screen, "hi")
        let taken = screen.take()
        XCTAssertEqual(taken.rows, [0])
        XCTAssertTrue(screen.take().empty)
        screen.reset()
        XCTAssertTrue(screen.take().overturned)
        XCTAssertTrue(screen.take().empty)
    }

    /// A caret that moved is a change in its own right. Nothing in the
    /// cells says so, and a frame that draws no caret where the caret is
    /// is a frame drawn wrong — so a screen where only the caret moved
    /// still owes one (`printf '\033[10C'` on an idle terminal).
    func testDamageCountsACaretThatMoved() {
        let screen = Screen(width: 5, height: 3)
        XCTAssertTrue(screen.take().empty)
        screen.move(to: 3, row: 2)
        let moved = screen.take()
        XCTAssertTrue(moved.moved, "the caret is somewhere else now")
        XCTAssertTrue(moved.rows.isEmpty, "and not one cell changed with it")
        XCTAssertTrue(screen.take().empty, "taken, not watched")
    }

    /// Every way of moving it counts, the erased-for-a-moment ones too: a
    /// program that hides its caret and draws nothing is still a program
    /// whose screen has changed (DECSET 25 is what every full-screen
    /// program sends on its way in and out).
    func testDamageCountsEveryWayTheCaretMoves() {
        for moving in [
            { (screen: Screen) in screen.carriageReturn() },
            { (screen: Screen) in screen.lineFeed() },
            { (screen: Screen) in screen.backspace() },
            { (screen: Screen) in screen.tab() },
            { (screen: Screen) in screen.moveBack(1) },
            { (screen: Screen) in screen.restoreCursor() },
            { (screen: Screen) in screen.visible = false },
            { (screen: Screen) in screen.reverseVideo = true },
        ] {
            let screen = Screen(width: 5, height: 3)
            screen.move(to: 3, row: 1)
            _ = screen.take()
            moving(screen)
            XCTAssertTrue(screen.take().moved, "a frame is owed for that")
        }
    }

    /// A mode the frame or the keyboard reads is set back to what it
    /// already was: nothing moved, and nothing is owed.
    func testDamageLeavesAModeThatDidNotChangeAlone() {
        let screen = Screen(width: 5, height: 3)
        _ = screen.take()
        screen.visible = true
        XCTAssertTrue(screen.take().empty)
    }

    func testResetPutsEverythingBack() {
        let screen = Screen(width: 5, height: 3)
        type(screen, "x\r\ny\r\nz")
        screen.setRegion(top: 1, bottom: 2)
        screen.ink.italic = true
        screen.wraparound = false
        screen.reset()
        XCTAssertEqual(screen.rows.map(\.text), ["", "", ""])
        XCTAssertEqual(screen.top, 0)
        XCTAssertEqual(screen.bottom, 2)
        XCTAssertFalse(screen.ink.italic)
        XCTAssertTrue(screen.wraparound)
        XCTAssertEqual(screen.x, 0)
        XCTAssertEqual(screen.y, 0)
    }

    func testFillPattern() {
        let screen = Screen(width: 3, height: 2)
        screen.fillPattern()
        XCTAssertEqual(screen.rows.map(\.text), ["EEE", "EEE"])
        XCTAssertEqual(screen.x, 0)
        XCTAssertEqual(screen.y, 0)
    }
}
