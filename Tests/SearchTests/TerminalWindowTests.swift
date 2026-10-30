import XCTest
@testable import Search

/// The whole path the app takes — a real shell in a real window, drawn by
/// the view — to say where a tab that shows nothing goes wrong.
@MainActor
final class TerminalWindowTests: XCTestCase {
    /// A live shell in a window paints its prompt: the scene the view draws
    /// says so, and the frame the renderer was last handed says so too.
    func testLiveShellSceneCarriesThePrompt() async throws {
        let terminal = Terminal(command: TerminalCommand(
            argv: ["/bin/zsh", "-f", "-c", "echo PROMPT-HERE; sleep 5"]
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        // Out of sight when the test ends, not closed: a window a probe put
        // on screen is still visible to every other suite's teardown,
        // which asserts that nothing is.
        addTeardownBlock { window.orderOut(nil) }

        // The shell's words may land before anything is listening for them,
        // so the scene itself is polled — the words are what matter, and
        // they stay on the screen once they are there.
        var scene: Terminal.Scene?
        for _ in 0..<100 {
            scene = terminal.scene(scroll: 0)
            if scene?.lines.contains(where: { (row: Row) in row.text.contains("PROMPT-HERE") }) == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let found = try XCTUnwrap(scene, "the shell's scene exists")
        let texts: [String] = found.lines.map { (row: Row) in row.text }
        XCTAssertEqual(texts.filter { $0.contains("PROMPT-HERE") }.count, 1, "the prompt line reached the scene: \(texts)")

        // The view's own drawing of that scene: the cells the renderer was
        // handed carry the letters, not spaces.
        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(view.bounds, scale: view.window?.backingScaleFactor ?? 1)
        paint.refresh(scene: found, selection: nil, strong: false)
        let texture = try XCTUnwrap(paint.snapshot())
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let theme = TerminalDraw.Theme.current()
        var painted = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let gap = abs(Double(pixels[offset]) / 255 - Double(theme.ground.x))
                + abs(Double(pixels[offset + 1]) / 255 - Double(theme.ground.y))
                + abs(Double(pixels[offset + 2]) / 255 - Double(theme.ground.z))
            if gap > 0.3 { painted += 1 }
        }
        XCTAssertGreaterThan(painted, 200, "the words of the prompt painted; painted \(painted)")

        terminal.stop()
    }

    /// A shell that marks its prompts (OSC 133) can be walked between them:
    /// ⌘↑ lifts to the command before the one at the top of the frame, ⌘↓
    /// comes back down to it, and with no block that way either key goes as
    /// far as there is to go.
    func testTheShellsPromptsAreWalkedWithTheKeys() async throws {
        // Forty commands, each one marking its prompt and printing a line,
        // so that most of them are in the scrollback by the time it ends.
        let script = "for i in $(seq 1 40); do printf '\\033]133;A\\007$ '; "
            + "printf 'line %s\\n' $i; printf '\\033]133;C\\007'; printf '\\033]133;D;0\\007'; done; sleep 5"
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c", script]))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }

        // The marks arrive with the output, so the blocks are polled for:
        // what is waited on is the scrollback having something to walk.
        var blocks = 0
        for _ in 0..<100 {
            blocks = terminal.look(scroll: 0) { screen, _ in screen.blocks.count } ?? 0
            if blocks >= 20 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(blocks, 20, "the shell marked its prompts; counted \(blocks) blocks")
        XCTAssertEqual(view.lift, 0, "a frame starts on the live screen, the newest output")

        view.jumpToPrompt(forward: false)
        let up = view.lift
        XCTAssertGreaterThan(up, 0, "⌘↑ lifted the frame into the scrollback")

        view.jumpToPrompt(forward: false)
        XCTAssertGreaterThan(view.lift, up, "and again goes on to the command before that one")

        view.jumpToPrompt(forward: true)
        XCTAssertEqual(view.lift, up, "⌘↓ comes back down to the prompt it left")

        var steps = 0
        while view.lift > 0, steps < 100 {
            view.jumpToPrompt(forward: true)
            steps += 1
        }
        XCTAssertEqual(view.lift, 0, "and goes on down until the live screen is back")
        view.jumpToPrompt(forward: true)
        XCTAssertEqual(view.lift, 0, "where there is nothing below, it stays put")

        terminal.stop()
    }

    /// A program that asked for the mouse hears a click where it is, in the
    /// unit it asked for: 1006 counts cells of the grid, and 1016 counts
    /// pixels of the frame — the finer unit being the whole of what 1016 is
    /// for. The click is aimed at the frame's first cell, which is the
    /// corner the first row is drawn at, and the program echoes back what
    /// it heard.
    ///
    /// The unit is what this pins: a report in cells for a program that
    /// asked for pixels, or the other way round, is a program drawing in
    /// the wrong place, and nothing else in the suite would notice.
    func testAClickIsHeardWhereItIsInTheUnitTheProgramAskedFor() async throws {
        // 1000 with no encoding asked for: the old one, three bytes with 32
        // added — the code, then the column and the row from one.
        let old = try await echoOfAClick(mode: 1000, asking: .legacy, into: 4)
        XCTAssertEqual(
            old.said, echoed("\u{1b}[M !!"),
            "the first cell of the frame, in the old encoding — the scene was \(old.scene)"
        )

        // The same click with SGR asked for: the numbers written out.
        let cells = try await echoOfAClick(mode: 1006, asking: .sgr, into: 4)
        XCTAssertEqual(
            cells.said, echoed("\u{1b}[<0;1;1M"),
            "the same cell, in SGR's numbers — the scene was \(cells.scene)"
        )

        // And with 1016: SGR's bytes, counting pixels of the frame rather
        // than cells — the four points in, at the scale it is drawn at.
        let pixels = try await echoOfAClick(mode: 1016, asking: .sgrPixels, into: 4)
        let at = Int(4 * pixels.scale) + 1
        XCTAssertEqual(
            pixels.said, echoed("\u{1b}[<0;\(at);\(at)M"),
            "and the same click in pixels of the frame — the scene was \(pixels.scene)"
        )
    }

    /// The caret's own rect — the one the input method puts its candidate
    /// window against — is where the caret is drawn: the first rows of the
    /// grid, which are the top of the view, not the rows that far up from
    /// the other end.
    func testTheCaretsRectIsWhereTheCaretIsDrawn() async throws {
        let terminal = Terminal(command: TerminalCommand(
            argv: ["/bin/zsh", "-f", "-c", "printf 'HERE\\r\\n'; sleep 5"]
        ))
        defer { terminal.stop() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }

        var there = false
        for _ in 0..<100 {
            there = terminal.scene(scroll: 0)?.lines.contains { (row: Row) in row.text.contains("HERE") } == true
            if there { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(there, "the shell printed its line")

        let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let frame = view.convert(view.bounds, to: nil)
        XCTAssertFalse(rect.isEmpty, "the caret has a rect: \(rect)")
        XCTAssertGreaterThan(
            rect.minY, frame.midY,
            "the caret is on the first rows, which are drawn at the top of the frame — the rect was \(rect) in \(frame)"
        )
        XCTAssertLessThanOrEqual(rect.maxY, frame.maxY, "and inside the frame")
    }

    /// What the program on the other end heard when the pointer was put
    /// `into` points inside the top left of the grid, with the mouse asked
    /// for in `mode` — the encoding the program is left in being `asking`.
    /// The shell is left echoing what it reads — `cat -v`, which writes the
    /// bytes it cannot print as a caret and a letter — so the report comes
    /// back as text on the screen and is read from there.
    private func echoOfAClick(mode: Int, asking: MouseReport.Format, into: CGFloat) async throws
        -> (said: String, scale: CGFloat, scene: [String]) {
        let terminal = Terminal(command: TerminalCommand(argv: [
            "/bin/zsh", "-f", "-c",
            "stty raw -echo; printf '\\033[?1000;\(mode)h'; printf 'READY\\r\\n'; exec cat -v",
        ]))
        defer { terminal.stop() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }

        func read() -> [String] {
            guard let seen = terminal.scene(scroll: 0) else { return [] }
            return seen.lines.map { (row: Row) in row.text }
        }

        // The shell has to be up, and the mode has to have been read — the
        // second is the parser's answer, since the view keeps the last
        // reading rather than asking the screen itself.
        var scene = read()
        for _ in 0..<100 {
            scene = read()
            let up = scene.contains { $0.contains("READY") }
            let on = terminal.look(scroll: 0) { screen, _ in screen.mouseFormat } == asking
            if up, on { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(scene.contains { $0.contains("READY") }, "the shell came up — the scene was \(scene)")
        // The mode reaches the view as one of a frame's, which the terminal
        // hands over when it has a frame to hand over.
        try await Task.sleep(nanoseconds: 200_000_000)

        // The top left of the grid in the window's own terms, so that the
        // point means the same whichever way the view's own y runs: the
        // frame's top corner, the room it leaves round the grid, and then
        // in a little.
        let frame = view.convert(view.bounds, to: nil)
        let at = NSPoint(
            x: frame.minX + TerminalDraw.inset + into,
            y: frame.maxY - TerminalDraw.inset - into
        )
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: at, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        view.mouseDown(with: click)

        // The report is the only thing on the screen with an escape in it:
        // the modes the shell set went down the terminal rather than up.
        var said = ""
        for _ in 0..<100 {
            scene = read()
            if let line = scene.first(where: { $0.contains("^[[") }) {
                said = line.trimmingCharacters(in: .whitespaces)
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return (said, window.backingScaleFactor, scene)
    }

    /// What the shell shows for the bytes a program was handed: every byte
    /// it cannot print, the escape among them, as a caret and a letter.
    private func echoed(_ bytes: String) -> String {
        bytes.replacingOccurrences(of: "\u{1b}", with: "^[")
    }
}
