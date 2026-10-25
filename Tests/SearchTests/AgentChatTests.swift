import XCTest
@testable import Search

// The chat view reads what the agents wrote themselves: their own
// transcript files, in three shapes (see AgentChat). What to check here
// is the reading — a person's line from the agent's, a thought from an
// answer, a tool's call held until its answer names it, the wrappers
// the CLIs put round what is not theirs — and the following of a file
// that is still being written, which is what a live conversation is.
final class AgentChatTests: XCTestCase {
    private var room: URL {
        let room = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-chat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        return room
    }

    /// A store the shape of the real ones, with a session file in it.
    private func store(of agent: AgentTalk.Agent, name: String, lines: [String]) -> URL {
        let home = room.appendingPathComponent(agent.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent(name)
        try? lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        return home
    }

    private func log(_ agent: AgentTalk.Agent, _ lines: [String]) -> ChatLog {
        var read = ChatLog(agent: agent)
        read.read(Data(lines.joined(separator: "\n").appending("\n").utf8))
        return read
    }

    // MARK: - pi

    /// Pi's shape: the person's line whole, the agent's answer with its
    /// thinking and its tools in one message, and a tool's answer in a
    /// message of its own that names the call it answers.
    func testPiRecordsReadAsATalk() {
        let read = log(.pi, [
            #"{"type":"session","version":3,"id":"01a160f8"}"#,
            #"{"type":"custom_message","customType":"remote-pi:name-assigned","content":"Mesh name"}"#,
            #"{"type":"message","timestamp":"2026-10-22T00:19:18.833Z","message":{"role":"user","content":[{"type":"text","text":"采用 rea 分析下 Metalterm 程序"}]}}"#,
            #"{"type":"message","timestamp":"2026-10-22T00:19:23.732Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me start."},{"type":"toolCall","id":"call_00","name":"bash","arguments":{"command":"ls -la"}},{"type":"text","text":"接下来接入。"}]}}"#,
            #"{"type":"message","timestamp":"2026-10-22T00:19:23.795Z","message":{"role":"toolResult","toolCallId":"call_00","toolName":"bash","content":[{"type":"text","text":"total 728"}]}}"#,
        ])
        XCTAssertEqual(read.turns.count, 2)
        XCTAssertEqual(read.turns[0].role, .person)
        guard case .word(let asked) = read.turns[0].parts[0] else { return XCTFail() }
        XCTAssertEqual(asked, "采用 rea 分析下 Metalterm 程序")
        XCTAssertEqual(read.turns[1].role, .agent)
        XCTAssertEqual(read.turns[1].parts.count, 3)
        guard case .thought(let thought) = read.turns[1].parts[0],
              case .tool(let tool) = read.turns[1].parts[1],
              case .word(let said) = read.turns[1].parts[2]
        else { return XCTFail() }
        XCTAssertEqual(thought, "Let me start.")
        XCTAssertEqual(said, "接下来接入。")
        XCTAssertEqual(tool.name, "bash")
        XCTAssertEqual(tool.summary, "ls -la")
        XCTAssertEqual(tool.output, "total 728")
        XCTAssertEqual(tool.failed, false)
    }

    /// An answer with no call to answer (a record from before this reader
    /// began, or a line half written) is dropped rather than shown as an
    /// orphan tool.
    func testAnAnswerWithNoCallIsDropped() {
        let read = log(.pi, [
            #"{"type":"message","message":{"role":"toolResult","toolCallId":"call_gone","content":[{"type":"text","text":"out"}]}}"#,
        ])
        XCTAssertTrue(read.turns.isEmpty)
    }

    // MARK: - Claude Code

    /// Claude's shape: the same blocks inside a `message`, the tool's
    /// answer in a `user` line of its own, and the bookkeeping — a side
    /// chain, a command's record — not conversation at all.
    func testClaudeRecordsReadAsATalk() {
        let read = log(.claude, [
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"a subagent's words"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>/clear</command-name>"}]}}"#,
            #"{"type":"user","timestamp":"2026-10-22T00:19:18.833Z","message":{"role":"user","content":[{"type":"text","text":"分析一下"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Where to begin."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/tmp/a.swift"}},{"type":"text","text":"看完了。"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"1  let x = 1"}]}]}}"#,
        ])
        // The person once, the agent once: the tool_result user line is
        // the tool's answer, not a person's saying.
        XCTAssertEqual(read.turns.count, 2)
        XCTAssertEqual(read.turns[0].role, .person)
        XCTAssertEqual(read.turns[1].role, .agent)
        guard case .tool(let tool) = read.turns[1].parts[1] else { return XCTFail() }
        XCTAssertEqual(tool.name, "Read")
        XCTAssertEqual(tool.summary, "/tmp/a.swift")
        XCTAssertEqual(tool.output, "1  let x = 1")
        // A failed tool says so.
        let again = log(.claude, [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"no such file"}]}}"#,
        ])
        guard case .tool(let failed) = again.turns[0].parts[0] else { return XCTFail() }
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.output, "no such file")
    }

    // MARK: - Codex

    /// Codex's shape: a rollout of `response_item`s, with the reasoning
    /// as a summary and the shell as a function call. The `event_msg`
    /// copies of the same words are display cues, not transcript.
    func testCodexRolloutsReadAsATalk() {
        let read = log(.codex, [
            #"{"type":"session_meta","payload":{}}"#,
            #"{"type":"response_item","timestamp":"2026-10-22T00:19:18.833Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"跑一下测试"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"跑一下测试"}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Tests first."}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\"command\":[\"swift\",\"test\"]}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Executed 4 tests"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"全绿。"}]}}"#,
        ])
        XCTAssertEqual(read.turns.count, 2)
        XCTAssertEqual(read.turns[0].role, .person)
        XCTAssertEqual(read.turns[1].role, .agent)
        XCTAssertEqual(read.turns[1].parts.count, 3)
        guard case .thought(let thought) = read.turns[1].parts[0],
              case .tool(let tool) = read.turns[1].parts[1],
              case .word(let said) = read.turns[1].parts[2]
        else { return XCTFail() }
        XCTAssertEqual(thought, "Tests first.")
        XCTAssertEqual(tool.name, "shell")
        XCTAssertEqual(tool.output, "Executed 4 tests")
        XCTAssertEqual(said, "全绿。")
    }

    // MARK: - the file, followed

    /// The reader takes what the file added since the last look, holds a
    /// half-written line for the next one, and starts over when the file
    /// it knew is replaced by a shorter one.
    func testTheReaderFollowsTheFileAndStartsOverWhenItIsRewritten() throws {
        let home = store(of: .pi, name: "2026-10-22T00-17-16-154Z_01a160f8.jsonl", lines: [
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"one"}]}}"#,
        ])
        let file = home.appendingPathComponent("2026-10-22T00-17-16-154Z_01a160f8.jsonl")
        let talk = AgentTalk.Talk(agent: .pi, id: "01a160f8", file: file, cwd: nil)
        var reader = ChatReader(talk: talk)
        XCTAssertTrue(reader.update())
        XCTAssertEqual(reader.log.turns.count, 1)

        // Appended: one more turn, and the half of the next held.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"two"}]}}"# + "\n")
                .appending(#"{"type":"message","message":{"rol"#).utf8
        ))
        try handle.close()
        XCTAssertTrue(reader.update())
        XCTAssertEqual(reader.log.turns.count, 2)
        // Nothing new: nothing read, and nothing to draw.
        XCTAssertFalse(reader.update())

        // The held half finishes, and is one turn once it does.
        let finish = try FileHandle(forWritingTo: file)
        try finish.seekToEnd()
        try finish.write(contentsOf: Data((#"e":"user","content":[{"type":"text","text":"three"}]}}"# + "\n").utf8))
        try finish.close()
        XCTAssertTrue(reader.update())
        XCTAssertEqual(reader.log.turns.count, 3)

        // Replaced by a shorter file: read again from the top.
        try #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"afresh"}]}}"#
            .appending("\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(reader.update())
        XCTAssertEqual(reader.log.turns.count, 1)
        guard case .word(let said) = reader.log.turns[0].parts[0] else { return XCTFail() }
        XCTAssertEqual(said, "afresh")
    }

    /// A talk is only had from a session file in the agent's own store —
    /// and a path pointing anywhere else is a talk still waiting for its
    /// file, never a reading of somewhere it should not look.
    func testATalkIsOnlyTakenFromItsOwnStore() throws {
        let home = store(of: .claude, name: "b40d2959-f0e0-4b41-9be2-829ba6a940cc.jsonl", lines: ["{}"])
        let inside = home.appendingPathComponent("b40d2959-f0e0-4b41-9be2-829ba6a940cc.jsonl").path
        let raw: [String: Any] = ["transcript_path": inside]
        let talk = AgentTalk.talk(in: raw, source: "claude", cwd: nil, stores: [home])
        XCTAssertEqual(talk?.id, "b40d2959-f0e0-4b41-9be2-829ba6a940cc")
        XCTAssertEqual(talk?.file?.path, inside)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("pretending-\(UUID().uuidString).jsonl")
        try "{}".write(to: outside, atomically: true, encoding: .utf8)
        let stray = AgentTalk.talk(
            in: ["transcript_path": outside.path], source: "claude", cwd: nil, stores: [home]
        )
        XCTAssertEqual(stray?.file, nil)

        // A source this file cannot read is no talk at all.
        XCTAssertNil(AgentTalk.talk(in: ["transcript_path": inside], source: "cursor", cwd: nil, stores: [home]))
        // A run whose file is not written yet is still found in its store
        // when it appears, by the run's own name.
        let waiting = AgentTalk.Talk(agent: .claude, id: "b40d2959-f0e0-4b41-9be2-829ba6a940cc", file: nil, cwd: nil)
        XCTAssertEqual(AgentTalk.settle(waiting, in: [home])?.path, inside)
    }

    // MARK: - the chip and the plate

    /// An agent that said where its transcript is puts the chip up in its
    /// terminal; pressing it lays the conversation over the grid; pressing
    /// it again takes it away. The island hears the agent through the
    /// same hooks the notch does — a saying that carries the file is what
    /// puts the chip there.
    @MainActor
    func testTheChipAppearsAndThePlateReadsTheTalk() throws {
        let home = store(of: .pi, name: "2026-10-22T00-17-16-154Z_01a160f8.jsonl", lines: [
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"分析一下"}]}}"#,
            #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"好。"}]}}"#,
        ])
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c", "sleep 10"]))
        let view = TerminalView(terminal: terminal)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        window.orderFrontRegardless()
        // Not close(): closing a shown window in a test tears it down in
        // a way that crashes whichever heavy test runs next in the run
        // (a WebKit one, here). The dock tests let their panes leak for
        // the same reason; the window goes when the process does.
        window.orderOut(nil)

        let island = Island.shared
        island.heard(IslandEvent(
            source: "pi", name: "SessionStart", session: "run-chat",
            tty: terminal.pty, cwd: nil,
            talk: AgentTalk.Talk(
                agent: .pi, id: "01a160f8",
                file: home.appendingPathComponent("2026-10-22T00-17-16-154Z_01a160f8.jsonl"),
                cwd: nil
            )
        ))
        XCTAssertNotNil(view.chatPill, "an agent that can be read puts the chip up")
        XCTAssertNil(view.chatPlate, "and the talk waits until it is asked for")

        view.toggleChat()
        XCTAssertNotNil(view.chatPlate)
        XCTAssertTrue(view.chatShowing)
        let turns = view.chatReader?.log.turns.count ?? 0
        XCTAssertEqual(turns, 2, "the plate reads the agent's own record")
        // The composer's chip is wired to the same question its list is:
        // opening the talk asks the agent what it is on, and the chip says
        // that answer rather than staying blank. (What the answer is
        // depends on this Mac's catalogs, so only the wiring is asserted.)
        XCTAssertEqual(
            view.chatPlate?.modelWords,
            AgentModels.current(for: .pi, talk: view.chatTalk) ?? "",
            "the chip says the model the agent is on"
        )

        view.toggleChat()
        XCTAssertNil(view.chatPlate)
        XCTAssertFalse(view.chatShowing)

        // The agent leaving takes the chip with it.
        island.heard(IslandEvent(source: "pi", name: "SessionEnd", session: "run-chat", tty: terminal.pty, cwd: nil))
        XCTAssertNil(view.chatPill)
    }

    /// The chip takes a click where it actually is. A hit test is asked in
    /// the *superview's* coordinates, and the chip sits in a far corner —
    /// asked against its own bounds it answered no to every real click,
    /// which is precisely how it was found (a chip drawn, reading right,
    /// doing nothing).
    @MainActor
    func testTheChipTakesItsClickWhereItStands() {
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c", "sleep 10"]))
        let view = TerminalView(terminal: terminal)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        let pill = TerminalChatPill()
        view.addSubview(pill)
        view.chatPill = pill
        pill.say("Claude Code", showing: false)
        view.placeChat()
        view.layoutSubtreeIfNeeded()

        let middle = NSPoint(x: pill.frame.midX, y: pill.frame.midY)
        XCTAssertTrue(
            pill.hitTest(middle) === pill,
            "a click on the chip lands on the chip, in the terminal's own coordinates"
        )
        XCTAssertNil(
            pill.hitTest(NSPoint(x: 10, y: 10)),
            "and the rest of the pane stays the terminal's"
        )
        window.orderOut(nil)
    }
}
