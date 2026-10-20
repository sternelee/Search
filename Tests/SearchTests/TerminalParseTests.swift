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
    private var copies: [String] = []

    override func setUp() {
        super.setUp()
        screen = Screen()
        parser = Parser(screen: screen)
        notices = []
        replies = []
        copies = []
        parser.say = { [weak self] in self?.notices.append($0) }
        parser.reply = { [weak self] in self?.replies.append($0) }
        parser.copied = { [weak self] in self?.copies.append($0) }
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
        XCTAssertFalse(screen.rows[0].cells[0].ink.bold)
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
        // underline, 4:4 the dotted one — kept as an underline, though
        // the screen draws the two of them the same heavy way).
        feed("\u{1b}[4:3mX")
        XCTAssertTrue(screen.rows[0].cells[0].ink.underline)
        XCTAssertTrue(screen.rows[0].cells[0].ink.curl, "4:3 is the curly underline")
        feed("\u{1b}[4:4mY")
        XCTAssertTrue(screen.rows[0].cells[1].ink.underline, "4:4 is still an underline")
        XCTAssertFalse(screen.rows[0].cells[1].ink.curl, "4:4 is dotted, not curly")
        feed("\u{1b}[24m.")
        XCTAssertFalse(screen.ink.underline)
        XCTAssertFalse(screen.ink.curl, "24 takes the line away, whatever its style")
    }

    /// SGR 21 is the double underline — the one it was taken for in the
    /// days when a vt220 could not hold a style it had not the line for.
    /// 22 is the other one: bold and faint off, the pair SGR 1 and 2 set.
    func testSGR21IsTheDoubleUnderlineNotBoldOff() {
        feed("\u{1b}[1mb\u{1b}[21mu")
        XCTAssertTrue(screen.rows[0].cells[0].ink.bold, "21 leaves bold alone")
        XCTAssertTrue(screen.rows[0].cells[1].ink.underline, "21 is the double underline")
        XCTAssertFalse(screen.rows[0].cells[1].ink.curl, "21 is double, not curly")
        feed("\u{1b}[4:3mc\u{1b}[21mv")
        XCTAssertTrue(screen.rows[0].cells[3].ink.underline)
        XCTAssertFalse(screen.rows[0].cells[3].ink.curl, "21 replaces the curly style with the double one")
    }

    /// SGR 58: the line under (or through) the words gets a colour of its
    /// own — the same two forms 38 and 48 speak — and 59 takes it away.
    func testSGR58IsTheLinesOwnColour() {
        feed("\u{1b}[4;58;5;196mu")
        XCTAssertEqual(screen.ink.underline, true)
        XCTAssertEqual(screen.ink.line, .ansi(196), "58;5;n names the line's colour from the 256")
        feed("\u{1b}[9;58;2;10;20;30ms")
        XCTAssertEqual(screen.ink.line, .rgb(10, 20, 30), "58;2;r;g;b names it from the colour itself")
        feed("\u{1b}[59m.")
        XCTAssertEqual(screen.ink.line, .plain, "59 takes the line's colour away")
        XCTAssertEqual(screen.ink.strike, true, "59 leaves the strike alone")
    }

    // MARK: The private modes

    func testDecsetAndDecrst() {
        feed("\u{1b}[?1000;1006;2004h")
        XCTAssertEqual(screen.mouse, .click)
        XCTAssertEqual(screen.mouseFormat, .sgr)
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

    // MARK: Modes the program asks about and turns on

    func testFocusAndSynchronizedOutput() {
        feed("\u{1b}[?1004h")
        XCTAssertTrue(screen.focusReporting, "1004: the program wants to hear when the keyboard moves")
        feed("\u{1b}[?1004l")
        XCTAssertFalse(screen.focusReporting)
        feed("\u{1b}[?2026h")
        XCTAssertTrue(screen.syncOutput, "2026: the program is building a frame out of sight")
        feed("\u{1b}[?2026l")
        XCTAssertFalse(screen.syncOutput)
    }

    func testAModeThatChangedIsDamage() {
        screen.take()
        feed("\u{1b}[?1004h")
        XCTAssertTrue(screen.take().moved, "a program that only turns a mode on still gets its frame")
    }

    /// The three mouse encodings replace each other rather than piling up:
    /// a program that sets 1006 and then 1016 has changed its mind about
    /// one encoding, not asked for two at once. Turning one off leaves the
    /// plain one, which is what it was in before any of them.
    func testOneMouseEncodingReplacesTheLast() {
        feed("\u{1b}[?1006h")
        XCTAssertEqual(screen.mouseFormat, .sgr)
        feed("\u{1b}[?1015h")
        XCTAssertEqual(screen.mouseFormat, .urxvt, "urxvt's, in place of SGR's")
        feed("\u{1b}[?1016h")
        XCTAssertEqual(screen.mouseFormat, .sgrPixels, "and SGR counting pixels, in place of that")
        XCTAssertTrue(screen.mouseFormat.pixels)
        feed("\u{1b}[?1016l")
        XCTAssertEqual(screen.mouseFormat, .legacy, "turning it off leaves the plain encoding behind")
        feed("\u{1b}[?1006h")
        feed("\u{1b}[?1006l")
        XCTAssertEqual(screen.mouseFormat, .legacy)
    }

    /// And each of them answers for itself when asked: 1006 on does not
    /// mean 1015 is on.
    func testTheMouseEncodingsAreAnsweredApart() {
        feed("\u{1b}[?1016h")
        feed("\u{1b}[?1016$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1016;1$y", "the encoding that is on says so")
        feed("\u{1b}[?1006$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1006;2$y", "and the one it replaced does not")
        feed("\u{1b}[?1015$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1015;2$y")
    }

    func testModeQueryIsAnswered() {
        feed("\u{1b}[?2004h")            // bracketed paste, on
        feed("\u{1b}[?1004$p")           // ...and is it on?
        XCTAssertEqual(replies.last, "\u{1b}[?1004;2$y", "a mode that is off says so")
        feed("\u{1b}[?2004$p")
        XCTAssertEqual(replies.last, "\u{1b}[?2004;1$y", "a mode that is on says so")
        feed("\u{1b}[?9999$p")
        XCTAssertEqual(replies.last, "\u{1b}[?9999;0$y", "a mode nobody has is answered as unknown, not guessed at")
        feed("\u{1b}[4$p")
        XCTAssertEqual(replies.last, "\u{1b}[4;2$y", "and the ansi modes are answered the same way")
    }

    func testAnAnswerIsNotAQuestion() {
        // DECRPM, the reply to the above. A terminal that answered its own
        // answers would talk to itself for ever.
        let before = replies.count
        feed("\u{1b}[?2004;1$y")
        XCTAssertEqual(replies.count, before)
    }

    func testTheCursorIsMovedByRestoreNotByTheKeyboardsQuery() {
        feed("abc")
        feed("\u{1b}[1;1H\u{1b}7")      // somewhere, and remembered there
        feed("\u{1b}[3;3H")
        feed("\u{1b}[?u")               // the kitty keyboard query: not a cursor at all
        XCTAssertEqual(screen.x, 2, "the query left the cursor where it was")
        XCTAssertEqual(screen.y, 2)
        feed("\u{1b}[u")                // and this one is the restore it has always been
        XCTAssertEqual(screen.x, 0)
        XCTAssertEqual(screen.y, 0)
    }

    // MARK: Character sets

    func testG2AndG3() {
        feed("\u{1b}*0\u{1b}nq")
        XCTAssertEqual(screen.rows[0].cells[0].char, "─", "G2 given the drawing set, chosen by LS2")
        feed("\u{1b}+0\u{1b}ol")
        XCTAssertEqual(screen.rows[0].cells[1].char, "┌", "G3 given the drawing set, chosen by LS3")
        feed("\u{1b}+B\u{1b}om")
        XCTAssertEqual(screen.rows[0].cells[2].char, "m", "G3 put back to ASCII, and still the one chosen")
    }

    // MARK: Swallowing

    func testHyperlinksAreLaidOverTheWordsTheyCover() {
        feed("\u{1b}]8;;https://metalterm.dev\u{1b}\\this way\u{1b}]8;;\u{1b}\\ and not this")
        XCTAssertEqual(screen.links, ["https://metalterm.dev"])
        let cells = screen.rows[0].cells
        XCTAssertNotEqual(cells[0].link, 0, "the words under the link carry it")
        XCTAssertNotEqual(cells[7].link, 0, "all of them")
        XCTAssertEqual(cells[8].link, 0, "and the ones past the end do not")
        XCTAssertEqual(screen.link(of: cells[0]), "https://metalterm.dev")
        XCTAssertNil(screen.link(of: cells[9]))
    }

    func testTheSameAddressWrittenTwiceIsOneEntry() {
        feed("\u{1b}]8;;https://a.dev\u{1b}\\one\u{1b}]8;;\u{1b}\\\u{1b}]8;;https://a.dev\u{1b}\\two\u{1b}]8;;\u{1b}\\")
        XCTAssertEqual(screen.links, ["https://a.dev"], "the table holds the address, not each use of it")
        XCTAssertEqual(screen.rows[0].cells[0].link, screen.rows[0].cells[3].link)
    }

    func testALinkEndsWhereTheProgramEndsIt() {
        feed("\u{1b}]8;;https://b.dev\u{1b}\\in")
        feed("\u{1b}]8;;\u{1b}\\out")
        XCTAssertEqual(screen.rows[0].cells[0].link, 1)
        XCTAssertEqual(screen.rows[0].cells[2].link, 0, "the empty address is how a link is closed")
    }

    func testAnAddressWithSemicolonsInItIsKeptWhole() {
        feed("\u{1b}]8;;https://x.dev/a;b;c\u{1b}\\there")
        XCTAssertEqual(screen.links, ["https://x.dev/a;b;c"])
    }

    // MARK: The caret's colour, and the clipboard

    func testOsc12SetsTheCaretColour() {
        feed("\u{1b}]12;#ff0000\u{07}")
        XCTAssertEqual(screen.cursorInk, .rgb(255, 0, 0), "#RRGGBB")
        feed("\u{1b}]12;#f00\u{07}")
        XCTAssertEqual(screen.cursorInk, .rgb(255, 0, 0), "and the short way: one digit to a channel")
        feed("\u{1b}]12;rgb:00/80/ff\u{07}")
        XCTAssertEqual(screen.cursorInk, .rgb(0, 128, 255), "rgb:RR/GG/BB")
        feed("\u{1b}]12;rgba:ff/ff/ff/80\u{07}")
        XCTAssertEqual(screen.cursorInk, .rgb(255, 255, 255), "rgba: — the alpha is dropped, nothing here being translucent")
    }

    func testASpecThatIsNotAColourLeavesTheCaretAsItWas() {
        feed("\u{1b}]12;#123456\u{07}")
        feed("\u{1b}]12;not a colour\u{07}")
        XCTAssertEqual(screen.cursorInk, .rgb(0x12, 0x34, 0x56))
        feed("\u{1b}]12\u{07}")
        XCTAssertEqual(screen.cursorInk, .rgb(0x12, 0x34, 0x56), "and neither does a sequence with no spec at all")
    }

    func testOsc112PutsTheCaretBackToTheThemesOwn() {
        feed("\u{1b}]12;#123456\u{07}")
        _ = screen.take()
        feed("\u{1b}]112\u{07}")
        XCTAssertEqual(screen.cursorInk, .plain)
        XCTAssertTrue(screen.take().moved, "a caret that changed colour is a frame owed")
    }

    func testOsc52PutsTextOnTheClipboard() {
        let said = Data("hello from the program".utf8).base64EncodedString()
        feed("\u{1b}]52;c;\(said)\u{07}")
        XCTAssertEqual(copies, ["hello from the program"])
    }

    func testAProgramThatAsksToReadTheClipboardIsRefused() {
        feed("\u{1b}]52;c;?\u{07}")
        XCTAssertEqual(copies, [], "no escape sequence reads the clipboard")
        XCTAssertEqual(replies, ["\u{1b}]52;c;\u{07}"], "and the program is told the selection is empty rather than left waiting")
    }

    func testAClipboardPayloadThatIsNotBase64IsSwallowed() {
        let before = parser.swallowed
        feed("\u{1b}]52;c;not base64 at all!\u{07}")
        XCTAssertEqual(copies, [])
        XCTAssertGreaterThan(parser.swallowed, before)
    }

    func testUnknownSequencesAreCountedNotRun() {
        let before = parser.swallowed
        feed("\u{1b}]4;1;rgb:00/00/00\u{07}")      // the palette: not spoken
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
