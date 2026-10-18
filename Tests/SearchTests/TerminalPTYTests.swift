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
            saw = scene.text
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
            saw = scene.text
            if saw.contains("back:") { replied.fulfill() }
        }
        terminal.send("yo\n")
        wait(for: [replied], timeout: 10)
        XCTAssertTrue(saw.contains("back:yo"))
    }

    /// The clear ⌘K has in a terminal, asked by hand (TerminalView's
    /// clearBuffer is the view's way of it): the screen and the
    /// scrollback wiped at a stroke — ED 3 then ED 2 — where a shell's
    /// own `clear` only ever reaches for the screen.
    func testClearTakesTheScrollbackWithTheScreen() {
        let filled = XCTestExpectation(description: "the program's lines went past the screen")
        let terminal = Terminal(
            command: TerminalCommand(
                argv: ["/bin/sh", "-c", "i=0; while [ $i -lt 60 ]; do echo line; i=$((i+1)); done; sleep 30"]))
        terminal.onDraw = { [weak terminal] _, _ in
            guard let terminal else { return }
            let kept = terminal.look(scroll: 0) { screen, _ in screen.back.count } ?? 0
            guard kept > 20 else { return }
            filled.fulfill()
        }
        wait(for: [filled], timeout: 10)
        terminal.onDraw = nil

        terminal.clear()
        let after = terminal.look(scroll: 0) { screen, _ in
            (screen.back.count, screen.rows.map(\.text))
        }
        XCTAssertEqual(after?.0, 0, "the scrollback went with the screen")
        XCTAssertTrue(after?.1.allSatisfy(\.isEmpty) ?? false, "and the screen is blank again")

        terminal.stop()
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
            if scene.text.contains("started") {
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

    /// Whether a process is running, asked of the system rather than of the
    /// screen: what the interrupt did to the command is a fact about it.
    private func isRunning(_ needle: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return out.split(separator: "\n").contains { $0.contains(needle) }
    }

    /// Waits for a fact rather than for a duration: a poll until `check` holds,
    /// so the wait is as long as the thing waited for and no longer.
    private func wait(until check: () -> Bool, seconds: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return check()
    }

    /// ^C has somewhere to go only when the session owns a controlling
    /// terminal: with none, there is no foreground group for the kernel to
    /// signal, and the interrupt reaches the tty and stops there. A shell that
    /// never asks for the terminal itself — zsh does not, sh and bash do —
    /// still gets one (see Terminal.spawn), so its commands can be stopped.
    func testInterruptStopsACommandInAShellThatNeverAsksForTheTerminal() {
        // A duration nothing else in this suite wears, so "still running" is
        // about this command and nothing else.
        let marker = "sleep 313.37"
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-i"]))
        let up = XCTestExpectation(description: "the shell echoed the command")
        var echoed = false
        terminal.onDraw = { [weak terminal] _, _ in
            guard !echoed, let scene = terminal?.scene(scroll: 0) else { return }
            if scene.text.contains(marker) {
                echoed = true
                up.fulfill()
            }
        }
        terminal.send(marker + "\n")
        wait(for: [up], timeout: 10)
        // The echo is the tty's; the command itself starts once the shell has
        // read the line, forked it, and handed it the terminal.
        XCTAssertTrue(wait { isRunning(marker) }, "the command started")
        // And the handover of the terminal comes after the fork: interrupting
        // inside that window is a race, not the thing being tested.
        Thread.sleep(forTimeInterval: 0.5)

        terminal.send("\u{03}")
        // The signal is the kernel's; the command's death follows it.
        XCTAssertTrue(
            wait { !isRunning(marker) },
            "^C stopped the command: the session has a foreground group to signal")
        terminal.stop()
    }

    func testSpawnFailureReportsMinusOne() {
        let terminal = Terminal(
            command: TerminalCommand(argv: ["/no/such/program", "here"]))
        XCTAssertEqual(terminal.exit, -1)
        XCTAssertNil(terminal.onDraw)
    }
}
