import AppKit
import XCTest

@testable import Search

/// The four things the chat learned from orbit-pi after the talk itself:
/// how full the context window is, whether the agent is still working,
/// which lines of a tool's output are there now, and putting a row on the
/// pasteboard.
///
/// Every number here comes from something an agent wrote down. Nothing is
/// estimated, and nothing is guessed from the screen — the same rule the
/// talk reader follows, because a picture of a token count is not a count.
@MainActor
final class AgentContextTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func root(_ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-context-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, body) in files {
            try? body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        roots.append(root)
        return root
    }

    // MARK: - where a window comes from

    /// The number a model's own name carries. `[1m]` is how a router names
    /// the million-token variant of a model, and it is written by the CLI
    /// itself, so it is read rather than guessed.
    func testAWindowInAModelsNameIsRead() {
        XCTAssertEqual(AgentModels.window(of: "group/auto[1m]"), 1_000_000)
        XCTAssertEqual(AgentModels.window(of: "auto/deepseek-v4.1-flash[1m]"), 1_000_000)
        XCTAssertEqual(AgentModels.window(of: "some-model[128k]"), 128_000)
        XCTAssertEqual(AgentModels.window(of: "some-model[200K]"), 200_000)
    }

    /// A name that says nothing leaves the ring off. A denominator invented
    /// from a model's family would be a measurement that is not one.
    func testANameThatSaysNothingHasNoWindow() {
        XCTAssertNil(AgentModels.window(of: "k3.1-pro"))
        XCTAssertNil(AgentModels.window(of: "claude-opus-4-1-20250805"))
        XCTAssertNil(AgentModels.window(of: "model[0m]"))
        XCTAssertNil(AgentModels.window(of: "model[m]"))
        XCTAssertNil(AgentModels.window(of: "model[]"))
        XCTAssertNil(AgentModels.window(of: "model[1g]"))
        XCTAssertNil(AgentModels.window(of: "model[1m"))
    }

    /// pi states the window per model in its catalog, and the row carries
    /// it so the chat does not have to read the catalog twice.
    func testPisRowsCarryTheirWindow() {
        let home = root([
            "models.json": """
            {"providers": {"magpie": {"models": [
              {"id": "auto", "name": "Auto", "contextWindow": 1048576},
              {"id": "small", "name": "Small", "contextWindow": 195000}
            ]}}}
            """
        ])
        let rows = AgentModels.rows(for: .pi, root: home)
        XCTAssertEqual(rows.first { $0.value == "magpie/auto" }?.window, 1_048_576)
        XCTAssertEqual(rows.first { $0.value == "magpie/small" }?.window, 195_000)
        XCTAssertTrue(rows.first { $0.value == "magpie/auto" }?.note.contains("context") == true)
    }

    /// Claude's rows carry the window its model ids state, and none when
    /// they state none.
    func testClaudesRowsCarryTheWindowTheirNamesState() {
        let home = root([
            "settings.json": """
            {"modelPicker": {"options": [
              {"label": "Auto", "model": "group/auto[1m]"},
              {"label": "Pro", "model": "k3.1-pro"}
            ]}}
            """
        ])
        let rows = AgentModels.rows(for: .claude, root: home)
        XCTAssertEqual(rows.first { $0.value == "group/auto[1m]" }?.window, 1_000_000)
        XCTAssertNil(rows.first { $0.value == "k3.1-pro" }?.window)
    }

    /// Codex writes the window into the run's own record, once a turn. It
    /// is the one agent that does, which is why the chat reads it there
    /// rather than keeping a table of models that would go stale.
    func testCodexStatesItsWindowInTheRecord() {
        var log = ChatLog(agent: .codex)
        log.read(Data("""
        {"type":"turn_context","payload":{"model":"gpt-5-codex","model_context_window":258400}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}

        """.utf8))
        XCTAssertEqual(log.window, 258_400)
        XCTAssertEqual(log.turns.count, 1)
    }

    // MARK: - the count

    /// The count is the newest turn's input, cache included, plus what it
    /// answered — the conversation as it stands in the window, not a sum
    /// over every turn that carried the same words.
    func testWhatIsSpentIsTheNewestTurnsWindowNotASum() {
        var log = ChatLog(agent: .claude)
        log.read(Data("""
        {"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"one"}],"usage":{"input_tokens":1000,"output_tokens":50}}}
        {"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"two"}],"usage":{"input_tokens":2000,"cache_read_input_tokens":9000,"output_tokens":80}}}

        """.utf8))
        XCTAssertEqual(log.turns.count, 1, "consecutive assistant words are one turn")
        XCTAssertEqual(log.spent, 2000 + 9000 + 80)
    }

    func testNothingSpentSaysNothing() {
        var log = ChatLog(agent: .claude)
        log.read(Data("""
        {"type":"user","message":{"role":"user","content":"hello"}}

        """.utf8))
        XCTAssertEqual(log.spent, 0)
    }

    // MARK: - the meter

    func testTheMeterReadsTheFractionAndSaysItInPercent() {
        XCTAssertEqual(ContextMeter.fraction(used: 500, window: 1000), 0.5)
        XCTAssertEqual(ContextMeter.fraction(used: 1500, window: 1000), 1, "a run past its window still fits the ring")
        XCTAssertNil(ContextMeter.fraction(used: 0, window: 1000), "nothing spent is not zero percent")
        XCTAssertNil(ContextMeter.fraction(used: 500, window: 0), "no window is not a full one")

        XCTAssertEqual(ContextMeter.percent(used: 500, window: 1000), "50%")
        XCTAssertEqual(ContextMeter.percent(used: 1, window: 1_000_000), "<1%")
        XCTAssertEqual(ContextMeter.percent(used: 0, window: 1000), "")
    }

    /// The colour says how bad it is before the arc's length does: the
    /// terminal's own ink, then a warning, then an error.
    func testTheMetersColourWarnsBeforeTheArcIsFull() {
        let ink = NSColor.white
        XCTAssertEqual(ContextMeter.tint(0.2, ink: ink), ink.withAlphaComponent(0.75))
        XCTAssertEqual(ContextMeter.tint(0.75, ink: ink), .systemOrange)
        XCTAssertEqual(ContextMeter.tint(0.95, ink: ink), .systemRed)
    }

    // MARK: - is it still going

    /// Working is read off the file's own shape: a question nobody has
    /// answered, a tool it reached for, a thought it is in the middle of.
    /// The agent's own words last means it finished.
    func testWorkingIsReadOffTheFilesShape() {
        var log = ChatLog(agent: .claude)
        XCTAssertFalse(log.working, "an empty talk is not a working agent")

        log.read(Data("""
        {"type":"user","message":{"role":"user","content":"do the thing"}}

        """.utf8))
        XCTAssertTrue(log.working, "a question with no answer yet is work")

        log.read(Data("""
        {"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}

        """.utf8))
        XCTAssertTrue(log.working, "a tool it reached for has not answered yet")

        log.read(Data("""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a b c"}]}}

        """.utf8))
        XCTAssertTrue(log.working, "a tool's answer is not the agent's own")

        log.read(Data("""
        {"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"done"}]}}

        """.utf8))
        XCTAssertFalse(log.working, "the agent's own words last means it finished")
    }

    // MARK: - a diff

    /// A hunk header makes it a diff, and the lines are coloured by what
    /// they do: added, removed, or already there.
    func testADiffIsColouredByWhatEachLineDoes() {
        let output = """
        diff --git a/x.swift b/x.swift
        --- a/x.swift
        +++ b/x.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        """
        let painted = Prose.diff(output, face: .monospacedSystemFont(ofSize: 11, weight: .regular),
                                 ink: .white)
        let drawn = try? XCTUnwrap(painted)
        XCTAssertNotNil(drawn)
        guard let drawn else { return }
        var colours: [String: NSColor] = [:]
        drawn.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: drawn.length)) {
            value, range, _ in
            let line = (drawn.string as NSString).substring(with: range)
                .trimmingCharacters(in: .newlines)
            if let colour = value as? NSColor { colours[line] = colour }
        }
        XCTAssertEqual(colours["+let b = 3"], NSColor.systemGreen.withAlphaComponent(0.82))
        XCTAssertEqual(colours["-let b = 2"], NSColor.systemRed.withAlphaComponent(0.82))
        XCTAssertEqual(colours[" let a = 1"], NSColor.white.withAlphaComponent(0.36))
        XCTAssertEqual(colours["+++ b/x.swift"], NSColor.white.withAlphaComponent(0.30))
    }

    /// Output that is not a diff keeps its own colour: a lone `+` in prose
    /// and a lone `---` are not a change.
    func testOutputThatIsNotADiffIsLeftAlone() {
        XCTAssertNil(Prose.diff("1 + 1 = 2\n", face: .systemFont(ofSize: 11), ink: .white))
        XCTAssertNil(Prose.diff("only added\n+one line\n", face: .systemFont(ofSize: 11), ink: .white))
        XCTAssertNil(Prose.diff("", face: .systemFont(ofSize: 11), ink: .white))
        // A removal and an addition together, with no hunk header, is
        // still a diff — that is what `git diff --no-index` on one line
        // looks like.
        XCTAssertNotNil(Prose.diff("-gone\n+here\n", face: .systemFont(ofSize: 11), ink: .white))
    }

    // MARK: - the paper and the composer

    /// The working row takes room under the talk, and gives it back.
    func testTheWorkingRowTakesRoomAndGivesItBack() {
        let paper = TerminalChatPaper()
        paper.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        paper.take(talkOf([
            ("user", "hello"),
            ("assistant", "hi there"),
        ]))
        let quiet = paper.written
        paper.beat(working: true)
        XCTAssertGreaterThan(paper.written, quiet, "the working row is a row")
        paper.beat(working: false)
        XCTAssertEqual(paper.written, quiet, "and it goes when the work does")
    }

    /// What the agent is doing, in the fewest words that are true.
    func testTheWorkingRowSaysWhatTheAgentIsDoing() {
        let paper = TerminalChatPaper()
        paper.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        paper.take(talkOf([("user", "run the tests")]))
        XCTAssertEqual(paper.workingWords, "Working")
        paper.beat(working: true)
        XCTAssertEqual(paper.workingWords, "Working")
    }

    /// Option-clicking a row puts the whole of it on the pasteboard.
    func testOptionClickCopiesTheRow() {
        let paper = TerminalChatPaper()
        paper.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        paper.take(talkOf([("user", "copy me please")]))
        var took: String?
        paper.copied = { took = $0 }
        // A press inside the first row, near the top of the paper. The
        // paper is unflipped and the talk starts at its top, so the first
        // row is a few points down from the top of the view.
        let point = NSPoint(x: 60, y: paper.bounds.height - 6)
        let spot = paper.bounds.height - point.y
        XCTAssertNotNil(paper.item(at: spot), "the first row is under the top of the paper")
        paper.mouseDown(with: click(at: point, option: true))
        XCTAssertEqual(took, "copy me please")
    }

    /// The composer's ring is drawn from the two numbers the agent's own
    /// records gave, and there is no ring when either is missing.
    func testTheComposerTakesTheWindowFromTheRowAndTheCountFromTheLog() {
        let plate = TerminalChatView()
        plate.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        plate.takeModels([
            AgentModels.Row(label: "Auto", value: "group/auto[1m]", note: "", window: 1_000_000),
            AgentModels.Row(label: "Small", value: "k3.1-pro", note: ""),
        ], current: "group/auto[1m]")
        XCTAssertEqual(plate.contextWindow, 1_000_000)

        plate.takeModels([
            AgentModels.Row(label: "Auto", value: "group/auto[1m]", note: "", window: 1_000_000),
            AgentModels.Row(label: "Small", value: "k3.1-pro", note: ""),
        ], current: "k3.1-pro")
        XCTAssertEqual(plate.contextWindow, 0, "a model whose name says nothing has no ring")

        plate.beat(working: true, used: 250_000)
        XCTAssertTrue(plate.working)
        XCTAssertEqual(plate.contextUsed, 250_000)
    }

    // MARK: - the cards

    /// Pressing the same thing twice must not stack two cards: a repeat
    /// refreshes the twin already up, so the second press is still seen
    /// even when the first is nearly gone.
    func testARepeatRefreshesTheCardInsteadOfStackingATwin() {
        var stack = AgentToasts()
        let first = stack.push(.success, "Copied", at: 100)
        let again = stack.push(.success, "Copied", at: 102)
        XCTAssertEqual(first, again)
        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(stack.items[0].revision, 1, "the life restarted")
        XCTAssertEqual(stack.items[0].born, 102, "from now, not from before")

        // A different word or a different body is a different card.
        stack.push(.success, "Copied", body: "a line", at: 103)
        XCTAssertEqual(stack.count, 2)
        stack.push(.info, "Copied", at: 104)
        XCTAssertEqual(stack.count, 3)
    }

    /// A burst of events must never bury the talk behind its own
    /// confirmations: the oldest card leaves instead.
    func testTheStackHasACeilingAndDropsTheOldest() {
        var stack = AgentToasts()
        var ids: [Int] = []
        for i in 0..<(AgentToasts.mostVisible + 2) {
            ids.append(stack.push(.info, "event \(i)", at: CFTimeInterval(i)))
        }
        XCTAssertEqual(stack.count, AgentToasts.mostVisible)
        XCTAssertEqual(stack.items.map(\.id), Array(ids.suffix(AgentToasts.mostVisible)))
    }

    /// Each kind holds for its own time, then fades. An error is read
    /// slower than a copy confirmation, and the order says so.
    func testEachKindHoldsForItsOwnTimeAndThenFades() {
        XCTAssertGreaterThan(AgentToast.Kind.error.ttl, AgentToast.Kind.warning.ttl)
        XCTAssertGreaterThan(AgentToast.Kind.warning.ttl, AgentToast.Kind.info.ttl)
        XCTAssertGreaterThan(AgentToast.Kind.info.ttl, AgentToast.Kind.success.ttl)

        var stack = AgentToasts()
        stack.push(.success, "done", at: 0)
        let toast = stack.items[0]
        // Still whole at the end of its hold, half faded halfway through
        // the fade, gone once the fade is over.
        XCTAssertEqual(toast.body(at: AgentToast.Kind.success.ttl), 1)
        XCTAssertEqual(toast.body(at: toast.dies - AgentToast.fade / 2), 0.5, accuracy: 0.01)
        XCTAssertEqual(toast.body(at: toast.dies), 0)
        XCTAssertFalse(stack.expire(at: toast.dies - 0.01), "not yet")
        XCTAssertTrue(stack.expire(at: toast.dies), "now")
        XCTAssertTrue(stack.isEmpty)
    }

    /// A stack with nothing in it needs no clock — which is why the layer
    /// only arms a timer while a card is up.
    func testAnEmptyStackHasNoNextDeath() {
        var stack = AgentToasts()
        XCTAssertNil(stack.nextDeath)
        stack.push(.info, "a", at: 10)
        XCTAssertEqual(stack.nextDeath, 10 + AgentToast.Kind.info.ttl + AgentToast.fade)
        stack.dismiss(stack.items[0].id)
        XCTAssertNil(stack.nextDeath)
    }

    // MARK: - the way back to the newest words

    /// The jump control appears only once the reader has left the tail: at
    /// the tail the newest words are already at the bottom edge, and a
    /// control there would point at itself.
    func testTheJumpControlAppearsOnlyAwayFromTheTail() {
        let paper = TerminalChatPaper()
        paper.frame = NSRect(x: 0, y: 0, width: 380, height: 120)
        paper.take(longTalk(20))
        XCTAssertGreaterThan(paper.written, paper.bounds.height, "the talk is taller than the view")
        XCTAssertNil(paper.jumpRect, "at the tail there is nowhere to go back to")

        paper.scrollWheel(with: wheel(delta: 120))
        XCTAssertNotNil(paper.jumpRect, "away from the tail, the way back is shown")
    }

    /// Something arriving while the reader is away is a fact worth saying:
    /// the control grows a second word, so the reader knows the talk moved
    /// on without them.
    func testNewWordsSayNewActivityAndFollowingAgainClearsIt() {
        let paper = TerminalChatPaper()
        paper.frame = NSRect(x: 0, y: 0, width: 380, height: 120)
        paper.take(longTalk(20))
        paper.scrollWheel(with: wheel(delta: 120))
        let plain = paper.jumpRect

        paper.take(longTalk(21))
        XCTAssertNotEqual(paper.jumpRect?.width, plain?.width, "the control says there is new activity")

        // Pressing it puts the newest words back under the eye.
        let jump = try? XCTUnwrap(paper.jumpRect)
        guard let jump else { return }
        paper.mouseDown(with: click(at: NSPoint(x: jump.midX, y: jump.midY), option: false))
        XCTAssertTrue(paper.isFollowing)
        XCTAssertEqual(paper.jumpRect?.width, nil, "following again takes the control away")
    }

    // MARK: - helpers

    /// A talk long enough to scroll: the same two lines, again and again.
    private func longTalk(_ turns: Int) -> ChatLog {
        var said: [(String, String)] = []
        for i in 0..<turns {
            said.append(("user", "question \(i)"))
            said.append(("assistant", String(repeating: "answer \(i) ", count: 8)))
        }
        return talkOf(said)
    }

    /// A real scroll event: the paper's wheel handler is what moves the
    /// talk, so the test drives the same door a trackpad does.
    private func wheel(delta: CGFloat) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                         wheel1: Int32(delta), wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    // MARK: - helpers

    /// A talk built by writing the agent's own records, so the tests use
    /// the same reader the pane does rather than a hand-made log.
    private func talkOf(_ said: [(String, String)]) -> ChatLog {
        var log = ChatLog(agent: .claude)
        var lines = ""
        for (role, words) in said {
            if role == "user" {
                lines += #"{"type":"user","message":{"role":"user","content":"\#(words)"}}"# + "\n"
            } else {
                lines += #"{"type":"assistant","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"\#(words)"}]}}"# + "\n"
            }
        }
        log.read(Data(lines.utf8))
        return log
    }

    private func click(at point: NSPoint, option: Bool) -> NSEvent {
        let flags: NSEvent.ModifierFlags = option ? .option : []
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }
}
