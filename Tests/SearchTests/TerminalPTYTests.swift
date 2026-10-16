import XCTest
@testable import Search

/// The terminal with a program behind it: a real one, on a real pseudo-
/// terminal, doing what real ones do — writing, reading back what it was
/// written, ending, and telling the truth about all three. Hermetic as
/// the rest: nothing here touches the Store.
@MainActor
final class TerminalPTYTests: XCTestCase {
    private func runUntilEnded(_ command: TerminalCommand, timeout: TimeInterval = 10) -> (Terminal, String) {
        let ended = XCTestExpectation(description: "program ended")
        var saw = ""
        let terminal = Terminal(command: command)
        terminal.onEnded = { _, _ in ended.fulfill() }
        terminal.onDraw = { [weak terminal] _, _ in
            guard let scene = terminal?.scene(scroll: 0) else { return }
            saw = scene.lines.map(\.text).joined(separator: "\n")
        }
        wait(for: [ended], timeout: timeout)
        return (terminal, saw)
    }

    func testRunsACommandAndReportsItsExit() {
        let (terminal, saw) = runUntilEnded(
            TerminalCommand(argv: ["/bin/sh", "-c", "printf 'hello pty'; exit 7"]))
        XCTAssertEqual(terminal.exit, 7)
        XCTAssertTrue(saw.contains("hello pty"))
        XCTAssertEqual(terminal.named, "printf 'hello pty'; exit 7", "no title set: the command's tail")
    }

    func testExitZeroAndAShellQuestionAnswered() {
        let (terminal, saw) = runUntilEnded(
            TerminalCommand(argv: ["/bin/sh", "-c", "printf '%s' \"${TERM_PROGRAM?}\"; echo; stty size; exit 0"]))
        XCTAssertEqual(terminal.exit, 0)
        XCTAssertTrue(saw.contains("Search"), "the terminal is TERM_PROGRAM=Search")
        XCTAssertTrue(saw.contains("24 80"), "stty reads the winsize the spawn set")
    }

    func testSendsInputAndReadsItBack() {
        let replied = XCTestExpectation(description: "the program read what was sent")
        var saw = ""
        let terminal = Terminal(
            command: TerminalCommand(argv: ["/bin/sh", "-c", "read line; printf 'back:%s' \"$line\"; exit 0"]))
        terminal.onDraw = { [weak terminal] _, _ in
            guard let scene = terminal?.scene(scroll: 0) else { return }
            saw = scene.lines.map(\.text).joined(separator: "\n")
            if saw.contains("back:") { replied.fulfill() }
        }
        terminal.send("yo\n")
        wait(for: [replied], timeout: 10)
        XCTAssertTrue(saw.contains("back:yo"))
    }

    /// The shell's own marks (OSC 133) come back as the frame's blocks: a
    /// command that failed leaves its span in the gutter, red (see
    /// TerminalDraw, TerminalGrid).
    func testMarksACommandsSpanAndFailure() {
        let (terminal, _) = runUntilEnded(
            TerminalCommand(argv: ["/bin/sh", "-c", "printf '\u{1b}]133;A\u{7}hi\u{1b}]133;C\u{7}\u{1b}]133;D;7\u{7}'"]))
        let scene = terminal.scene(scroll: 0)
        XCTAssertEqual(scene?.marks, [
            Terminal.Scene.Mark(row: 0, span: 1, failed: true),
        ], "a block from its prompt to its end, failed: exit 7")
    }

    /// A command that went fine leaves the gutter alone: a stripe under
    /// every finished block reads as a stray vertical line once the output
    /// is tall (the drawing bug a full `ls` screen used to wear).
    func testMarksLeaveASuccessfulCommandAlone() {
        let (terminal, _) = runUntilEnded(
            TerminalCommand(argv: ["/bin/sh", "-c", "printf '\u{1b}]133;A\u{7}hi\u{1b}]133;C\u{7}\u{1b}]133;D;0\u{7}'"]))
        let scene = terminal.scene(scroll: 0)
        XCTAssertEqual(scene?.marks, [], "a finished, successful command marks nothing")
    }

    func testEndsAStubbornProgramByEscalation() {
        let started = XCTestExpectation(description: "the program put its traps up")
        let ended = XCTestExpectation(description: "program ended by force")
        let terminal = Terminal(
            command: TerminalCommand(argv: ["/bin/sh", "-c", "printf started; trap '' HUP TERM; sleep 30; exit 0"]))
        // Wait until the program says it has started — only then are its
        // traps up, and the escalation has something stubborn to beat.
        terminal.onDraw = { [weak terminal] _, _ in
            guard let scene = terminal?.scene(scroll: 0) else { return }
            if scene.lines.map(\.text).joined(separator: "\n").contains("started") {
                started.fulfill()
            }
        }
        wait(for: [started], timeout: 10)
        terminal.onEnded = { exit, byHand in
            XCTAssertTrue(byHand, "the exit was Search's doing")
            XCTAssertEqual(exit, -9, "the only way past traps is the kill")
            ended.fulfill()
        }
        terminal.stop()
        wait(for: [ended], timeout: 10)
        XCTAssertEqual(terminal.exit, -9)
    }

    func testSpawnFailureReportsMinusOne() {
        let terminal = Terminal(
            command: TerminalCommand(argv: ["/no/such/program", "here"]))
        XCTAssertEqual(terminal.exit, -1)
        XCTAssertNil(terminal.onDraw)
    }
}
