import AppKit
import XCTest

@testable import Search

/// What the talk looks like: machinery folded away, a person's words in a
/// bubble on the right, a footer under each turn, and a rail down the edge
/// that can put a turn back under your eyes.
///
/// Everything here is asserted against the paper's own shape and against
/// ink it actually painted — a formula that agrees with itself proves
/// nothing about what a person sees.
@MainActor
final class AgentTalkViewTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    // MARK: - building a talk

    private func block(_ role: String, _ blocks: String, _ stamp: String) -> String {
        #"{"type":"\#(role)","timestamp":"\#(stamp)","message":{"role":"\#(role)","content":[\#(blocks)]}}"#
    }

    private func text(_ words: String) -> String {
        #"{"type":"text","text":"\#(words)"}"#
    }

    private func thought(_ words: String) -> String {
        #"{"type":"thinking","thinking":"\#(words)"}"#
    }

    private func use(_ id: String, _ name: String, _ input: String) -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}"#
    }

    private func result(_ id: String, _ words: String, _ failed: Bool = false) -> String {
        #"{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(failed),"content":"\#(words)"}"#
    }

    private func log(_ lines: [String], agent: AgentTalk.Agent = .claude) -> ChatLog {
        var log = ChatLog(agent: agent)
        log.read(Data((lines.joined(separator: "\n") + "\n").utf8))
        return log
    }

    /// One turn of machinery: a thought, three tools, an answer.
    private func workingTurn(question: String, answer: String) -> [String] {
        [
            block("user", text(question), "2026-10-25T13:02:11.000Z"),
            block("assistant", [
                thought("The dock is redrawn from a paced clock."),
                use("t1", "Read", #"{"file_path":"Sources/Search/TerminalDock.swift"}"#),
            ].joined(separator: ","), "2026-10-25T13:02:19.000Z"),
            block("user", result("t1", "1\t// TerminalDock.swift"), "2026-10-25T13:02:20.000Z"),
            block("assistant", use("t2", "Grep", #"{"pattern":"present","path":"Sources/Search"}"#),
                  "2026-10-25T13:02:26.000Z"),
            block("user", result("t2", "TerminalPacer.swift:44: func present()"), "2026-10-25T13:02:27.000Z"),
            block("assistant", use("t3", "Bash", #"{"command":"swift test --filter TerminalDockTests"}"#),
                  "2026-10-25T13:02:48.000Z"),
            block("user", result("t3", "Executed 24 tests, with 0 failures"), "2026-10-25T13:03:09.000Z"),
            block("assistant", text(answer), "2026-10-25T13:03:14.000Z"),
        ]
    }

    /// A talk in a plate, laid out but never shown: enough for the paper to
    /// have a size and to paint.
    private func paper(_ log: ChatLog, height: CGFloat = 620, width: CGFloat = 560) -> TerminalChatPaper {
        let plate = TerminalChatView()
        plate.frame = NSRect(x: 0, y: 0, width: width, height: height)
        plate.take(log)
        plate.paper.follow()
        plate.layoutSubtreeIfNeeded()
        return plate.paper
    }

    private func click(_ paper: TerminalChatPaper, at point: NSPoint) {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: paper.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return XCTFail("no event") }
        paper.mouseDown(with: event)
    }

    /// A long talk: eight questions, each with machinery under it.
    private func longTalk() -> ChatLog {
        var lines: [String] = []
        for i in 1...8 {
            lines += workingTurn(question: "question number \(i)?",
                                 answer: "Answer number \(i), with enough words to take a line of its own.")
        }
        return log(lines)
    }

    // MARK: - ink

    private struct Ink {
        let rep: NSBitmapImageRep
        /// Pixels per point, so a test can talk in points.
        let scale: CGFloat

        /// The rows of the image that have any ink in the given column
        /// range, counted as bands — one band per line of words.
        func lines(from x: CGFloat, to end: CGFloat) -> Int {
            let low = max(0, Int(x * scale))
            let high = min(rep.pixelsWide - 1, Int(end * scale))
            guard low <= high, let ground = rep.colorAt(x: low, y: 0) else { return 0 }
            func inked(_ y: Int) -> Bool {
                for px in low...high {
                    guard let color = rep.colorAt(x: px, y: y) else { continue }
                    let delta = abs(color.redComponent - ground.redComponent)
                        + abs(color.greenComponent - ground.greenComponent)
                        + abs(color.blueComponent - ground.blueComponent)
                    if delta > 0.05 { return true }
                }
                return false
            }
            var bands = 0
            var y = 0
            while y < rep.pixelsHigh {
                if inked(y) {
                    bands += 1
                    while y < rep.pixelsHigh, inked(y) { y += 1 }
                }
                y += 1
            }
            return bands
        }
    }

    private func ink(_ paper: TerminalChatPaper) -> Ink {
        paper.layoutSubtreeIfNeeded()
        guard let rep = paper.bitmapImageRepForCachingDisplay(in: paper.bounds) else {
            fatalError("no rep")
        }
        paper.cacheDisplay(in: paper.bounds, to: rep)
        return Ink(rep: rep, scale: CGFloat(rep.pixelsWide) / max(1, paper.bounds.width))
    }

    // MARK: - folding

    /// A turn's machinery — thoughts and tool calls — is one line, and the
    /// answer it led to is still there in full.
    func testWorkIsFoldedIntoOneLine() {
        let page = paper(log(workingTurn(question: "why does the dock flicker?", answer: "Two clocks.")))
        // Two turns is a short talk, and a short talk starts open.
        XCTAssertEqual(page.shape.map(\.kind), ["you", "thought", "tool", "tool", "tool", "agent"])

        // A longer talk folds its machinery by itself — one line where
        // six rows used to be.
        let longer = paper(longTalk())
        XCTAssertEqual(longer.shape.map(\.kind),
                       Array(repeating: ["you", "activity", "agent"], count: 8).flatMap { $0 })
        XCTAssertLessThan(
            ink(longer).lines(from: 20, to: longer.bounds.width - 20),
            ink(page).lines(from: 20, to: page.bounds.width - 20) * 4,
            "eight folded turns take far less paper than eight open ones would"
        )
    }

    /// The activity line says what was done, not how many calls it took.
    func testTheActivityLineSaysWhatWasDone() {
        let longer = paper(longTalk())
        let said = longer.shape.filter { $0.kind == "activity" }.map(\.words)
        XCTAssertEqual(said.count, 8)
        for words in said {
            XCTAssertEqual(words, "Ran a command · Read a file · Searched · Thought once")
        }
    }

    /// A folded line is a door: clicking it opens the work behind it, and
    /// clicking it again closes it.
    func testClickingAFoldedLineOpensTheWork() {
        let longer = paper(longTalk())
        guard let folded = longer.shape.first(where: { $0.kind == "activity" }) else {
            return XCTFail("nothing was folded")
        }
        click(longer, at: NSPoint(x: folded.rect.midX, y: folded.rect.midY))
        XCTAssertEqual(Array(longer.shape.map(\.kind).prefix(6)),
                       ["you", "thought", "tool", "tool", "tool", "agent"],
                       "the first run opened")
        XCTAssertEqual(longer.shape.map(\.kind).filter { $0 == "activity" }.count, 7,
                       "and the rest stayed shut")

        guard let open = longer.shape.first(where: { $0.kind == "activity" }) else {
            return XCTFail("the second run should still be folded")
        }
        click(longer, at: NSPoint(x: open.rect.midX, y: open.rect.midY))
        XCTAssertEqual(Array(longer.shape.map(\.kind).prefix(12)), [
            "you", "thought", "tool", "tool", "tool", "agent",
            "you", "thought", "tool", "tool", "tool", "agent",
        ])
        XCTAssertEqual(longer.shape.map(\.kind).filter { $0 == "activity" }.count, 6)
    }

    /// A tool's own output is behind a second door, on the tool row.
    func testAToolRowOpensItsOutput() {
        // A talk short enough that the whole of it is on the paper, so a
        // line added by the click cannot hide below the fold.
        let page = paper(log(workingTurn(question: "why does the dock flicker?", answer: "Two clocks.")),
                         height: 900)
        guard let tool = page.shape.first(where: { $0.kind == "tool" && $0.words.contains("Bash") }) else {
            return XCTFail("no Bash row")
        }
        let before = ink(page).lines(from: 20, to: page.bounds.width - 20)
        click(page, at: NSPoint(x: tool.rect.midX, y: tool.rect.midY))
        let after = ink(page).lines(from: 20, to: page.bounds.width - 20)
        XCTAssertGreaterThan(after, before, "the output should add lines")
    }

    // MARK: - who is talking

    /// Your own words sit on the right in a bubble; the agent's sit on the
    /// left. It is the one thing that makes a transcript a conversation.
    func testYourWordsSitOnTheRightAndTheAgentsOnTheLeft() {
        let page = paper(log([
            block("user", text("why does the dock flicker?"), "2026-10-25T13:02:11.000Z"),
            block("assistant", text("Two clocks were asking for frames."), "2026-10-25T13:02:19.000Z"),
        ]))
        XCTAssertEqual(page.shape.map(\.kind), ["you", "agent"])
        let mine = page.shape[0].rect
        let theirs = page.shape[1].rect

        // The bubble is a filled box, so its own row has ink across the
        // right and none across the left.
        let picture = ink(page)
        // Image rows run top-down while the paper's own y runs bottom-up.
        let row = Int((page.bounds.height - mine.midY) * picture.scale)
        let ground = picture.rep.colorAt(x: 0, y: 0)!
        func painted(from: CGFloat, to: CGFloat) -> Int {
            var count = 0
            for px in max(0, Int(from * picture.scale))...min(picture.rep.pixelsWide - 1, Int(to * picture.scale)) {
                guard let color = picture.rep.colorAt(x: px, y: row) else { continue }
                let delta = abs(color.redComponent - ground.redComponent)
                    + abs(color.greenComponent - ground.greenComponent)
                    + abs(color.blueComponent - ground.blueComponent)
                if delta > 0.03 { count += 1 }
            }
            return count
        }
        XCTAssertEqual(painted(from: 0, to: page.bounds.width * 0.4), 0,
                       "nothing of mine reaches the left of the column")
        XCTAssertGreaterThan(painted(from: page.bounds.width * 0.55, to: page.bounds.width - 14), 0,
                             "my words are over on the right")
        XCTAssertGreaterThan(mine.minY, theirs.maxY, "the agent answers below me")
    }

    // MARK: - the footer

    /// When a turn ran, how long it took, and what it cost — built from
    /// the record, so it is the same numbers whichever way it is drawn.
    func testTheFooterSaysTheTimeTheSpanAndTheCost() {
        var turn = ChatLog.Turn(id: 1, role: .agent, parts: [])
        XCTAssertEqual(TerminalChatPaper.foot(turn), [])

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        turn.at = formatter.date(from: "2026-10-25T13:02:19.000Z")
        turn.until = formatter.date(from: "2026-10-25T13:03:14.000Z")
        XCTAssertEqual(TerminalChatPaper.foot(turn), ["21:02", "55s"])

        turn.usage = ChatLog.Usage(input: 12_400, output: 1_850, cached: 96_000)
        XCTAssertEqual(TerminalChatPaper.foot(turn), ["21:02", "55s", "12.4k in · 1.9k out", "96.0k cached"])

        // A turn under a second is not worth a number, and a turn with no
        // cost says nothing about cost.
        turn.until = turn.at
        turn.usage = nil
        XCTAssertEqual(TerminalChatPaper.foot(turn), ["21:02"])
    }

    func testTokensAreSaidInTheUnitsPeopleUse() {
        XCTAssertEqual(TerminalChatPaper.tokens(0), "0")
        XCTAssertEqual(TerminalChatPaper.tokens(999), "999")
        XCTAssertEqual(TerminalChatPaper.tokens(12_400), "12.4k")
        XCTAssertEqual(TerminalChatPaper.tokens(195_000), "195k")
        XCTAssertEqual(TerminalChatPaper.tokens(1_048_576), "1.0M")
    }

    // MARK: - the rail

    /// One tick per turn, down the right edge.
    func testTheRailHasOneTickPerTurn() {
        let page = paper(longTalk())
        XCTAssertEqual(page.shape.count, 24)
        let rail = ink(page).lines(from: page.bounds.width - 10, to: page.bounds.width - 7)
        XCTAssertEqual(rail, 8, "eight questions and eight answers, with the band behind them")
    }

    /// A tick is a door too: clicking one puts that turn under your eyes,
    /// even after the talk has been scrolled away from its end.
    func testClickingATickPutsThatTurnBackUnderYourEyes() {
        let page = paper(longTalk(), height: 300)
        XCTAssertTrue(page.isFollowing, "a fresh talk shows its newest words")
        let atTheEnd = page.shape.map(\.rect.origin.y)

        // The topmost tick is the first question, which is far above.
        click(page, at: NSPoint(x: page.bounds.width - 8, y: page.bounds.height - 12))
        XCTAssertFalse(page.isFollowing, "jumping to the top leaves the end behind")
        // Where the rows sit, not how many bands of ink there are: the
        // jump control at the bottom is ink too, and counting it would let
        // a talk that did not move look like one that did.
        let tops = page.shape.map(\.rect.origin.y)
        XCTAssertNotEqual(tops, atTheEnd, "the talk moved")
        XCTAssertGreaterThan(ink(page).lines(from: 20, to: page.bounds.width - 120), 0,
                             "and something is under your eyes")
    }

    // MARK: - what the agents record

    /// Codex says what a turn cost in a record of its own, after the
    /// answer it counted — and it must land on that answer, not on the
    /// one after it.
    func testCodexTokenCountsLandOnTheTurnTheyCounted() {
        let rollout = [
            #"{"timestamp":"2026-10-25T13:02:19.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"why does the dock flicker?"}]}}"#,
            #"{"timestamp":"2026-10-25T13:02:24.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Two clocks were asking for frames."}]}}"#,
            #"{"timestamp":"2026-10-25T13:02:25.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90000,"cached_input_tokens":80000,"output_tokens":3000},"last_token_usage":{"input_tokens":12000,"cached_input_tokens":9600,"output_tokens":400}}}}"#,
        ]
        let page = paper(log(rollout, agent: .codex))
        XCTAssertEqual(page.shape.map(\.kind), ["you", "agent"])
        XCTAssertEqual(page.shape.map(\.words).last, "Two clocks were asking for frames.")

        var found = false
        for turn in page.talk where turn.usage != nil {
            found = true
            XCTAssertEqual(turn.role, .agent)
            XCTAssertEqual(turn.usage?.input, 12_000)
            XCTAssertEqual(turn.usage?.output, 400)
            XCTAssertEqual(turn.usage?.cached, 9_600)
        }
        XCTAssertTrue(found, "the count should have landed somewhere")
    }
}
