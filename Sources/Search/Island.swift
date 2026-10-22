import Foundation
import Network

// MARK: - What one hook said

/// One moment an agent told Search about, as one of its hooks said it:
/// which agent, which session of it, where it is, and what it was doing.
/// The body's shape is the CLIs' own — they borrowed it from one
/// another — while the source and the terminal come with the request
/// itself, where the bridge put them: the CLIs don't know either one.
struct IslandEvent {
    var source: String
    var name: String
    var session: String
    var tty: String?
    var cwd: String?
    var tool: String?
    var call: String?
    var prompt: String?
    var words: String?
}

/// The reading of what a hook said: pure work, nothing held. Everything
/// here takes what it's given and says what it made of it, so it can be
/// asked of anything, a test's line as easily a socket's.
enum IslandRead {
    /// Reads a hook's saying down to what the bar needs. What doesn't
    /// name a moment (`hook_event_name`, or Codex's `event_name`) isn't
    /// a saying at all — it's dropped whole rather than half-read.
    static func event(body: Data, source: String?, tty: String?, event: String? = nil) -> IslandEvent? {
        guard let raw = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        guard let said = say(raw["hook_event_name"]) ?? say(raw["event_name"]) ?? event,
              let name = moment(said) else { return nil }
        // A payload with no session of its own (Copilot's) is still one
        // agent in one terminal: the tty says which, and only a payload
        // with neither falls back to the one shared name.
        let session = say(raw["session_id"]) ?? tty ?? "default"
        return IslandEvent(
            source: source ?? say(raw["_source"]) ?? "",
            name: name,
            session: session,
            tty: tty ?? say(raw["_tty"]),
            cwd: say(raw["cwd"]),
            tool: say(raw["tool_name"]),
            call: call(raw["tool_input"]),
            prompt: say(raw["prompt"]),
            words: say(raw["last_assistant_message"]) ?? say(raw["message"])
        )
    }

    /// Every hook's own word for where the agent stands, folded onto
    /// the island's. Cursor and Copilot name their moments in camelCase
    /// and Gemini has words of its own, but a bar has just the one
    /// vocabulary; Cursor's payload carries no event name at all, so
    /// its word comes in on the request the bridge sends it with.
    /// Nothing worth a moment (Cursor's afterAgentThought — thinking
    /// mid-turn) says nothing. Grok's StopFailure is a turn ended on an
    /// error, still a turn ended, so it folds onto Stop too.
    static func moment(_ said: String) -> String? {
        switch said {
        // Cursor, camelCase
        case "beforeSubmitPrompt": return "UserPromptSubmit"
        case "beforeShellExecution", "beforeReadFile", "beforeFileEdit", "beforeMCPExecution": return "PreToolUse"
        case "afterShellExecution", "afterFileEdit", "afterMCPExecution": return "PostToolUse"
        case "afterAgentThought": return nil
        case "afterAgentResponse", "stop": return "Stop"
        // Gemini, words of its own
        case "BeforeAgent": return "UserPromptSubmit"
        case "BeforeTool": return "PreToolUse"
        case "AfterTool": return "PostToolUse"
        case "AfterAgent": return "Stop"
        // Copilot CLI, camelCase
        case "sessionStart": return "SessionStart"
        case "sessionEnd": return "SessionEnd"
        case "userPromptSubmitted": return "UserPromptSubmit"
        case "preToolUse": return "PreToolUse"
        case "postToolUse": return "PostToolUse"
        case "errorOccurred": return "Notification"
        // Grok
        case "StopFailure": return "Stop"
        default: return said
        }
    }

    /// A tool's input, said as a line a person can read at a glance: the
    /// one field that says what the tool is about — a command, a file, a
    /// page — taken the way the CLIs write it. An input with nothing of
    /// the kind in it says nothing, and that's kept as what it is.
    static func call(_ input: Any?) -> String? {
        guard let fields = input as? [String: Any] else { return nil }
        for field in ["command", "file_path", "path", "url", "query", "pattern", "description", "prompt"] {
            if let line = say(fields[field]) {
                return say(line)
            }
        }
        return nil
    }

    /// A string's own saying, trimmed of the whitespace hooks wrap
    /// things in and cut to what a bar can hold. Not a string, or an
    /// empty one: nothing, so the caller can tell said from unsaid.
    static func say(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > 160 else { return trimmed }
        let cut = trimmed.prefix(159)
        return cut + "…"
    }
}

// MARK: - The island

/// Every coding agent at work in a terminal, told about by hooks the
/// agents run themselves (put in place by hand, in Settings — see
/// IslandHooks). What arrives is shown in a bar over the page (IslandBar)
/// and answered there: an agent that has stopped to ask for permission
/// can be allowed, denied, or left to ask in its own terminal, without
/// leaving the tab you're on. An agent in the terminal you're watching is
/// left alone — its bar would say what the screen in front of you says
/// better — and one outside Search's terminals has a bar to be read but
/// no place to be jumped to.
@MainActor
final class Island: ObservableObject {
    static let shared = Island()

    /// Where the shore listens, in the one folder every user shares by
    /// name alone: the id in it is the user's own, so the socket is
    /// nobody else's to touch.
    static let path = "/tmp/search-island-\(getuid()).sock"

    /// One agent in one terminal: what it is to the bar, and what it's
    /// doing or asking. `at` is when it last said anything, so a session
    /// gone quiet can be told from one that's gone.
    struct Session: Identifiable {
        /// Where it stands with a person: at work, stopped to ask
        /// permission, stopped to be told something, or done and waiting
        /// to be read.
        enum Part: Int {
            case asking = 0, waiting, working, done
        }
        let id: String
        let source: String
        var part: Part
        var tool: String?
        var words: String?
        var tty: String?
        var cwd: String?
        var at: Date
    }

    /// A permission held open, waiting for a person: what was asked,
    /// and the way to answer it. Answering twice does nothing the second
    /// time — the hold is let go the moment it's answered.
    typealias Hold = IslandServer.Hold

    /// What a person says to a held permission: go ahead, don't, or ask
    /// it in the terminal it came from, where the CLI asks in its own way.
    enum Decision {
        case allow, deny, ownTerminal
    }

    @Published private(set) var sessions: [Island.Session] = []
    @Published private(set) var holds: [Island.Hold] = []

    private var server: IslandServer?

    /// Opens the island's socket, once, as the app comes up: before this
    /// nothing arrives, after it everything the hooks send does. A
    /// socket left behind by a run that ended badly is taken over — it
    /// can only be this user's own.
    func start() {
        guard server == nil else { return }
        // A test run doesn't take the socket: another test's is the same
        // path, and a real app's could be beside it, and the one taken
        // by whichever started last is the one the real hooks would
        // find, held by the run that can't answer for them. The
        // recording runs its own server with its own path instead.
        guard !Store.testing else { return }
        let shore = IslandServer(path: Island.path)
        shore.spoken = { [weak self] event in Task { @MainActor in self?.heard(event) } }
        shore.holding = { [weak self] hold in Task { @MainActor in self?.held(hold) } }
        shore.lost = { [weak self] hold in Task { @MainActor in self?.dropped(hold) } }
        server = shore
        shore.start()
    }

    // MARK: Keeping what the bar shows

    /// Takes in a saying and keeps what the bar shows of it. The names
    /// are the CLIs' own — the handful they all borrowed from Claude
    /// Code — and the ones that mean nothing here are read and dropped:
    /// a moment that isn't ours is not an error.
    func heard(_ event: IslandEvent) {
        let id = event.source + "/" + event.session
        // The permission itself never comes this way: it arrives held
        // open (`held`), and the saying that follows it — the CLI's own
        // "needs your permission" note — would say twice what's said
        // once.
        guard event.name != "PermissionRequest" else { return }
        switch event.name {
        case "SessionStart", "UserPromptSubmit":
            // Starting is starting, whatever was said before: a session
            // id is a run, and a run can only begin once.
            let fresh = Island.Session(
                id: id, source: event.source, part: .working, tool: nil, words: nil,
                tty: event.tty, cwd: event.cwd, at: Date()
            )
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i] = fresh }
            else { sessions.append(fresh) }
        case "PreToolUse":
            // The tool it's about to use, which is what the bar says of
            // the work. A session that starts mid-run (its start was
            // never said, or was said before the app came up) is made
            // here, from what it's doing.
            grow(id, event) { $0.part = .working; $0.tool = event.tool; $0.words = nil }
        case "PostToolUse", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Interrupt":
            // The work goes on; nothing new to say of it.
            break
        case "Notification":
            // The CLI's word that it's waiting on a person: something
            // to be typed, or asked in a way no hook carries. It stands
            // as waiting until the person goes to it.
            grow(id, event) { $0.part = .waiting; $0.words = event.words }
        case "Stop":
            // The end of a turn, with what the agent said last: the one
            // thing a person not watching wants to know. Kept until put
            // away — being told is the whole point of the bar.
            grow(id, event) { $0.part = .done; $0.words = event.words ?? "" }
            // Said where nobody's looking, so it's said the way a long
            // job in a terminal is (see Notifications): on the screen,
            // for whoever is somewhere else. A test run records it and
            // posts nothing, as always.
            if event.tty != Island.watched {
                SiteNotifications.shared.post(
                    tab: event.source,
                    title: "\(Island.name(event.source)) finished",
                    body: event.words ?? "The turn ended in a tab you're not watching."
                )
            }
        case "SessionEnd":
            // Said and done: the run is over and the session with it.
            let go = holds.filter { $0.event.source == event.source && $0.event.session == event.session }
            for hold in go { hold.answer(Data("{}".utf8)) }
            holds.removeAll { hold in go.contains { $0.id == hold.id } }
            sessions.removeAll { $0.id == id }
        default:
            break
        }
    }

    /// A permission has stopped to wait for a person. The session shows
    /// it as asking; the hold stays until answered here, handed back to
    /// its own terminal, or given up on (`dropped`, when the connection
    /// it came in on ends — the CLI timing out and asking its own way).
    /// This is what the server's asking comes to (the wiring is in
    /// `start`), and the whole of what a test needs to bring one in.
    func held(_ hold: IslandServer.Hold) {
        let id = hold.event.source + "/" + hold.event.session
        grow(id, hold.event) {
            $0.part = .asking
            $0.tool = hold.event.tool
            $0.words = hold.event.call
        }
        holds.append(hold)
    }

    /// Answers a held permission, in the shape the CLIs take: allowed
    /// or denied outright, or answered with nothing — their cue to ask
    /// in person, in the terminal the agent is in.
    func answer(_ hold: Island.Hold, _ decision: Island.Decision) {
        guard holds.contains(where: { $0.id == hold.id }) else { return }
        holds.removeAll { $0.id == hold.id }
        let id = hold.event.source + "/" + hold.event.session
        let bytes: Data
        switch decision {
        case .allow:
            bytes = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        case .deny:
            bytes = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        case .ownTerminal:
            bytes = Data("{}".utf8)
        }
        hold.answer(bytes)
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].part = decision == .ownTerminal ? .waiting : .working
            if decision != .ownTerminal { sessions[i].words = nil }
        }
    }

    /// The connection a held permission came in on has ended — the CLI
    /// timed out or left. The hold is let go and the session left
    /// waiting, where its own terminal is the one asking now.
    private func dropped(_ hold: Island.Hold) {
        holds.removeAll { $0.id == hold.id }
        let id = hold.event.source + "/" + hold.event.session
        if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].part == .asking {
            sessions[i].part = .waiting
        }
    }

    /// A terminal has ended, and with it every agent that was in it. The
    /// hooks can't say so themselves — a killed CLI never runs another
    /// hook — so the terminal's own end says it for them. Any hold still
    /// open from it is handed back empty, so a CLI waiting on it can go
    /// on asking its own way.
    func retired(tty: String?) {
        guard let tty else { return }
        for hold in holds where hold.event.tty == tty { hold.answer(Data("{}".utf8)) }
        holds.removeAll { $0.event.tty == tty }
        sessions.removeAll { $0.tty == tty }
    }

    /// Puts a session away: read, and done with. Only a done one can be
    /// put away — a working one is back in a moment, and an asking one
    /// still has a person to answer to.
    func putAway(_ session: Island.Session) {
        guard session.part == .done else { return }
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: Going to it

    /// Brings the agent's terminal to the front: the window, the tab,
    /// the pane. An agent running outside Search's terminals has a bar
    /// to be read and no place to be brought to.
    func visit(_ session: Island.Session) {
        guard let tty = session.tty else { return }
        for browser in Browsers.all {
            for tab in browser.tabs where tab.isTerminal {
                guard let splits = tab.madeShell, let pane = splits.pane(of: tty) else { continue }
                Browsers.show(browser)
                browser.select(tab)
                splits.focus(pane)
                return
            }
        }
    }

    /// The terminal the keys are in, if they're in one: the front
    /// window's own tab, the pane that holds them. Whatever agent is in
    /// that one is being watched already.
    static var watched: String? {
        guard let browser = Browsers.front, let tab = browser.active else { return nil }
        return tab.madeShell?.focusedTerminal?.pty
    }

    /// What the bar calls an agent, the names a person knows them by.
    static func name(_ source: String) -> String {
        switch source {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "pi": return "Pi"
        default: return source.isEmpty ? "Agent" : source.prefix(1).uppercased() + source.dropFirst()
        }
    }

    // MARK: Inside

    /// Keeps a session's place in the list: what it already had, said
    /// over with what this event said of it. A session never heard from
    /// before is begun here from what it's doing — a run that started
    /// before the app did has no start to be heard.
    private func grow(_ id: String, _ event: IslandEvent, _ then: (inout Island.Session) -> Void) {
        let i = sessions.firstIndex(where: { $0.id == id })
        var session = i.map { sessions[$0] }
            ?? Island.Session(
                id: id, source: event.source, part: .working, tool: nil, words: nil,
                tty: event.tty, cwd: event.cwd, at: Date()
            )
        then(&session)
        session.at = Date()
        if let i { sessions[i] = session } else { sessions.append(session) }
    }
}

// MARK: - The shore

/// The island's own socket: a listener on a unix socket, in the two
/// shapes the askers write. The bridge's curl writes HTTP, and holds
/// the line open waiting for its answer — that's what carries the
/// permissions, the one thing that must be answered. The pi extension
/// writes bare JSON and ends, wanting nothing back — that's what
/// carries the sayings. Nothing else is understood, and nothing that
/// can't be read is kept.
final class IslandServer {
    /// One permission held open: what was asked, and the way to answer
    /// it. Answering is safe at any time — after the connection is gone,
    /// an answer is simply dropped.
    struct Hold {
        let id = UUID()
        let event: IslandEvent
        let answer: (Data) -> Void
    }

    /// The bridge's HTTP request, read by hand: the path, the three
    /// headers the bridge knows and the body doesn't (the event comes on
    /// the request because Cursor's and Copilot's payloads carry no
    /// name of their own), and the body itself. curl writes exactly one
    /// request on exactly one connection, so a request whole by its own
    /// length is the whole conversation.
    struct Call {
        let path: String
        let source: String?
        let tty: String?
        let event: String?
        let body: Data
    }

    /// What's come in so far, made sense of. An HTTP request is whole
    /// when its body is, by its own said length; bare JSON has no length
    /// and is whole when the sender has ended or when it already says
    /// something whole (the reading is in `read`). Junk is junk.
    enum Shape {
        case http(Call, whole: Bool)
        case bare(Data)
        case junk
    }

    var spoken: ((IslandEvent) -> Void)?
    var holding: ((Hold) -> Void)?
    var lost: ((Hold) -> Void)?

    /// A saying past this many bytes is not a saying — it's something
    /// gone wrong on the other end — and the connection is dropped
    /// whole rather than read forever.
    static let most = 10 * 1024 * 1024

    private let listener: NWListener?
    private let queue = DispatchQueue(label: "search.island")
    private var held: [UUID: (connection: NWConnection, hold: Hold)] = [:]

    init(path: String) {
        // A socket left behind by a run that ended badly is taken over:
        // nobody but this user could have made it (the path carries the
        // user's own id), and the file standing in the way serves no one.
        unlink(path)
        // The socket is this user's alone, and it is that from the
        // moment it exists: umask makes it so before the listener does,
        // because between a file's making and its tightening is a
        // moment anybody could read through.
        let was = umask(0o077)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        listener = try? NWListener(using: params)
        guard listener != nil else { umask(was); return }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                umask(was)
                // Said again in case umask didn't take: the one
                // permission that matters, said one way or both.
                chmod(path, 0o700)
            } else if case .failed = state {
                umask(was)
            }
        }
    }

    /// Starts listening. Never mind failing: the island is a watching,
    /// not a way of working — without it nothing breaks, the agents
    /// just go unnoticed.
    func start() {
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.queue.async { self.take(connection) }
        }
        listener?.start(queue: queue)
    }

    // MARK: One connection

    private func take(_ connection: NWConnection) {
        let id = UUID()
        // An end before anything came of it matters only when something
        // was being held: that's a permission given up on, and it has to
        // be said so the hold can be let go (Island.dropped).
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.queue.async {
                    if let (_, hold) = self.held.removeValue(forKey: id) {
                        self.lost?(hold)
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        read(connection, soFar: Data())
    }

    private func read(_ connection: NWConnection, soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, ended, error in
            guard let self else { connection.cancel(); return }
            self.queue.async {
                var data = soFar
                if let content { data.append(content) }
                // Not a saying, and never going to be one.
                guard data.count <= IslandServer.most else { connection.cancel(); return }
                switch IslandServer.shape(data) {
                case .http(let call, whole: true):
                    self.take(connection, call: call)
                case .http:
                    // Still coming — and a partial request at an end is
                    // nothing to take: let it go.
                    if ended || error != nil { connection.cancel() }
                    else { self.read(connection, soFar: data) }
                case .bare(let body):
                    // Bare JSON is whole when the sender has ended — or
                    // when it already says something whole, for the
                    // senders that cannot say they're done (the test's
                    // own among them: a raw connect is not the test
                    // runner's to make, and Network's connection cannot
                    // end its own saying).
                    let said = ended || error != nil
                        || IslandRead.event(body: body, source: nil, tty: nil) != nil
                    if said { self.take(connection, whole: data) }
                    else { self.read(connection, soFar: data) }
                case .junk:
                    connection.cancel()
                }
            }
        }
    }

    // MARK: Reading it

    /// What's come in so far, made sense of. HTTP is known by its ask;
    /// bare JSON is everything else a hook would write.
    static func shape(_ data: Data) -> Shape {
        guard !data.isEmpty else { return .junk }
        guard data.starts(with: Data("POST".utf8)) else { return .bare(data) }
        guard let head = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return .http(partial(), whole: false) }
        let lines = String(decoding: data[..<head.lowerBound], as: UTF8.self)
            .split(separator: "\r\n", omittingEmptySubsequences: false)
        var path = ""
        var source: String?
        var tty: String?
        var event: String?
        var length = 0
        for (i, line) in lines.enumerated() {
            if i == 0 {
                let words = line.split(separator: " ")
                path = words.count > 1 ? String(words[1]) : ""
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "x-search-source": source = value
            case "x-search-tty": tty = value
            case "x-search-event": event = value
            case "content-length": length = Int(value) ?? 0
            default: break
            }
        }
        let body = data[head.upperBound...]
        let whole = body.count >= max(length, 0)
        let call = Call(
            path: path, source: source, tty: tty, event: event,
            body: Data(body.prefix(max(length, 0)))
        )
        return .http(call, whole: whole)
    }

    /// The call a half-read request stands for: nothing in it yet, and
    /// never whole — it exists so a still-coming request has a shape to
    /// be held in.
    private static func partial() -> Call {
        Call(path: "", source: nil, tty: nil, event: nil, body: Data())
    }

    // MARK: Answering

    private func take(_ connection: NWConnection, call: Call) {
        guard let event = IslandRead.event(body: call.body, source: call.source, tty: call.tty, event: call.event) else {
            reply(connection, with: Data("{}".utf8))
            return
        }
        guard event.name == "PermissionRequest" else {
            reply(connection, with: Data("{}".utf8))
            spoken?(event)
            return
        }
        // The permission is held open: this connection isn't answered
        // until a person says, and the hold is the way they say it.
        let id = UUID()
        let hold = Hold(event: event) { [weak self] bytes in
            self?.queue.async { self?.answer(id, with: bytes) }
        }
        held[id] = (connection, hold)
        holding?(hold)
    }

    private func take(_ connection: NWConnection, whole data: Data) {
        // Bare JSON, ended by the sender: read for the say of it, and
        // answered bare in kind — nothing waits for the answer, but the
        // conversation stays in one shape.
        if let event = IslandRead.event(body: data, source: nil, tty: nil) {
            spoken?(event)
            connection.send(
                content: Data("{}".utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        } else {
            connection.cancel()
        }
    }

    /// Answers, in the shape the ask came in, and ends the conversation
    /// there: nothing over this socket is ever more than one ask and one
    /// answer.
    private func reply(_ connection: NWConnection, with body: Data) {
        let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + body,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func answer(_ id: UUID, with body: Data) {
        // The hold was let go already — the connection ended, and the
        // asking was said to have been given up on — so this is an answer
        // with nobody left to hear it, dropped.
        guard let (connection, _) = held.removeValue(forKey: id) else { return }
        reply(connection, with: body)
    }
}
