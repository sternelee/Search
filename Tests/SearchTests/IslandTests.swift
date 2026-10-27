import XCTest
import Network
import SwiftUI
import AppKit
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
        let head = "POST /hook HTTP/1.1\r\nX-Search-Source: claude\r\nX-Search-Tty: /dev/ttys001\r\nX-Search-Event: PreToolUse\r\nContent-Length: \(body.count)\r\n\r\n"
        var whole = Data(head.utf8)
        whole.append(body)

        guard case .http(let call, whole: true) = IslandServer.shape(whole) else {
            return XCTFail("a whole request is an http call")
        }
        XCTAssertEqual(call.path, "/hook", "the path is the ask's")
        XCTAssertEqual(call.source, "claude", "the source header is read")
        XCTAssertEqual(call.tty, "/dev/ttys001", "the tty header is read")
        XCTAssertEqual(call.event, "PreToolUse", "the event header is read")
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

    // MARK: - the folding of the names

    /// Every CLI has its own word for where the agent stands, and the
    /// bar has just the one vocabulary: Cursor's and Copilot's
    /// camelCase and Gemini's words of its own are folded onto it, a
    /// moment that isn't one (a thought mid-turn) is nothing, and
    /// Grok's turn ended on an error is still a turn ended.
    func testTheMomentsAreFoldedOntoTheIslandsOwnWords() {
        // Gemini
        XCTAssertEqual(IslandRead.moment("BeforeAgent"), "UserPromptSubmit", "gemini's turn start is a prompt")
        XCTAssertEqual(IslandRead.moment("BeforeTool"), "PreToolUse", "gemini's tool ahead is a tool ahead")
        XCTAssertEqual(IslandRead.moment("AfterTool"), "PostToolUse", "gemini's tool done is a tool done")
        XCTAssertEqual(IslandRead.moment("AfterAgent"), "Stop", "gemini's turn end is a stop")
        XCTAssertEqual(IslandRead.moment("SessionStart"), "SessionStart", "gemini borrows the shared words for the session")
        // Cursor
        XCTAssertEqual(IslandRead.moment("beforeSubmitPrompt"), "UserPromptSubmit", "cursor's camelCase folds the same")
        XCTAssertEqual(IslandRead.moment("beforeShellExecution"), "PreToolUse", "cursor's shell ahead is a tool ahead")
        XCTAssertEqual(IslandRead.moment("afterFileEdit"), "PostToolUse", "cursor's edit done is a tool done")
        XCTAssertEqual(IslandRead.moment("afterAgentResponse"), "Stop", "cursor's answer out is a stop")
        XCTAssertEqual(IslandRead.moment("stop"), "Stop", "cursor's own word is the shared word, lowercased")
        XCTAssertNil(IslandRead.moment("afterAgentThought"), "a thought mid-turn is not a moment")
        // Copilot
        XCTAssertEqual(IslandRead.moment("sessionStart"), "SessionStart", "copilot's camelCase folds the same")
        XCTAssertEqual(IslandRead.moment("userPromptSubmitted"), "UserPromptSubmit", "copilot's prompt is a prompt")
        XCTAssertEqual(IslandRead.moment("preToolUse"), "PreToolUse", "copilot's tool ahead is a tool ahead")
        XCTAssertEqual(IslandRead.moment("errorOccurred"), "Notification", "copilot's error is a thing to be told")
        // Grok
        XCTAssertEqual(IslandRead.moment("StopFailure"), "Stop", "grok's failed turn is still a turn ended")
        // The shared words pass untouched, and a word nobody knows
        // passes too — to be dropped by the keeping, not the folding.
        XCTAssertEqual(IslandRead.moment("PermissionRequest"), "PermissionRequest", "the shared words are their own")
        XCTAssertEqual(IslandRead.moment("Whatever"), "Whatever", "an unknown word is passed on, not invented into")
    }

    /// Cursor's and Copilot's payloads carry no name of their own —
    /// the bridge says it for them on the request — and Copilot's
    /// carries no session either, so the terminal it ran in says which
    /// run it was, one run to a terminal.
    func testASayingWithNoNameOfItsOwnIsReadByTheRequests() {
        // Cursor: no hook_event_name in the body, the name on the
        // request, folded with the rest.
        let cursor = IslandRead.event(
            body: json(["session_id": "conv-77", "cwd": "/Users/who"]),
            source: "cursor", tty: "/dev/ttys012", event: "beforeShellExecution"
        )
        XCTAssertEqual(cursor?.name, "PreToolUse", "the request's name is the moment's")
        XCTAssertEqual(cursor?.session, "conv-77", "cursor's session is its conversation")
        XCTAssertEqual(cursor?.source, "cursor", "the source is the header's")

        // Copilot: neither a name nor a session in the body — the
        // request says both.
        let copilot = IslandRead.event(
            body: json(["cwd": "/Users/who"]),
            source: "copilot", tty: "/dev/ttys013", event: "userPromptSubmitted"
        )
        XCTAssertEqual(copilot?.name, "UserPromptSubmit", "the request's name is the moment's")
        XCTAssertEqual(copilot?.session, "/dev/ttys013", "a run without a session is its terminal")

        // Two copilot runs in two terminals are two sessions, not one.
        let other = IslandRead.event(
            body: json(["cwd": "/Users/who"]),
            source: "copilot", tty: "/dev/ttys014", event: "userPromptSubmitted"
        )
        XCTAssertEqual(other?.session, "/dev/ttys014", "the second terminal is the second session")

        // And with neither a session nor a terminal, the one shared
        // name holds what's left.
        let stray = IslandRead.event(
            body: json(["hook_event_name": "Stop"]),
            source: nil, tty: nil
        )
        XCTAssertEqual(stray?.session, "default", "the last resort is the one shared name")
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

    /// A row is put away by hand, whatever it's doing — and comes back
    /// only when it says something worth hearing again: a new turn, an
    /// ask, a finish, never the running noise between them. An ask it
    /// was holding open when it was put away goes back to its own
    /// terminal to ask there, the one place it can still be answered —
    /// closing the row is not closing the asking on it.
    @MainActor
    func testARowIsPutAwayUntilItSaysAgain() {
        let island = Island.shared
        let said = { (fields: [String: Any]) in
            IslandRead.event(body: self.json(fields), source: "claude", tty: "/dev/ttys004")
        }
        func one() -> Island.Session? { island.sessions.first { $0.id == "claude/run-put" } }

        island.heard(said(["hook_event_name": "PreToolUse", "session_id": "run-put", "tool_name": "Bash", "tool_input": ["command": "ls"]])!)
        island.putAway(one()!)
        XCTAssertNil(one(), "a working one can be put away by hand too")
        XCTAssertTrue(island.shelved.contains("claude/run-put"), "a put-away one is kept out of the bar")

        island.heard(said(["hook_event_name": "PreToolUse", "session_id": "run-put", "tool_name": "Read", "tool_input": ["file_path": "/tmp"]])!)
        XCTAssertNotNil(one(), "the work still goes on off-stage")
        XCTAssertTrue(island.shelved.contains("claude/run-put"), "the running noise is not worth hearing again")

        island.heard(said(["hook_event_name": "UserPromptSubmit", "session_id": "run-put", "prompt": "again"])!)
        XCTAssertFalse(island.shelved.contains("claude/run-put"), "a new turn is worth hearing again")

        var answered: Data?
        island.held(IslandServer.Hold(
            event: IslandEvent(source: "claude", name: "PermissionRequest", session: "run-put", tty: "/dev/ttys004", cwd: nil, tool: "Bash", call: "rm -rf /", prompt: nil, words: nil),
            answer: { answered = $0 }
        ))
        XCTAssertEqual(one()?.part, .asking, "an ask is worth hearing again")
        island.putAway(one()!)
        XCTAssertEqual(answered, Data("{}".utf8), "the ask is handed back to its own terminal, not closed on the asking")
        XCTAssertFalse(island.holds.contains { $0.event.session == "run-put" }, "the hold is let go")

        island.heard(said(["hook_event_name": "SessionEnd", "session_id": "run-put"])!)
        XCTAssertNil(one(), "the run over, the session goes with it")
        XCTAssertFalse(island.shelved.contains("claude/run-put"), "and the shelving with it")
    }

    /// A terminal with an agent at work in it is the notch's to talk
    /// about, not the desktop's: its own sayings of itself — OSC 9, a
    /// bell — are the notch's to say again (Browser skips the Mac
    /// notification when the island keeps a session for the terminal).
    @MainActor
    func testATerminalWithAnAgentInItIsTheNotchsToTalkAbout() {
        let island = Island.shared
        XCTAssertFalse(island.atWork(tty: nil), "no terminal, no agent")
        XCTAssertFalse(island.atWork(tty: "/dev/ttys999"), "a terminal with nothing kept is not at work")
        island.heard(IslandEvent(
            source: "claude", name: "PreToolUse", session: "run-at-work",
            tty: "/dev/ttys005", cwd: nil, tool: "Bash", call: nil, prompt: nil, words: nil
        ))
        XCTAssertTrue(island.atWork(tty: "/dev/ttys005"), "the terminal the agent runs in is at work")
        island.retired(tty: "/dev/ttys005")
        XCTAssertFalse(island.atWork(tty: "/dev/ttys005"), "the terminal gone, the work goes with it")
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

    // MARK: - the bar's place

    /// The bar sits where it's dragged and holds the width it's given:
    /// both kept inside the window, whatever the drag said (see
    /// IslandPlace — the bar's own math, kept from a window so it can
    /// be held to here).
    func testTheBarKeepsItsPlaceAndWidthInsideTheWindow() {
        // The width: no narrower than 220, no wider than 720 — or the
        // room less a breath each side. A room too narrow for the
        // narrowest is overruled — the bar is never nothing.
        XCTAssertEqual(IslandPlace.width(360, room: 1000), 360, "a middle width is kept as it is")
        XCTAssertEqual(IslandPlace.width(100, room: 1000), 220, "too narrow is the narrowest")
        XCTAssertEqual(IslandPlace.width(2000, room: 1000), 720, "too wide is the widest")
        XCTAssertEqual(IslandPlace.width(2000, room: 500), 472, "a narrow window wins over the widest")
        XCTAssertEqual(IslandPlace.width(100, room: 300), 220, "a window too narrow is overruled")
        // The place: the left edge for a center said as a share of the
        // room, a breath (fourteen) in from each edge it can't cross.
        XCTAssertEqual(IslandPlace.left(center: 0.5, width: 360, room: 1000), 320, "the middle of the room")
        XCTAssertEqual(IslandPlace.left(center: 0.0, width: 360, room: 1000), 14, "the far left stops a breath in")
        XCTAssertEqual(IslandPlace.left(center: 1.0, width: 360, room: 1000), 626, "the far right stops a breath in")
        XCTAssertEqual(IslandPlace.left(center: 1.0, width: 360, room: 380), 10, "a room with no room centers the bar")
        // And the share is the say-so kept, whatever width and place.
        XCTAssertEqual(IslandPlace.center(left: 320, width: 360, room: 1000), 0.5, accuracy: 0.001, "the middle goes back as a half")
        XCTAssertEqual(IslandPlace.center(left: 14, width: 220, room: 1000), 0.124, accuracy: 0.001, "the left edge says where the center is")
        XCTAssertEqual(IslandPlace.center(left: 14, width: 220, room: 0), 0.5, "a room of nothing keeps the middle it had")
        // How far down the bar is dragged: no higher than the notch
        // it starts at (up from there is the tabs' own strip), no
        // lower than a breath of the window over the bar's own
        // height — however many rows it grew to on the way down.
        XCTAssertEqual(IslandPlace.down(50, room: 800, bar: 30), 50, "a middle down is kept as it is")
        XCTAssertEqual(IslandPlace.down(-40, room: 800, bar: 30), 0, "up from the notch is the tabs' place, not the bar's")
        XCTAssertEqual(IslandPlace.down(2000, room: 800, bar: 30), 756, "too far down keeps a breath of the window under it")
        XCTAssertEqual(IslandPlace.down(50, room: 40, bar: 30), 0, "a room with no room below the bar holds it at the notch")
    }

    // MARK: - the stack

    /// The bar is a stack of cards, newest first, and one agent is one
    /// card. What to hold it to here is the order the island keeps —
    /// the bar draws what it's told, so the telling is where a card's
    /// place is decided — and the shape of the stack: a few cards while
    /// it's closed, all of them while it's open.
    @MainActor
    func testTheNewestSayingIsTheTopOfTheStack() {
        let island = Island.shared
        let said = { (name: String, run: String, tool: String) in
            IslandEvent(
                source: "claude", name: name, session: run, tty: "/dev/ttys004",
                cwd: nil, tool: tool, call: nil, prompt: nil, words: nil
            )
        }
        func place(_ run: String) -> Int? { island.order.firstIndex(of: "claude/\(run)") }

        island.heard(said("PreToolUse", "run-a", "Bash"))
        island.heard(said("PreToolUse", "run-b", "Read"))
        island.heard(said("PreToolUse", "run-c", "Grep"))
        XCTAssertEqual(island.order.prefix(3).map { $0 }, ["claude/run-c", "claude/run-b", "claude/run-a"],
                       "the last thing heard is the first card")

        // One agent says something else: its card goes back to the top
        // rather than a second card appearing for it — the same run, the
        // same card, said over.
        island.heard(said("PreToolUse", "run-a", "Edit"))
        XCTAssertEqual(island.order.prefix(3).map { $0 }, ["claude/run-a", "claude/run-c", "claude/run-b"],
                       "an agent that says more of itself comes back to the top")
        XCTAssertEqual(island.sessions.filter { $0.id == "claude/run-a" }.count, 1,
                       "one agent is one card, however much it says")
        XCTAssertEqual(island.sessions.first { $0.id == "claude/run-a" }?.tool, "Edit",
                       "the card says the newest thing it's doing")

        // A run over is a card gone, and its place with it.
        island.heard(IslandEvent(
            source: "claude", name: "SessionEnd", session: "run-b", tty: "/dev/ttys004",
            cwd: nil, tool: nil, call: nil, prompt: nil, words: nil
        ))
        XCTAssertNil(place("run-b"), "the run over, its place goes with its card")

        for run in ["run-a", "run-c"] {
            island.heard(IslandEvent(
                source: "claude", name: "SessionEnd", session: run, tty: "/dev/ttys004",
                cwd: nil, tool: nil, call: nil, prompt: nil, words: nil
            ))
        }
        // The island is the app's one, shared with every other test in
        // this file: what's held to is this run's own cards being gone,
        // not the bar being empty of everybody's.
        XCTAssertFalse(island.order.contains { $0.hasPrefix("claude/run-") },
                       "the runs over, their places go with their cards")
    }

    /// The shape of the pile, without a window: a few cards piled,
    /// every card straightened, the piled one a front card and a slice
    /// of each one behind it, and the straightened one held inside the
    /// room it's in.
    func testThePileIsAFewCardsDeepAndAllOfThemLaidOut() {
        XCTAssertEqual(IslandPlace.showing(0), 0, "nothing to show, nothing shown")
        XCTAssertEqual(IslandPlace.showing(2), 2, "a pile of two is two")
        XCTAssertEqual(IslandPlace.showing(9), IslandPlace.stack, "a deep pile is held to the few it draws")

        // Piled: the front card whole, a slice of each one behind it —
        // and as tall as the tallest of them, since a slice of a card
        // that says more than the front one is still drawn above it.
        let card: CGFloat = 40
        XCTAssertEqual(IslandPlace.closed([card]), card, accuracy: 0.001, "a pile of one is the card")
        XCTAssertEqual(IslandPlace.closed([card, card, card]), card + 2 * IslandPlace.peek, accuracy: 0.001,
                       "three cards piled are the front one and two slices")
        XCTAssertEqual(IslandPlace.closed(Array(repeating: card, count: 9)), card + 2 * IslandPlace.peek,
                       accuracy: 0.001, "nine cards piled are still the few that draw")
        XCTAssertEqual(IslandPlace.closed([20, 60, 30]), 60 + 2 * IslandPlace.peek, accuracy: 0.001,
                       "a slice of a card taller than the front one still has to fit")

        // Straightened: as tall as the room can be told, never taller
        // than the bar grows to, and never nothing.
        XCTAssertEqual(IslandPlace.open(1000), IslandPlace.openMost, accuracy: 0.001,
                       "a tall window is the bar's own most")
        XCTAssertEqual(IslandPlace.open(300), 220, accuracy: 0.001,
                       "a short window keeps a breath over the bar")
        XCTAssertEqual(IslandPlace.open(40), IslandPlace.peek, accuracy: 0.001,
                       "a window with no room is a sliver, not nothing")
    }

    /// The deck's own rule: what a card at a depth is drawn as, and
    /// where each card's top edge sits — piled and straightened. This is
    /// the whole of the "3D": a card behind the front one is smaller,
    /// dimmer and tipped back about its own bottom edge, and the front
    /// card is none of those things, so a pile straightened is a list.
    func testACardBehindIsSmallerDimmerAndTippedBack() {
        // The front card is the identity — news is read square on.
        let front = IslandPlace.deck(0)
        XCTAssertEqual(front.scale, 1, accuracy: 0.0001, "the front card is drawn its own size")
        XCTAssertEqual(front.lean, 0, accuracy: 0.0001, "the front card isn't tipped at all")
        XCTAssertEqual(front.light, 1, accuracy: 0.0001, "the front card is drawn in full light")

        // Each one behind is all three, and more so the further back.
        for level in 1..<5 {
            let card = IslandPlace.deck(level)
            let nearer = IslandPlace.deck(level - 1)
            XCTAssertLessThan(card.scale, nearer.scale, "a card further back is smaller")
            XCTAssertGreaterThan(card.lean, nearer.lean, "a card further back is tipped further")
            XCTAssertLessThan(card.light, nearer.light, "a card further back is dimmer")
        }
        XCTAssertEqual(IslandPlace.deck(1).lean, IslandPlace.lean, accuracy: 0.0001,
                       "one back is one lean")
        XCTAssertEqual(IslandPlace.deck(1).scale, 1 - IslandPlace.shrink, accuracy: 0.0001,
                       "one back is one shrink")

        // A pile deeper than it's meant to be stays visible rather than
        // vanishing: the floors are floors, not a suggestion.
        XCTAssertGreaterThanOrEqual(IslandPlace.deck(50).scale, 0.6, "a very deep card is small, not nothing")
        XCTAssertGreaterThanOrEqual(IslandPlace.deck(50).light, 0.35, "a very deep card is dim, not dark")
    }

    /// A card behind is cut to a slice, then drawn small and tipped — and
    /// the slice it's cut to has to survive both, or the card in front of
    /// it shows a seam of nothing where the pile should be solid. The cut
    /// is asked for more than the slice it means to fill, precisely
    /// because the transforms only ever take away, and a pile whose cards
    /// exactly met is a pile that parts on the frames the perspective is
    /// rounded in.
    func testTheCutOfABuriedCardSurvivesBeingDrawnSmallAndTipped() {
        for level in 1..<IslandPlace.stack + 2 {
            let deck = IslandPlace.deck(level)
            let drawn = IslandPlace.cut(level) * deck.scale * cos(deck.lean * .pi / 180)
            XCTAssertGreaterThanOrEqual(drawn, IslandPlace.peek,
                                        "level \(level) is drawn at least the slice it stands for")
            XCTAssertLessThan(drawn, IslandPlace.peek * 1.2,
                              "level \(level) overlaps a little, not a lot")
        }
        // The front card is never cut: it's the whole card, or it isn't
        // the front.
        XCTAssertEqual(IslandPlace.deck(0).lean, 0, "the front card isn't tipped")
        XCTAssertEqual(IslandPlace.deck(0).scale, 1, "the front card isn't shrunk")
    }

    /// The pile's geometry: where each card's top edge sits, and that
    /// straightening the pile is the same order read flat — no card
    /// passes another on the way out, which is the whole reason the
    /// newest is at the front of the pile and the last of the list.
    func testThePileRecedesUpAndStraightensIntoTheSameOrder() {
        let cards: [CGFloat] = [40, 40, 40]
        XCTAssertEqual(IslandPlace.piled(cards), [2 * IslandPlace.peek, IslandPlace.peek, 0],
                       "the newest is at the front of the pile, the rest above it")
        XCTAssertEqual(IslandPlace.laid(cards), [2 * (40 + IslandPlace.gap), 40 + IslandPlace.gap, 0],
                       "straightened, the newest is the last of the list")

        // Whatever the cards' heights, both are read newest-last.
        let ragged: [CGFloat] = [20, 60, 30, 50]
        let piled = IslandPlace.piled(ragged)
        let laid = IslandPlace.laid(ragged)
        XCTAssertEqual(piled, piled.sorted(by: >), "a pile recedes: the newest is the lowest")
        XCTAssertEqual(laid, laid.sorted(by: >), "a list reads down: the newest is the lowest")
        XCTAssertEqual(piled.count, laid.count, "every card is in both")
        XCTAssertEqual(piled.last, 0, "the front of the pile is the front card")
        XCTAssertEqual(laid.last, 0, "the bottom of the list is the newest card")
    }

    /// The bar as it's drawn, with no window and no cursor: the closed
    /// stack is one card and a sliver of each one under it, the open one
    /// is every card whole, and both are the same numbers the shape is
    /// worked out in (IslandPlace) — so the drawing and the arithmetic
    /// can't drift apart without this failing.
    @MainActor
    func testTheBarDrawsAStackOfCardsAndOpensThem() throws {
        let island = Island.shared
        let run = UUID().uuidString.prefix(8)
        func said(_ name: String, _ id: String, tool: String? = nil) -> IslandEvent {
            IslandEvent(
                source: "claude", name: name, session: id, tty: "/dev/ttys004",
                cwd: "/Users/someone/www/github/search", tool: tool, call: nil,
                prompt: nil, words: nil
            )
        }
        let ids = (0..<3).map { "card-\(run)-\($0)" }
        // Three agents, each on a tool: three cards of the same height,
        // which is what makes the drawing's numbers checkable — the top
        // one is a card, and so are the ones under it.
        for id in ids { island.heard(said("PreToolUse", id, tool: "Bash")) }
        defer { for id in ids { island.heard(said("SessionEnd", id)) } }
        XCTAssertEqual(island.sessions.filter { ids.contains($0.id.replacingOccurrences(of: "claude/", with: "")) }.count, 3,
                       "three agents, three cards")

        // The width, the place and how far down are the bar's own kept
        // say-so: pinned here so the drawing is the same on anybody's
        // Mac as it is in this run.
        let kept = UserDefaults.standard
        let was = (kept.object(forKey: "island.center"), kept.object(forKey: "island.width"), kept.object(forKey: "island.down"))
        kept.set(0.5, forKey: "island.center")
        kept.set(360.0, forKey: "island.width")
        kept.set(0.0, forKey: "island.down")
        defer {
            kept.set(was.0, forKey: "island.center")
            kept.set(was.1, forKey: "island.width")
            kept.set(was.2, forKey: "island.down")
        }

        func height(_ open: Bool) throws -> CGFloat {
            let host = NSHostingView(rootView: IslandBar(room: CGSize(width: 1200, height: 800), opened: open))
            host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            // Laid out, then laid out again after the run loop has had
            // a turn — the way a window gets it — so what's measured is
            // the bar settled rather than the bar mid-draw.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.close()
            XCTAssertTrue(size.height > 0, "the bar drew something to measure")
            return size.height
        }

        // What the bar is holding, read through the same rule the bar
        // itself reads it by (Island.held's filter and order, then the
        // stack's own shape): so this holds whatever else the run left in
        // the island, and what's being checked is the numbers rather than
        // the state. Open is every card; closed is the few that peek.
        let watching = Island.watched
        let rank = Dictionary(island.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { one, _ in one })
        let all = island.sessions
            .filter { $0.tty != watching && !island.shelved.contains($0.id) }
            .sorted { a, b in
                switch (rank[a.id], rank[b.id]) {
                case let (one?, two?): return one < two
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a.at > b.at
                }
            }
        XCTAssertGreaterThanOrEqual(all.count, 3, "this test's own cards are held")

        let open = try height(true)
        XCTAssertEqual(open, IslandPlace.opened(all.map(IslandPlace.card), room: 800), accuracy: 1,
                       "open, the bar is every card whole with the air between them")

        let closed = try height(false)
        let deep = Array(all.prefix(IslandPlace.showing(all.count)))
        XCTAssertEqual(closed, IslandPlace.closed(deep.map(IslandPlace.card)),
                       accuracy: 1, "closed, the bar is the front card and a slice of each one behind it")
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

    /// An install that was installed stays usable: the command and the pi
    /// script are written again from today's text, so a fix reaches agents
    /// somebody hooked weeks ago. Nothing else is touched — an agent
    /// nobody installed stays that way.
    func testWhatWasInstalledIsKeptCurrent() throws {
        let home = room
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        let uninstalled = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: uninstalled, withIntermediateDirectories: true)
        let bridge = home.appendingPathComponent("Application Support/search-island.sh").path

        // As an older version left it: the path unquoted, which sh split
        // on the space in "Application Support", and an extension that
        // says nothing of where pi keeps its record.
        let settings = claude.appendingPathComponent("settings.json")
        let ours: [[String: Any]] = [["type": "command", "command": bridge + " claude"]]
        let row: [String: Any] = ["hooks": ours]
        try json(["hooks": Dictionary(uniqueKeysWithValues: IslandHooks.said.map { ($0, [row]) })])
            .write(to: settings)
        let extensions = home.appendingPathComponent(".pi/agent/extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try "// an old copy".write(
            to: extensions.appendingPathComponent(IslandHooks.piName), atomically: true, encoding: .utf8
        )

        IslandHooks.keepCurrent(bridge, home: home)

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        let hook = (after?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
        let command = (hook?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(command, "'" + bridge + "' claude", "the path is quoted, so sh keeps it one word")
        XCTAssertEqual(
            (hook ?? []).count, 1,
            "the old row is replaced, not joined by a second one"
        )
        let script = try String(
            contentsOf: extensions.appendingPathComponent(IslandHooks.piName), encoding: .utf8
        )
        XCTAssertTrue(script.contains("_sessionFile"), "the extension says where the record is")
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: uninstalled.path))?.isEmpty, true,
            "an agent nobody installed into is left alone"
        )
    }

    /// The bridge is written once, runs (not just sits), and says the
    /// socket by the user's own id and the source it's told — the two
    /// things the server reads of it.
    func testTheBridgeIsWrittenAndRuns() throws {
        let bridge = try IslandHooks.writeBridge(room)
        let text = try String(contentsOf: URL(fileURLWithPath: bridge), encoding: .utf8)
        XCTAssertTrue(text.contains("--unix-socket"), "the bridge speaks the socket")
        XCTAssertTrue(text.contains("X-Search-Source: ${1:-}"), "the bridge passes the source through")
        XCTAssertTrue(text.contains("X-Search-Event: ${2:-}"), "the bridge passes the moment through for the ones that don't say it")
        XCTAssertTrue(text.contains("hookSpecificOutput"), "only a decision is worth the agent's ears")
        XCTAssertTrue(bridge.hasSuffix("/" + IslandHooks.bridgeName), "the bridge is where it was put")
        // A hook is run with its output piped, so its own ps says ?? even
        // though its agent sits in a terminal: the walk up is the only way
        // the pane is ever named — and a pane never named is a chip never
        // shown (found live: claude on ttys006, hook said tty=??).
        XCTAssertTrue(text.contains("PID=$$"), "the bridge starts at itself")
        XCTAssertTrue(text.contains("ps -o tty=,ppid="), "and asks for the parent at the same time")
        XCTAssertTrue(text.contains("-lt 8"), "bounded, like pi's extension")
        XCTAssertFalse(
            text.contains("TTY=$(ps -o tty= -p $$ 2>/dev/null)"),
            "it does not trust its own terminal, which a hook never has"
        )
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

    /// Qwen Code borrowed Claude Code's contract whole but counts in
    /// milliseconds and hangs on a hook that doesn't say it's done, so
    /// every wait is said out loud: five seconds for a saying, the day
    /// for the permission. The source is its own, and the taking-back
    /// is as clean as the putting-in.
    func testQwenSWaitsAreSaidAndCountedItsOwnWay() throws {
        let home = room.appendingPathComponent("qwen", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try IslandHooks.installQwen(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.qwenHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("settings.json"))
        ) as? [String: Any]
        let hooks = settings?["hooks"] as? [String: Any]
        let said = ((hooks?["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(said?["command"] as? String, "/Where/search-island.sh qwen", "the bridge is told the source")
        XCTAssertEqual(said?["timeout"] as? Int, 5000, "a saying is waited on five seconds, said in Qwen's milliseconds")
        let held = ((hooks?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(held?["timeout"] as? Int, IslandHooks.heldLong * 1000, "the permission is waited on the day, in Qwen's milliseconds")

        try IslandHooks.installQwen(home, bridge: "/Where/search-island.sh")
        let again = try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("settings.json"))
        ) as? [String: Any]
        XCTAssertEqual(
            (((again?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.count), 1,
            "a second install takes the place of the first"
        )

        try IslandHooks.removeQwen(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.qwenHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
        let done = try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("settings.json"))
        ) as? [String: Any]
        XCTAssertNil(done?["hooks"], "nothing of ours is left, and the file was ours alone")
    }

    /// Droid took the contract as Claude wrote it, seconds and all: the
    /// same shape, its own home, its own source.
    func testDroidTookTheContractSecondsAndAll() throws {
        let home = room.appendingPathComponent("factory", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try IslandHooks.installDroid(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.droidHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        let hooks = (try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("settings.json"))
        ) as? [String: Any])?["hooks"] as? [String: Any]
        let said = ((hooks?["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(said?["command"] as? String, "/Where/search-island.sh droid", "the bridge is told the source")
        XCTAssertNil(said?["timeout"], "a saying is not waited on — it goes and is done with")
        let held = ((hooks?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(held?["timeout"] as? Int, IslandHooks.heldLong, "the permission is waited on, the day")

        try IslandHooks.removeDroid(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.droidHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
    }

    /// Gemini is watched, not asked: its before-tool is a veto on every
    /// tool, not a permission, so nothing of ours holds anything open
    /// and its own asking serves. Every wait is its own ten thousand,
    /// and its own events are the ones put in place.
    func testGeminiIsWatchedNotAsked() throws {
        let home = room.appendingPathComponent("gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try IslandHooks.installGemini(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.geminiHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        let hooks = (try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("settings.json"))
        ) as? [String: Any])?["hooks"] as? [String: Any]
        let said = ((hooks?["BeforeTool"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(said?["command"] as? String, "/Where/search-island.sh gemini", "the bridge is told the source")
        XCTAssertEqual(said?["timeout"] as? Int, 10_000, "the wait is Gemini's own ten seconds, in its milliseconds")
        XCTAssertNil(hooks?["PermissionRequest"], "nothing of ours is held open — Gemini asks its own way")

        try IslandHooks.removeGemini(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.geminiHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
    }

    /// Cursor's rows are flat — a command, no nest — and the saying
    /// carries no name for the moment, so the command carries it. What
    /// of the user's is there stays; what of ours is in place goes.
    func testCursorSIsFlatAndTheCommandCarriesTheMoment() throws {
        let home = room.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hooks = home.appendingPathComponent("hooks.json")
        try json([
            "hooks": [
                "afterFileEdit": [["command": "/Users/who/mine.sh"]],
            ],
        ]).write(to: hooks)

        try IslandHooks.installCursor(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.cursorHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any]
        let edit = ((after?["hooks"] as? [String: Any])?["afterFileEdit"] as? [[String: Any]])
        XCTAssertEqual(edit?.count, 2, "ours is beside theirs")
        XCTAssertEqual(edit?.last?["command"] as? String, "/Where/search-island.sh cursor afterFileEdit", "the moment is said by the command, for the saying doesn't")
        XCTAssertEqual(edit?.first?["command"] as? String, "/Users/who/mine.sh", "their row is as it was")

        try IslandHooks.removeCursor(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.cursorHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
        let done = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any]
        XCTAssertEqual(
            ((done?["hooks"] as? [String: Any])?["afterFileEdit"] as? [[String: Any]])?.count, 1,
            "their row is left, ours taken"
        )
    }

    /// Grok's hooks are a file of ours in the folder it scans — nothing
    /// of the user's touched, nothing of ours left, and a file empty of
    /// ours taken away rather than left as litter.
    func testGrokSIsAFileOfItsOwnInTheFolderItScans() throws {
        let home = room.appendingPathComponent("grok", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("hooks"), withIntermediateDirectories: true
        )
        // The user's own file in the same folder: not ours to touch.
        try json(["hooks": ["SessionStart": [["hooks": [["command": "/Users/who/mine"]]]]]]).write(
            to: home.appendingPathComponent("hooks").appendingPathComponent("mine.json")
        )

        try IslandHooks.installGrok(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.grokHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        let ours = try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("hooks").appendingPathComponent(IslandHooks.oursName))
        ) as? [String: Any]
        let said = (((ours?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(said?["command"] as? String, "/Where/search-island.sh grok", "the bridge is told the source")
        XCTAssertEqual(said?["timeout"] as? Int, 5, "the wait is Grok's own five seconds")
        XCTAssertNil((ours?["hooks"] as? [String: Any])?["PermissionRequest"], "no permission held open — Grok doesn't wait on one")

        try IslandHooks.removeGrok(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.grokHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent("hooks").appendingPathComponent(IslandHooks.oursName).path
            ), "a file of ours alone, empty of ours, is taken away"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks").appendingPathComponent("mine.json").path),
            "the user's own file in the folder is untouched"
        )
    }

    /// Copilot's waits are said its own way — its own word for the
    /// command, its own seconds — and the moment's name rides the
    /// command, for the saying doesn't carry it. The file is ours, but
    /// if a hand other than ours has put something in it, that hand's
    /// work outlives ours.
    func testCopilotSaysTheCommandItsOwnWay() throws {
        let home = room.appendingPathComponent("copilot", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try IslandHooks.installCopilot(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.copilotHooked(home, bridge: "/Where/search-island.sh"), "installed is hooked")
        let file = home.appendingPathComponent("hooks").appendingPathComponent(IslandHooks.oursName)
        let ours = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(ours?["version"] as? Int, 1, "the version is the shape Copilot reads")
        let said = ((ours?["hooks"] as? [String: Any])?["preToolUse"] as? [[String: Any]])?.first
        XCTAssertEqual(said?["bash"] as? String, "/Where/search-island.sh copilot preToolUse", "the command is Copilot's own word, the moment said with it")
        XCTAssertEqual(said?["timeoutSec"] as? Int, 5, "the wait is said Copilot's way")

        // A hand other than ours puts an event of its own in: the file
        // is shared ground now, and the taking-back leaves it standing.
        var withTheirs = ours ?? [:]
        var hooks = withTheirs["hooks"] as? [String: Any] ?? [:]
        hooks["userEvent"] = [["type": "command", "bash": "/Users/who/mine", "timeoutSec": 5]]
        withTheirs["hooks"] = hooks
        try json(withTheirs).write(to: file)

        try IslandHooks.removeCopilot(home, bridge: "/Where/search-island.sh")
        XCTAssertFalse(IslandHooks.copilotHooked(home, bridge: "/Where/search-island.sh"), "removed is unhooked")
        let done = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(
            ((done?["hooks"] as? [String: Any])?["userEvent"] as? [[String: Any]])?.count, 1,
            "their hand's work outlives ours"
        )
    }

    /// Oh My Pi runs the same extension as Pi, one home over, told its
    /// own source so the two never answer for each other.
    func testOhMyPiRunsTheSameFileOneHomeOver() throws {
        let home = room.appendingPathComponent("omp", isDirectory: true)
        XCTAssertFalse(IslandHooks.ompHooked(home), "a home that isn't there is not hooked")

        try IslandHooks.installOmp(home, bridge: "/Where/search-island.sh")
        XCTAssertTrue(IslandHooks.ompHooked(home), "the extension is the whole of being hooked")
        let text = try String(
            contentsOf: home.appendingPathComponent("extensions").appendingPathComponent(IslandHooks.piName),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("SOURCE = \"omp\""), "the extension is told its own source")
        XCTAssertTrue(text.contains("`${SOURCE}-${ctx.sessionManager.getSessionId()}`"), "the sessions are said by the source, so the two never answer for each other")

        try IslandHooks.removeOmp(home)
        XCTAssertFalse(IslandHooks.ompHooked(home), "taken away whole")
    }
}
