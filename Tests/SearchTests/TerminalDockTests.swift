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
        XCTAssertEqual(model.plate, 1, accuracy: 0.01, "the read that begins the plate's leave still shows it whole")
        // No invitation hovering under a running command: the plate
        // leaves with the line it held.
        model = dock.model(at: 1.55)
        XCTAssertLessThan(model.plate, 1, "the plate leaves in its turn")
        XCTAssertTrue(dock.moving(at: 1.56), "the leave owes its frames")
        XCTAssertFalse(dock.moving(at: 1.7), "the leave is spent")
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
        var model = dock.model(at: 1.2)
        XCTAssertEqual(model.line, 1)
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(model.plate, 1, accuracy: 0.01, "the read that begins the leave still shows it whole")
        model = dock.model(at: 1.25)
        XCTAssertLessThan(model.plate, 1, "the plate leaves — the next prompt's report re-arrives it")
        XCTAssertTrue(dock.moving(at: 1.26), "the leave owes its frames")
        XCTAssertFalse(dock.moving(at: 1.4), "the leave is spent")
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

    // MARK: - the blink

    /// Metalterm's blink, on the dock's own two clocks: solid while the
    /// person types and for half a second after the last keystroke; a
    /// sine for ten seconds of idleness; solid again once they have well
    /// and truly gone — a solid caret most of the time is what "doesn't
    /// blink constantly" means.
    func testTheCaretIsSolidWhileTypingAndAfterTenSecondsOfIdleness() {
        let was = TerminalLook.blinks
        TerminalLook.blinks = true
        defer { TerminalLook.blinks = was }
        let dock = TerminalDock()
        dock.report(.line(text: "ec", cursor: 2, suggestion: ""), at: 10)
        // Typing: solid, every frame of it.
        XCTAssertTrue(dock.blink(at: 10.01), "solid while the line is being typed")
        XCTAssertTrue(dock.blink(at: 10.49), "solid for half a second after")
        // The sine: hidden on part of its cycle — 1.8263637 s a turn —
        // which is the difference between a blink and a light that never
        // goes out.
        var hidden = false
        var shown = false
        for step in stride(from: 10.6, through: 13.0, by: 0.05) {
            if dock.blink(at: step) { shown = true } else { hidden = true }
        }
        XCTAssertTrue(hidden, "the sine hides the caret on part of its cycle")
        XCTAssertTrue(shown, "and shows it on the rest")
        // Left alone: solid again, and the clock is spent.
        XCTAssertTrue(dock.blink(at: 10 + 10.5), "solid after ten seconds of idleness")
        XCTAssertFalse(dock.blinkClock(at: 10 + 10.5), "no frames owed for a caret that gave up")
        // From the keystroke itself the clock is kept: the moment
        // typing-solid ends — half a second in — is a frame nobody else
        // owes.
        XCTAssertTrue(dock.blinkClock(at: 10.05), "the clock runs from the keystroke")
    }

    /// A caret the person asked not to blink is solid plainly — and a
    /// caret on a leg never blinks, because a moving thing is a visible
    /// thing. (Reduced Motion is the system's own setting; a test cannot
    /// reach in and turn it, and the branch is the same `||`.)
    func testTheCaretBlinkFollowsTheSettingsAndTheLegs() {
        let blinks = TerminalLook.blinks
        TerminalLook.blinks = false
        defer { TerminalLook.blinks = blinks }
        let dock = TerminalDock()
        dock.report(.line(text: "ec", cursor: 2, suggestion: ""), at: 10)
        XCTAssertTrue(dock.blink(at: 12), "no blink asked for, no blink drawn")
        XCTAssertFalse(dock.blinkClock(at: 12), "and no clock kept for it")

        // A leg: the caret is on its way somewhere, and the blink holds
        // off until it lands.
        dock.report(.line(text: "echo hi", cursor: 7, suggestion: ""), at: 11)
        XCTAssertTrue(dock.blink(at: 11.01), "a caret on a leg is visible")
    }

    // MARK: - the alternate screen

    /// A full-screen program takes the frame and the dock is gone at
    /// once — no fade, because the program's own first frame is already
    /// redrawing everything the plate stood over — and the report that
    /// follows its exit re-arrives the plate.
    func testTheAlternateScreenSuspendsTheDockAndAReportBringsItBack() {
        let dock = TerminalDock()
        dock.report(.line(text: "nvim", cursor: 4, suggestion: ""), at: 0)
        XCTAssertTrue(dock.owed)
        dock.suspend()
        XCTAssertFalse(dock.owns)
        XCTAssertFalse(dock.owed, "the plate is gone at once")
        XCTAssertFalse(dock.moving(at: 0.01), "nothing is owed a frame")
        XCTAssertEqual(dock.model(at: 0.02).plate, 0, "and nothing is drawn")
        // The program let go: the prompt's report re-arrives the plate.
        dock.report(.line(text: "", cursor: 0, suggestion: ""), at: 5)
        XCTAssertTrue(dock.owed)
        XCTAssertGreaterThan(dock.model(at: 5.01).plate, 0, "the plate is arriving again")
    }

    // MARK: - the plate while a command runs

    /// A command owns the rows while it runs, and the dock's invitation
    /// goes with the line: after the accepted line has faded out where it
    /// stood, the plate leaves too, and the next prompt's report brings
    /// it back.
    func testThePlateLeavesWhenACommandRunsAndReturnsWithTheNextPrompt() {
        let dock = TerminalDock()
        dock.report(.line(text: "cargo build", cursor: 11, suggestion: ""), at: 0)
        dock.report(.line(text: "", cursor: 0, suggestion: ""), at: 1)
        dock.ran(at: 1.02)
        // The line is fading, and the plate under it leaves with it: no
        // invitation hovering under a running command. The read that
        // notices the command owns the rows still shows the plate whole.
        var model = dock.model(at: 1.05)
        XCTAssertEqual(model.plate, 1, accuracy: 0.01, "the read that begins the leave shows it whole")
        model = dock.model(at: 1.08)
        XCTAssertLessThan(model.plate, 1, "the plate leaves with the fading line")
        XCTAssertFalse(dock.owns, "the command owns the rows")
        // Spent: the dock is gone.
        model = dock.model(at: 1.5)
        XCTAssertEqual(model.plate, 0, "the leave is spent")
        XCTAssertFalse(dock.owed)
        XCTAssertFalse(dock.moving(at: 1.5))
        // The next prompt: its report re-arrives the plate.
        dock.prompted(at: 2)
        dock.report(.line(text: "", cursor: 0, suggestion: ""), at: 2.01)
        model = dock.model(at: 2.02)
        XCTAssertGreaterThan(model.plate, 0, "the plate is back for the prompt")
        XCTAssertLessThan(model.plate, 1, "arriving, not popped")
        XCTAssertTrue(dock.owns)
    }

    /// A command run with no line held at all (a Ctrl-C at an empty
    /// prompt, or a widget that never reported) still leaves the plate
    /// in its turn: the read that notices the command owns the rows
    /// begins the leave, and there is nothing left to fade first.
    func testACommandRunWithNoLineTakesThePlateWithIt() {
        let dock = TerminalDock()
        dock.report(.line(text: "", cursor: 0, suggestion: ""), at: 0)
        XCTAssertEqual(dock.model(at: 0.1).plate, 1, "the plate is up at the prompt")
        dock.ran(at: 0.2)
        var model = dock.model(at: 0.25)
        XCTAssertEqual(model.plate, 1, accuracy: 0.01, "the read that begins the leave still shows it whole")
        model = dock.model(at: 0.28)
        XCTAssertLessThan(model.plate, 1, "the plate leaves with nothing to fade")
        XCTAssertTrue(dock.moving(at: 0.285), "the plate's leave is still walking")
        XCTAssertFalse(dock.owns)
    }
}