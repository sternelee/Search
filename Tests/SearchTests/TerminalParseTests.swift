import XCTest
@testable import Search

/// The parser fed by hand: the sequences a program sends, one at a time
/// and half of one at a time, with the screen taken apart after — the
/// purest part of the terminal, without a program behind it.
final class TerminalParseTests: XCTestCase {
    private var screen = Screen()
    private var parser = Parser(screen: Screen())
    private var notices: [Notice] = []
    private var replies: [String] = []

    override func setUp() {
        super.setUp()
        screen = Screen()
        parser = Parser(screen: screen)
        notices = []
        replies = []
        parser.say = { [weak self] in self?.notices.append($0) }
        parser.reply = { [weak self] in self?.replies.append($0) }
    }

    private func feed(_ text: String) {
        parser.feed(Array(text.utf8))
    }

    private func type(_ text: String) {
        for char in text { screen.put(char, wide: Parser.isWide(char)) }
    }

    // MARK: Characters

    func testPrintsAndWraps() {
        feed("hi")
        XCTAssertEqual(screen.rows[0].text.prefix(2), "hi")
        XCTAssertEqual(screen.x, 2)
        feed("\r\nnext")
        XCTAssertEqual(screen.y, 1)
        XCTAssertEqual(screen.rows[1].text.prefix(4), "next")
    }

    func testWideCharacterPrintsAcrossTwoSquares() {
        feed("你")
        XCTAssertEqual(screen.rows[0].cells[0].char, "你")
        XCTAssertTrue(screen.rows[0].cells[0].wide)
        XCTAssertEqual(screen.rows[0].cells[1].char, " ")
        XCTAssertEqual(screen.x, 2)
    }

    func testUtf8SplitAcrossFeeds() {
        let whole = Array("你".utf8)
        parser.feed(Array(whole.dropLast(1)))
        XCTAssertEqual(screen.rows[0].cells[0].char, " ")
        parser.feed(Array(whole.dropFirst(2)))
        XCTAssertEqual(screen.rows[0].cells[0].char, "你")
        // Four bytes that are not a character are the replacement, put
        // once and put behind.
        parser.feed([0xFF, 0xFE, 0xFF, 0xFE])
        XCTAssertEqual(screen.rows[0].cells[2].char, "\u{FFFD}")
    }

    // MARK: Cursor

    func testCursorPositioning() {
        feed("\u{1b}[3;5HX")
        XCTAssertEqual(screen.rows[2].cells[4].char, "X")
        feed("\u{1b}[2G!")
        XCTAssertEqual(screen.rows[2].cells[1].char, "!")
        feed("\u{1b}[1d@")
        XCTAssertEqual(screen.rows[0].cells[2].char, "@", "1d moves the row and keeps the column")
        feed("\u{1b}[C")
        XCTAssertEqual(screen.x, 4)
        feed("\u{1b}[2D")
        XCTAssertEqual(screen.x, 2)
        feed("\u{1b}[E")
        XCTAssertEqual(screen.y, 1)
        XCTAssertEqual(screen.x, 0)
        feed("\u{1b}[A")
        XCTAssertEqual(screen.y, 0)
    }

    // MARK: SGR

    func testSGRColorsAndAttributes() {
        feed("\u{1b}[31mR\u{1b}[1;38;2;10;20;30mB\u{1b}[mP")
        XCTAssertEqual(screen.ink.foreground, .plain, "0 puts the whole pen back")
        XCTAssertEqual(screen.rows[0].cells[0].ink.foreground, .ansi(1))
        XCTAssertEqual(screen.rows[0].cells[0].ink.bold, false)
        let blue = screen.rows[0].cells[1].ink
        XCTAssertTrue(blue.bold)
        XCTAssertEqual(blue.foreground, .rgb(10, 20, 30))
        XCTAssertEqual(screen.rows[0].cells[2].ink.foreground, .plain)
        feed("\u{1b}[38;5;196m\u{1b}[48;5;17m.")
        XCTAssertEqual(screen.ink.foreground, .ansi(196))
        XCTAssertEqual(screen.ink.background, .ansi(17))
        feed("\u{1b}[93m.")
        XCTAssertEqual(screen.ink.foreground, .ansi(11), "the nineties are the bright eight")
        feed("\u{1b}[4;9m.")
        XCTAssertTrue(screen.ink.underline)
        XCTAssertTrue(screen.ink.strike)
        feed("\u{1b}[24;29m.")
        XCTAssertFalse(screen.ink.underline)
        XCTAssertFalse(screen.ink.strike)
    }

    func testSGRWithSubParameters() {
        // A colon speaks the sub-parameter's semicolon (4:3 the curly
        // underline, the straight one as far as this is concerned).
        feed("\u{1b}[4:3mX")
        XCTAssertEqual(screen.rows[0].cells[0].ink.underline, true)
    }

    // MARK: The private modes

    func testDecsetAndDecrst() {
        feed("\u{1b}[?1000;1006;2004h")
        XCTAssertEqual(screen.mouse, .click)
        XCTAssertTrue(screen.mouseExact)
        XCTAssertTrue(screen.bracketedPaste)
        feed("\u{1b}[?1002h")
        XCTAssertEqual(screen.mouse, .drag)
        feed("\u{1b}[?1003h")
        XCTAssertEqual(screen.mouse, .motion)
        feed("\u{1b}[?1000l")
        XCTAssertEqual(screen.mouse, .off)
        feed("\u{1b}[?25l")
        XCTAssertFalse(screen.visible)
        feed("\u{1b}[?25h")
        XCTAssertTrue(screen.visible)
        feed("\u{1b}[?7l")
        XCTAssertFalse(screen.wraparound)
        feed("\u{1b}[?7h")
        XCTAssertTrue(screen.wraparound)
        feed("\u{1b}[?6h")
        XCTAssertTrue(screen.origin)
        feed("\u{1b}[?6l")
        XCTAssertFalse(screen.origin)
    }

    func testAlternateScreenBy1049() {
        feed("main")
        feed("\u{1b}[?1049h")
        XCTAssertTrue(screen.alternate)
        XCTAssertEqual(screen.rows[0].text, "")
        feed("alt")
        feed("\u{1b}[?1049l")
        XCTAssertFalse(screen.alternate)
        XCTAssertEqual(screen.rows[0].text.prefix(4), "main")
    }

    func testInsertMode() {
        feed("abc")
        feed("\u{1b}[4h")
        feed("XY")
        XCTAssertEqual(screen.rows[0].text, "abcXY", "IRM puts the characters in at the cursor, the rest sliding away")
        feed("\u{1b}[4l")
        feed("Z")
        XCTAssertEqual(screen.rows[0].text, "abcXYZ")
    }

    // MARK: Erasing and scrolling

    func testEraseAndScrollSequences() {
        feed("abc\r\ndef")
        feed("\u{1b}[1J")
        XCTAssertEqual(screen.rows[0].text, "")
        XCTAssertEqual(screen.rows[1].text, "", "the cursor was at the end: 1 erases the row whole")
        feed("\u{1b}[2J")
        XCTAssertEqual(screen.rows[1].text, "")
        feed("\u{1b}[r")
        XCTAssertEqual(screen.top, 0)
        XCTAssertEqual(screen.bottom, screen.height - 1)
        feed("\u{1b}[2;10r")
        XCTAssertEqual(screen.top, 1)
        XCTAssertEqual(screen.bottom, 9)
    }

    func testREPRepeatsTheLastCharacter() {
        feed("a\u{1b}[3b")
        XCTAssertEqual(screen.rows[0].text.prefix(4), "aaaa")
    }

    // MARK: Replies

    func testDeviceStatusReport() {
        feed("\u{1b}[3;5H\u{1b}[6n")
        XCTAssertEqual(replies, ["\u{1b}[3;5R"])
        feed("\u{1b}[5n")
        XCTAssertEqual(replies.last, "\u{1b}[0n")
    }

    func testPrimaryDeviceAttributes() {
        feed("\u{1b}[c")
        XCTAssertEqual(replies, ["\u{1b}[?62;22c"])
        feed("\u{1b}[0c")
        XCTAssertEqual(replies.last, "\u{1b}[?62;22c")
        feed("\u{1b}Z")
        XCTAssertEqual(replies.last, "\u{1b}[?62;22c")
    }

    // MARK: ESC without the bracket

    func testPlainEscapes() {
        feed("abc")
        feed("\u{1b}D")
        XCTAssertEqual(screen.y, 1)
        feed("\u{1b}M")
        XCTAssertEqual(screen.y, 0)
        feed("\u{1b}E")
        XCTAssertEqual(screen.y, 1)
        XCTAssertEqual(screen.x, 0)
        feed("xy")
        feed("\u{1b}7\u{1b}[2J\u{1b}8")
        XCTAssertEqual(screen.rows[1].text, "", "7 and 8 carry the place, not the writing")
        feed("z")
        XCTAssertEqual(screen.rows[1].text, "  z", "8 brought the cursor back where 7 left it — the column, not the writing")
        feed("\u{1b}H")
        XCTAssertTrue(screen.tabStops.contains(screen.x))
        feed("\u{1b}c")
        XCTAssertTrue(screen.take().overturned)
    }

    func testAlignmentPattern() {
        feed("\u{1b}#8")
        XCTAssertEqual(screen.rows[0].text, String(repeating: "E", count: screen.width))
    }

    // MARK: Character sets

    func testDecLineDrawing() {
        feed("\u{1b}(0lqk\u{1b}(B")
        XCTAssertEqual(screen.rows[0].text.prefix(3), "┌─┐")
        feed("x\u{0E}x\u{0F}x")
        // SO and SI choose G1, which was never given the drawing set.
        XCTAssertEqual(screen.rows[0].cells[3].char, "x")
        feed("\u{1b})0\u{0E}x\u{0F}")
        XCTAssertEqual(screen.rows[0].cells[6].char, "│", "G1 given the drawing set, chosen by SO")
    }

    // MARK: OSC

    func testOscTitle() {
        feed("\u{1b}]0;My Shell\u{07}")
        XCTAssertEqual(notices, [.title("My Shell")])
        feed("\u{1b}]2;Other\u{1b}\\")
        XCTAssertEqual(notices.last, .title("Other"))
    }

    func testOscWorkingDirectory() {
        feed("\u{1b}]7;file://localhost/Users/you/a%20folder\u{07}")
        XCTAssertEqual(notices, [.cwd(URL(fileURLWithPath: "/Users/you/a folder"))])
        feed("\u{1b}]7;file://host/\u{07}")
        XCTAssertEqual(notices.last, .cwd(URL(fileURLWithPath: "/")))
        feed("\u{1b}]7;not a path\u{07}")
        XCTAssertEqual(notices.count, 2, "what isn't a file path is swallowed")
    }

    func testOscNotifications() {
        feed("\u{1b}]9;build done\u{07}")
        XCTAssertEqual(notices, [.note(title: "Terminal", body: "build done")])
        feed("\u{1b}]9;Build;took 3s\u{07}")
        XCTAssertEqual(notices.last, .note(title: "Build", body: "took 3s"))
        feed("\u{1b}]777;notify;Build;took 3s\u{07}")
        XCTAssertEqual(notices.last, .note(title: "Build", body: "took 3s"))
    }

    func testOsc133MarksBlocks() {
        feed("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}make\u{1b}]133;C\u{07}\u{1b}]133;D;0\u{07}")
        XCTAssertEqual(screen.blocks.count, 1)
        XCTAssertEqual(screen.blocks[0].state, .done)
        XCTAssertEqual(screen.blocks[0].exit, 0)
        XCTAssertFalse(screen.blocks[0].failed)
        feed("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}false\u{1b}]133;D;1\u{07}")
        XCTAssertEqual(screen.blocks.count, 2)
        XCTAssertTrue(screen.blocks[1].failed)
    }

    func testBell() {
        feed("x\u{07}y")
        XCTAssertEqual(notices, [.bell])
        XCTAssertEqual(screen.rows[0].text.prefix(2), "xy")
    }

    // MARK: Swallowing

    func testUnknownSequencesAreCountedNotRun() {
        let before = parser.swallowed
        feed("\u{1b}]8;;https://search.dev\u{07}")  // hyperlinks: not spoken
        feed("\u{1b}[?9001h")                        // a mode nobody knows
        feed("\u{1b}[99z")                            // a final nobody sends
        feed("\u{1b}_hidden\u{1b}\\")                 // APC: skipped whole
        XCTAssertGreaterThan(parser.swallowed, before)
        XCTAssertEqual(notices, [], "nothing swallowed says anything")
    }

    func testControlsRunInsideASequence() {
        // The controls inside a control sequence run; the sequence waits.
        feed("abcd")
        feed("\u{1b}[1")
        feed("\r")
        XCTAssertEqual(screen.x, 0, "the carriage return ran inside the sequence")
        feed("C")
        XCTAssertEqual(screen.x, 1, "and the sequence went on to its final anyway")
        XCTAssertEqual(screen.rows[0].text, "abcd")
    }
}
