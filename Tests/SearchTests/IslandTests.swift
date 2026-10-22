import XCTest
import Network
@testable import Search

// The island is told by hooks the CLIs run (see IslandHooks for the
// files that make them run them), over a socket (IslandServer), and what
// it's told is kept and shown (Island). What to check here is the
// reading of a hook's saying, the taking of the two shapes a hook writes,
// the keeping of sessions, and the writing and taking-back of the hooks
// themselves — everything but the bar, which is what the reading keeps.
final class IslandTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "island-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        super.setUp()
    }

    private var room: URL {
        let room = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        return room
    }

    private func json(_ fields: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
    }

    // MARK: - the reading

    /// A hook's saying is read down to what the bar needs, whichever of
    /// the two names the CLIs gave the moment (they borrowed from one
    /// another, field first), and the source and the terminal come with
    /// the request itself — the headers — over anything the body said,
    /// because the body's word for them is the bridge's, and the
    /// headers' is the caller's.
    func testASayingIsReadDownToTheBar() {
        let claude = IslandRead.event(
            body: json([
                "hook_event_name": "PreToolUse", "session_id": "run-1", "cwd": "/Users/who",
                "tool_name": "Bash", "tool_input": ["command": "swift build"],
            ]),
            source: "claude", tty: "/dev/ttys009"
        )
        XCTAssertEqual(claude?.name, "PreToolUse", "the moment is the hook's own word")
        XCTAssertEqual(claude?.session, "run-1", "the session is the run")
        XCTAssertEqual(claude?.source, "claude", "the source is the header's")
        XCTAssertEqual(claude?.tty, "/dev/ttys009", "the terminal is the header's")
        XCTAssertEqual(claude?.tool, "Bash", "the tool is what it was about to use")
        XCTAssertEqual(claude?.call, "swift build", "the input is said as the one line it is about")

        let codex = IslandRead.event(
            body: json(["event_name": "Stop", "session_id": "r-2", "last_assistant_message": "done"]),
            source: nil, tty: nil
        )
        XCTAssertEqual(codex?.name, "Stop", "codex's own word for the moment is taken too")
        XCTAssertEqual(codex?.words, "done", "the last said is kept")

        // Without headers, the body's own say-so serves (the pi
        // extension puts them there itself).
        let pi = IslandRead.event(body: json([
            "hook_event_name": "SessionStart", "session_id": "pi-3", "_source": "pi", "_tty": "/dev/ttys010",
        ]), source: nil, tty: nil)
        XCTAssertEqual(pi?.source, "pi", "the body's source serves")
        XCTAssertEqual(pi?.tty, "/dev/ttys010", "the body's terminal serves")

        // A saying that names no moment isn't one, and is dropped whole.
        XCTAssertNil(IslandRead.event(body: json(["session_id": "x"]), source: nil, tty: nil))
        XCTAssertNil(IslandRead.event(body: Data("not json".utf8), source: nil, tty: nil))
    }

    /// What a hook says is said at a length the bar can hold: the words
    /// kept to one glance, whatever the run said.
    func testTheWordsAreCutToTheBar() {
        let long = String(repeating: "a", count: 300)
        let said = IslandRead.event(
            body: json(["hook_event_name": "Stop", "session_id": "r", "last_assistant_message": long]),
            source: nil, tty: nil
        )
        XCTAssertEqual(said?.words?.count, 160, "the bar keeps 160, the one line of it")
        XCTAssertTrue(said?.words?.hasSuffix("…") ?? false, "the cut says it was cut")
        XCTAssertNil(
            IslandRead.event(
                body: json(["hook_event_name": "Stop", "session_id": "r", "last_assistant_message": "   "]),
                source: nil, tty: nil
            )?.words,
            "whitespace-only words are nothing"
        )
    }

    // MARK: - the shape

    /// The two askings are told apart by their first word: an HTTP POST
    /// read by its own said length, and anything else, bare JSON, whole
    /// when the sender has ended. The bridge's two headers are read out
    /// of the ask, and the body kept whole.
    func testTheShapeTakesTheTwoAskings() {
        let body = Data(#"{"hook_event_name":"PreToolUse"}"#.utf8)
        let head = "POST /hook HTTP/1.1\r\nX-Search-Source: claude\r\nX-Search-Tty: /dev/ttys001\r\nContent-Length: \(body.count)\r\n\r\n"
        var whole = Data(head.utf8)
        whole.append(body)

        guard case .http(let call, whole: true) = IslandServer.shape(whole) else {
            return XCTFail("a whole request is an http call")
        }
        XCTAssertEqual(call.path, "/hook", "the path is the ask's")
        XCTAssertEqual(call.source, "claude", "the source header is read")
        XCTAssertEqual(call.tty, "/dev/ttys001", "the tty header is read")
        XCTAssertEqual(call.body, body, "the body is kept to its own length, no further")

        // Half an ask is not an ask yet.
        var half = Data(head.utf8)
        half.append(body.prefix(3))
        guard case .http(_, whole: false) = IslandServer.shape(half) else {
            return XCTFail("a short body is a call not yet whole")
        }

        // Bare JSON is the pi extension's saying: whole when it's there,
        // whatever its length (the sender ends when it's done).
        guard case .bare(let bare) = IslandServer.shape(Data(#"{"hook_event_name":"SessionStart"}"#.utf8)) else {
            return XCTFail("a saying that isn't an ask is bare JSON")
        }
        XCTAssertTrue(bare.contains(Data("SessionStart".utf8)), "the bare saying is kept whole")

        // Nothing is not junk's opposite — nothing is nothing.
        guard case .junk = IslandServer.shape(Data()) else { return XCTFail("empty is junk") }
    }

    // MARK: - the keeping

    /// What the hooks say is kept as one session per run: started
    /// working, said at every tool, done with the last words. A session
    /// that was never said to start is made from what it's doing — the
    /// app can come up after the run does.
    @MainActor
    func testTheKeepingOfASession() {
        let island = Island.shared
        let said = { (fields: [String: Any]) in
            IslandRead.event(body: self.json(fields), source: "claude", tty: "/dev/ttys004")
        }
        func one() -> Island.Session? { island.sessions.first { $0.id == "claude/run-9" } }

        island.heard(said(["hook_event_name": "PreToolUse", "session_id": "run-9", "tool_name": "Bash", "tool_input": ["command": "ls"]])!)
        XCTAssertEqual(one()?.part, .working, "a session is made from its work when it starts unsaid")
        XCTAssertEqual(one()?.tool, "Bash", "the tool is what the bar says of the work")

        island.heard(said(["hook_event_name": "UserPromptSubmit", "session_id": "run-9", "prompt": "go"])!)
        XCTAssertEqual(one()?.part, .working, "starting is starting, whatever was said before")
        XCTAssertNil(one()?.tool, "a new run says nothing yet of a tool")

        island.heard(said(["hook_event_name": "PermissionRequest", "session_id": "run-9", "tool_name": "Bash"])!)
        XCTAssertEqual(one()?.part, .working, "the permission never comes as a saying — it comes held open")

        island.heard(said(["hook_event_name": "Notification", "session_id": "run-9", "message": "needs your ok"])!)
        XCTAssertEqual(one()?.part, .waiting, "the CLI's own waiting word stands as waiting")
        XCTAssertEqual(one()?.words, "needs your ok", "the waiting says what it's waiting on")

        island.heard(said(["hook_event_name": "Stop", "session_id": "run-9", "last_assistant_message": "all done"])!)
        XCTAssertEqual(one()?.part, .done, "the end of a turn is done")
        XCTAssertEqual(one()?.words, "all done", "done keeps the last said")

        island.putAway(one()!)
        XCTAssertNil(one(), "a done one is put away by having been read")

        island.heard(said(["hook_event_name": "PreToolUse", "session_id": "run-9", "tool_name": "Bash"])!)
        island.heard(said(["hook_event_name": "SessionEnd", "session_id": "run-9"])!)
        XCTAssertNil(one(), "the run over, the session goes with it")
    }

    /// A terminal's end takes its agents with it — the hooks can't say
    /// so themselves, a killed CLI never running another hook — and the
    /// holds its asking left open are handed back empty, so a CLI
    /// waiting on one goes on asking its own way.
    @MainActor
    func testATerminalSEndTakesItsAgentsWithIt() {
        let island = Island.shared
        var answered: [Data] = []
        let hold = IslandServer.Hold(
            event: IslandEvent(
                source: "claude", name: "PermissionRequest", session: "gone",
                tty: "/dev/ttys007", cwd: nil, tool: "Bash", call: nil, prompt: nil, words: nil
            ),
            answer: { answered.append($0) }
        )
        island.held(hold)
        island.heard(IslandEvent(
            source: "claude", name: "PreToolUse", session: "gone",
            tty: "/dev/ttys007", cwd: nil, tool: "Bash", call: nil, prompt: nil, words: nil
        ))
        island.retired(tty: "/dev/ttys007")
        XCTAssertTrue(island.holds.isEmpty, "the holds of a gone terminal are let go")
        XCTAssertTrue(island.sessions.allSatisfy { $0.tty != "/dev/ttys007" }, "its sessions go with it")
        XCTAssertEqual(answered, [Data("{}".utf8)], "an open hold is answered with nothing, the CLI's own asking")
    }

    /// The answer a person gives is written the way the CLIs take it:
    /// a go-ahead, a stop, or nothing — their cue to ask in person.
    @MainActor
    func testTheAnswerIsWrittenTheWayTheyTakeIt() {
        let island = Island.shared
        var bytes: [Data] = []
        func fresh(_ decision: Island.Decision) {
            bytes.removeAll()
            let hold = IslandServer.Hold(
                event: IslandEvent(
                    source: "claude", name: "PermissionRequest", session: "ans-\(bytes.count)-\(decision)",
                    tty: "/dev/ttys008", cwd: nil, tool: "Bash", call: "rm -rf", prompt: nil, words: nil
                ),
                answer: { bytes.append($0) }
            )
            island.held(hold)
            island.answer(hold, decision)
        }
        fresh(.allow)
        XCTAssertEqual(String(decoding: bytes[0], as: UTF8.self).contains(#""behavior":"allow""#), true, "allowed outright")
        fresh(.deny)
        XCTAssertEqual(String(decoding: bytes[0], as: UTF8.self).contains(#""behavior":"deny""#), true, "denied outright")
        fresh(.ownTerminal)
        XCTAssertEqual(bytes[0], Data("{}".utf8), "answered with nothing, the cue to ask in person")
    }

    // MARK: - the socket

    /// The bridge's ask is carried whole over the socket, and the
    /// permission it carries is held open: nothing goes back until a
    /// person says, and then the person's own words go back on the same
    /// line the ask came in on.
    func testTheSocketHoldsTheAskingOpen() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-\(UUID().uuidString).sock").path
        let shore = IslandServer(path: path)
        var asked: [IslandServer.Hold] = []
        let held = expectation(description: "the permission is held open")
        shore.holding = { hold in
            asked.append(hold)
            held.fulfill()
        }
        shore.start()

        let body = json([
            "hook_event_name": "PermissionRequest", "session_id": "sock-1", "cwd": "/tmp",
            "tool_name": "Bash", "tool_input": ["command": "rm -rf /tmp/x"],
        ])
        var ask = "POST /hook HTTP/1.1\r\nX-Search-Source: claude\r\nX-Search-Tty: /dev/ttys012\r\nContent-Length: \(body.count)\r\n\r\n".data(using: .utf8)!
        ask.append(body)

        let answered = expectation(description: "the answer comes back on the same line")
        let client = NWConnection(to: .unix(path: path), using: .tcp)
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(content: ask, completion: .contentProcessed { _ in })
            }
        }
        client.receiveMessage { reply, _, _, _ in
            let text = String(decoding: reply ?? Data(), as: UTF8.self)
            XCTAssertTrue(text.contains("hookSpecificOutput"), "the answer is the CLIs' own shape")
            XCTAssertTrue(text.contains(#""behavior":"allow""#), "the person said go ahead")
            client.cancel()
            answered.fulfill()
        }
        client.start(queue: .main)
        wait(for: [held], timeout: 5)

        XCTAssertEqual(asked.count, 1, "one asking, one hold")
        XCTAssertEqual(asked.first?.event.tool, "Bash", "the hold carries what was asked")
        XCTAssertEqual(asked.first?.event.call, "rm -rf /tmp/x", "the hold carries the one line of it")
        asked.first?.answer(Data(#"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#.utf8))
        wait(for: [answered], timeout: 5)
    }

    /// The pi extension's saying — bare JSON, wanting nothing back — is
    /// carried and answered in kind: nothing waits, nothing breaks. (Its
    /// own socket is a raw one, ended by half-closing — which the test
    /// runner's sandbox won't let a test make; Network's connection
    /// serves to say the same saying, and the server takes a saying the
    /// moment it says something whole.)
    func testTheSocketTakesTheBareSaying() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-\(UUID().uuidString).sock").path
        let shore = IslandServer(path: path)
        var said: [IslandEvent] = []
        let spoke = expectation(description: "the saying is heard")
        shore.spoken = { event in
            said.append(event)
            spoke.fulfill()
        }
        shore.start()

        let saying = json([
            "hook_event_name": "PreToolUse", "session_id": "pi-sock", "_source": "pi",
            "_tty": "/dev/ttys013", "cwd": "/tmp", "tool_name": "bash", "tool_input": ["command": "ls"],
        ])
        let answered = expectation(description: "answered bare in kind")
        let client = NWConnection(to: .unix(path: path), using: .tcp)
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(content: saying, completion: .contentProcessed { _ in })
            }
        }
        client.receiveMessage { reply, _, _, _ in
            XCTAssertEqual(
                String(decoding: reply ?? Data(), as: UTF8.self), "{}",
                "answered bare in kind: nothing waits, nothing says"
            )
            client.cancel()
            answered.fulfill()
        }
        client.start(queue: .main)
        wait(for: [spoke, answered], timeout: 5)
        XCTAssertEqual(said.first?.source, "pi", "the saying's own word for who said it is taken")
        XCTAssertEqual(said.first?.tty, "/dev/ttys013", "the saying's own word for where")
        XCTAssertEqual(said.first?.tool, "bash", "the saying's own word for the work")
    }

    // MARK: - the hooks

    /// The bridge is written once, runs (not just sits), and says the
    /// socket by the user's own id and the source it's told — the two
    /// things the server reads of it.
    func testTheBridgeIsWrittenAndRuns() throws {
        let bridge = try IslandHooks.writeBridge(room)
        let text = try String(contentsOf: URL(fileURLWithPath: bridge), encoding: .utf8)
        XCTAssertTrue(text.contains("--unix-socket"), "the bridge speaks the socket")
        XCTAssertTrue(text.contains("X-Search-Source: ${1:-}"), "the bridge passes the source through")
        XCTAssertTrue(text.contains("hookSpecificOutput"), "only a decision is worth the agent's ears")
        XCTAssertTrue(bridge.hasSuffix("/" + IslandHooks.bridgeName), "the bridge is where it was put")
        // Runs: the one permission that makes a hook a hook.
        let mode = try FileManager.default.attributesOfItem(atPath: bridge)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755, "the bridge runs")
    }

    /// Claude Code's settings keep whatever else was there — the user's
    /// own hooks, another tool's — and ours beside them: every event
    /// ours, once each, however many times it's installed. Taken out,
    /// theirs is as it was, and none of ours is left.
    func testClaudeSSettingsAreMergedNotTaken() throws {
        let home = room.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settings = home.appendingPathComponent("settings.json")
        // The user's own: a hook of theirs, and a setting of theirs.
        try json([
            "model": "big",
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/Users/who/mine.sh"]]]],
                "SessionStart": [[
                    "hooks": [
                                        ["type": "command", "command": "/Users/who/mine.sh"],
                    ]
                ]],
            ],
        ]).write(to: settings)

        try IslandHooks.installClaude(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.claudeHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        var after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        XCTAssertEqual(after?["model"] as? String, "big", "the user's own settings are kept")
        let hooks = after?["hooks"] as? [String: Any]
        let pre = hooks?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 2, "ours is beside theirs, not instead of it")
        XCTAssertTrue(
            (pre?.first?["matcher"] as? String) == "Bash",
            "their matcher's row is kept as it was"
        )
        let start = hooks?["SessionStart"] as? [[String: Any]]
        XCTAssertEqual(start?.count, 2, "ours is beside theirs in the events they share")
        let permission = hooks?["PermissionRequest"] as? [[String: Any]]
        let held = ((permission?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(held?["timeout"] as? Int, IslandHooks.heldLong, "the permission is waited on, the day")

        // Idempotent: what was there is there once, however many installs.
        try IslandHooks.installClaude(home, bridge: "/Where/search-island.sh")
        after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        XCTAssertEqual(
            ((after?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count, 1,
            "a second install takes the place of the first, not a place beside it"
        )
        XCTAssertEqual(
            ((after?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.count, 2,
            "theirs and ours stay theirs and ours, not twice ours"
        )

        try IslandHooks.removeClaude(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.claudeHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
        let done = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        let left = done?["hooks"] as? [String: Any]
        XCTAssertEqual(left?.count, 2, "their two events are left, ours taken")
        XCTAssertNil(left?["model"], "the top of the hooks is the hooks' own")
        XCTAssertEqual(done?["model"] as? String, "big", "the user's own settings outlive the hooks")
    }

    /// Codex's hooks are one nest deeper and have no matcher of their
    /// own; the same rules hold — kept what's theirs, once what's ours,
    /// gone what was ours alone.
    func testCodexSHooksAreMergedNotTaken() throws {
        let home = room.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hooks = home.appendingPathComponent("hooks.json")
        try json([
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": "/Users/who/mine"]]]],
            ],
        ]).write(to: hooks)

        try IslandHooks.installCodex(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.codexHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        var after = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any]
        var rows = ((after?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(rows?.count, 2, "ours is beside theirs")
        var held = ((rows?.last?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(held?["command"] as? String, "/Where/search-island.sh codex", "the bridge is told the source")
        rows = ((after?["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        held = ((rows?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(held?["timeout"] as? Int, IslandHooks.heldLong, "the permission is waited on, the day")

        try IslandHooks.removeCodex(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.codexHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
        let done = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any]
        let left = done?["hooks"] as? [String: Any]
        XCTAssertEqual(left?.count, 1, "their event is left")
        XCTAssertEqual(
            (((left?["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String,
            "/Users/who/mine", "their hook is as it was"
        )
    }

    /// Pi's is one file, whole: written whole on every install (never
    /// half of two versions) and taken away whole.
    func testPiSIsOneFileWhole() throws {
        let home = room.appendingPathComponent("pi", isDirectory: true)
        XCTAssertFalse(IslandHooks.piHooked(home), "a home that isn't there is not hooked")

        try IslandHooks.installPi(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.piHooked(home), "the extension is the whole of being hooked")
        let text = try String(
            contentsOf: home.appendingPathComponent("extensions").appendingPathComponent(IslandHooks.piName),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("BRIDGE_PATH = \"/Where/search-island.sh\""), "the bridge is told where it is")
        XCTAssertTrue(text.contains("search-island-"), "the socket is said by the user's own id")
        XCTAssertTrue(text.contains("hookSpecificOutput"), "the asking is answered in the CLIs' own shape")

        try IslandHooks.removePi(home)
        XCTAssertFalse(IslandHooks.piHooked(home), "taken away whole")
    }
}
