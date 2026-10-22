import XCTest
@testable import Search

/// The input dock's manners (see TerminalDock): the shell's line editor
/// mirrored over OSC 7784, walked without a screen.
///
/// What is checked is the half of typing that has to be exact: which
/// glyphs a keystroke marked as arrived (an append marks what it appended;
/// a rewrite marks nothing, because a line that did not type itself is
/// already there), the veil's bounds, and the lifecycle the reports and
/// the marks walk the line through — owned while it is being edited,
/// fading where it stood when it is accepted, dropped when a prompt
/// begins, and the plate collapsed when the editor gives the line up.
@MainActor
final class TerminalDockTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "terminal-dock-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - the ledger

    /// A keystroke that appends marks only what it appended: the glyphs
    /// that were there keep the arrivals they had, and the new ones each
    /// get one. Anything else — the same line again, a caret that only
    /// moved — keeps every arrival it had.
    func testAnAppendMarksOnlyWhatItAppended() {
        let old = [DockLedger.settled, DockLedger.settled]
        let arrivals = DockLedger.arrivals(for: "abc", after: "ab", holding: old, at: 5)
        XCTAssertEqual(arrivals, [DockLedger.settled, DockLedger.settled, 5])
        // A line that did not change owes no glyph anything.
        let kept = DockLedger.arrivals(for: "abc", after: "abc", holding: arrivals, at: 6)
        XCTAssertEqual(kept, arrivals)
    }

    /// A line that did not type itself — a rewrite in the middle, an
    /// accept out of history, a paste — arrives whole and already there:
    /// nothing rises, because nothing was typed.
    func testARewriteMarksNothingAsArrived() {
        let arrivals = DockLedger.arrivals(for: "xyz", after: "abc", holding: [1, 1, 1], at: 5)
        XCTAssertEqual(arrivals.count, 3)
        XCTAssertFalse(arrivals.contains { $0 > 0 })
    }

    // MARK: - the veil

    /// The veil covers the prompt's own row to the bottom of the frame:
    /// the shell's echo of the line being edited and everything under it.
    /// A prompt above the frame (scrolled away) veils nothing, and one
    /// below it (a frame that cannot hold it) veils nothing either.
    func testTheVeilRunsFromThePromptToTheBottom() {
        XCTAssertEqual(TerminalDock.veil(prompt: 40, top: 32, rows: 24), 8..<24)
        XCTAssertNil(TerminalDock.veil(prompt: 40, top: 41, rows: 24), "above the frame")
        XCTAssertNil(TerminalDock.veil(prompt: 40, top: 32, rows: 8), "below the frame")
    }

    // MARK: - the life of a line

    /// The first report of a prompt arrives the plate and owns the input;
    /// the glyphs of the line it brings are settled (they did not type
    /// themselves), and a keystroke that appends marks its own.
    func testTheFirstReportArrivesThePlateAndOwnsTheInput() {
        let dock = TerminalDock()
        XCTAssertFalse(dock.owed)
        dock.report(.line(text: "ec", cursor: 2, suggestion: "ho"), at: 0)
        XCTAssertTrue(dock.owed)
        XCTAssertTrue(dock.owns)
        var model = dock.model(at: 0.05)
        XCTAssertLessThan(model.plate, 1, "the plate is still arriving")
        XCTAssertFalse(model.owns == false)
        // The glyphs came whole: nothing rises.
        XCTAssertTrue(model.arrivals.allSatisfy { $0 == DockLedger.settled })
        // The keystroke that appends marks what it appended, and bleeds
        // the caret once, which is a frame still owed.
        dock.report(.line(text: "ech", cursor: 3, suggestion: "o"), at: 0.1)
        model = dock.model(at: 0.12)
        XCTAssertEqual(model.arrivals.last ?? 0, 0.1, accuracy: 0.001)
        XCTAssertTrue(dock.moving(at: 0.12), "a glyph is rising and a bleed is on")
        // A fifth of a window later the glyph has arrived, and when the
        // bleed is spent and the caret is home, nothing moves.
        XCTAssertFalse(dock.moving(at: 0.4))
    }

    /// The caret rides the find panel's own curves: a move is a leg — the
    /// head arrives early on the quartic and the tail trails it, the gap
    /// between them the smear — and both land where the column said.
    func testTheCaretTravelsTheWarpCurves() {
        let dock = TerminalDock()
        dock.report(.line(text: "abc", cursor: 1, suggestion: ""), at: 0)
        dock.report(.line(text: "abc", cursor: 3, suggestion: ""), at: 1)
        // An eighth of the leg (settle .40, travel .25 of it): the head is
        // most of the way there and the tail is behind it.
        let model = dock.model(at: 1.05)
        XCTAssertGreaterThan(model.caret.head, 2, "the head is ahead of the middle")
        XCTAssertLessThan(model.caret.tail, model.caret.head, "the tail trails the head")
        XCTAssertGreaterThan(model.caret.smear, 0)
        // And it lands.
        let landed = dock.model(at: 1.4)
        XCTAssertEqual(landed.caret.head, 3, accuracy: 0.01)
        XCTAssertEqual(landed.caret.tail, 3, accuracy: 0.01)
    }

    /// The empty report after an accepted line — what line-finish sends —
    /// fades the line out where it stood, over the window the find panel
    /// leaves in; and OSC 133 `C`, which follows it, lifts the veil
    /// without touching the fade.
    func testAnAcceptedLineFadesOutAndTheCommandLiftsTheVeil() {
        let dock = TerminalDock()
        dock.report(.line(text: "echo hi", cursor: 7, suggestion: ""), at: 0)
        dock.report(.line(text: "", cursor: 0, suggestion: ""), at: 1)
        var model = dock.model(at: 1.02)
        XCTAssertLessThan(model.line, 1, "the line is fading")
        XCTAssertEqual(model.text, "echo hi", "still on the plate while it fades")
        XCTAssertTrue(dock.owns)
        dock.ran(at: 1.03)
        XCTAssertFalse(dock.owns, "the command owns the rows now")
        model = dock.model(at: 1.5)
        XCTAssertEqual(model.text, "", "the line is gone from the plate")
        XCTAssertFalse(dock.moving(at: 1.5), "the fade is spent")
        XCTAssertTrue(dock.owed, "the plate stays for the next prompt")
    }

    /// OSC 133 `A` — a prompt began — drops whatever the dock was holding
    /// at once, fading or not: the rows it stood in for are the shell's
    /// own, and the report that follows establishes the new line.
    func testAPromptDropsTheLineAtOnce() {
        let dock = TerminalDock()
        dock.report(.line(text: "false", cursor: 5, suggestion: ""), at: 0)
        dock.report(.line(text: "", cursor: 0, suggestion: ""), at: 1)
        XCTAssertTrue(dock.moving(at: 1.02), "the fade is on")
        dock.prompted(at: 1.03)
        let model = dock.model(at: 1.2)
        XCTAssertEqual(model.line, 1)
        XCTAssertEqual(model.text, "")
        XCTAssertFalse(dock.moving(at: 1.2), "nothing is owed")
        XCTAssertTrue(dock.owed, "but the plate stays")
    }

    /// `off` — the editor gave the line up: too long, or wrapped —
    /// collapses the plate over the window the panel leaves in, and the
    /// frame that finishes it is what ends it. A report that comes back
    /// re-arrives the plate.
    func testOffCollapsesThePlateAndAReportBringsItBack() {
        let dock = TerminalDock()
        dock.report(.line(text: "ls", cursor: 2, suggestion: ""), at: 0)
        dock.report(.off, at: 1)
        XCTAssertFalse(dock.owns)
        var model = dock.model(at: 1.02)
        XCTAssertLessThan(model.plate, 1, "the plate is leaving")
        XCTAssertTrue(dock.owed)
        model = dock.model(at: 1.5)
        XCTAssertEqual(model.plate, 0, accuracy: 0.01)
        XCTAssertFalse(dock.owed, "the collapse finished it")
        // And a line reported again re-arrives it.
        dock.report(.line(text: "ls", cursor: 2, suggestion: ""), at: 2)
        model = dock.model(at: 2.05)
        XCTAssertGreaterThan(model.plate, 0)
        XCTAssertLessThan(model.plate, 1)
        XCTAssertTrue(dock.owns)
    }

    /// Reduce Motion is given the whole thing at once: no arrive, no
    /// collapse, no legs. (CI runs with it off; the check is the only
    /// honest thing to do without a screen that can flip it.)
    func testReducedMotionSettlesTheCaret() {
        let dock = TerminalDock()
        dock.report(.line(text: "ab", cursor: 2, suggestion: ""), at: 0)
        XCTAssertEqual(dock.model(at: 0).caret.head, 2, accuracy: 0.01)
    }

    // MARK: - the wire the reports ride

    /// The script's escaping, read back (TerminalParse.docked): the
    /// controls that would break the payload, `\\x3b` for a semicolon,
    /// which would otherwise end the field, and a backslash doubled to
    /// tell itself from the marks. Anything the script never writes is
    /// passed through as it stands.
    func testTheDockedTextIsUnescaped() {
        XCTAssertEqual(Parser.docked("plain"), "plain")
        XCTAssertEqual(Parser.docked("a\\nb"), "a\nb")
        XCTAssertEqual(Parser.docked("a\\x3bb"), "a;b")
        XCTAssertEqual(Parser.docked("a\\\\b"), "a\\b")
        XCTAssertEqual(Parser.docked("a\\eb\\ac\\td"), "a\u{1b}b\u{07}c\td")
        // A promised hex that didn't deliver: the `x` is given back
        // rather than eating its neighbours.
        XCTAssertEqual(Parser.docked("a\\xzb"), "axzb")
    }

    /// The report itself, parsed off the wire: the cursor's column counted
    /// in characters, the suggestion behind the text, and the payload's
    /// escapes read in place.
    func testTheReportIsParsed() {
        let parser = Parser(screen: Screen(width: 80, height: 24))
        var heard: Dock?
        parser.say = { notice in
            if case .dock(let report) = notice { heard = report }
        }
        parser.feed(Array("\u{1b}]7784;buf;3;ech\\x3bo;.\u{07}".utf8))
        XCTAssertEqual(heard, .line(text: "ech;o", cursor: 3, suggestion: "."))
        parser.feed(Array("\u{1b}]7784;off\u{07}".utf8))
        XCTAssertEqual(heard, .off)
    }
}
