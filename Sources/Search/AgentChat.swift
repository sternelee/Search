import Foundation

// A coding agent's own record of its talk, read as a conversation.
//
// Three agents write three shapes into three files, and all three are
// JSONL appends — one record per line, never rewritten. That is what
// makes a conversation readable while it is still being written: a
// reader keeps its offset, reads what was added since, and a new line
// is a new piece of the talk. The shapes differ enough to need three
// readers, but they agree on what a talk is made of: what the person
// said, what the agent said, what it thought before saying it, and the
// tools it used with what they answered.
//
// What is deliberately shared, and where the traps are:
// - A tool's answer arrives in a later line than its call, so calls are
//   held by id until their answer shows up. An answer with no call (a
//   line cut short, a record from a compacted history) is dropped rather
//   than shown as an orphan tool.
// - Internal bookkeeping is not conversation: hook attachments, cost
//   lines, mode switches, subagent side chains, injected context. Each
//   reader names what it keeps, not what it drops, so a new record type
//   in some future version reads as nothing instead of as the agent's
//   words.
// - A line is only taken when it is complete. The file being written
//   ends in a partial record more often than not, and that partial
//   record is carried to the next read rather than parsed.
struct ChatLog {
    enum Role {
        case person, agent
    }

    struct Tool: Equatable {
        var name: String
        var summary: String
        var input: String
        var output: String
        /// The tool said it failed — the same words in a different light.
        var failed: Bool
    }

    /// What a turn cost, in the units all three agents agree on. Their
    /// field names differ (Claude's `input_tokens`, Pi's `input`, Codex's
    /// `last_token_usage`) but the meaning is the same, and a footer
    /// quoting one agent's spelling would read as nothing to anyone else.
    struct Usage: Equatable {
        var input: Int = 0
        var output: Int = 0
        /// Tokens served from the prompt cache — billed differently, and
        /// usually the largest number in the record, so a footer that
        /// left them out would look like a rounding error.
        var cached: Int = 0

        var worth: Bool { input + output + cached > 0 }

        func merging(_ other: Usage) -> Usage {
            var both = self
            both.add(other)
            return both
        }

        mutating func add(_ other: Usage) {
            // The largest, not the sum: an agent reports the same turn's
            // usage more than once (a streamed answer writes a line per
            // block), and adding those would multiply the count by the
            // number of lines it took to say.
            input = max(input, other.input)
            output = max(output, other.output)
            cached = max(cached, other.cached)
        }
    }

    enum Part: Equatable {
        case word(String)
        case thought(String)
        case tool(Tool)
    }

    struct Turn: Identifiable, Equatable {
        let id: Int
        let role: Role
        var at: Date?
        /// When the last thing in the turn was written. The difference is
        /// how long the turn took — the one measure of "generation time"
        /// all three transcripts carry, because none of them writes a
        /// duration of its own.
        var until: Date? = nil
        var usage: Usage? = nil
        var parts: [Part]

        /// Whether anything in the turn is worth a row: an empty answer
        /// (a tool-only step with no words) is still a row, but a turn
        /// whose every part was dropped is not.
        var worth: Bool { !parts.isEmpty }

        /// Whether any tool in the turn said it failed.
        var broke: Bool {
            parts.contains {
                if case .tool(let tool) = $0 { return tool.failed }
                return false
            }
        }
    }

    let agent: AgentTalk.Agent
    private(set) var turns: [Turn] = []
    /// How many times anything in it changed. A view redraws on a change
    /// of this rather than by comparing conversations, which would cost a
    /// walk of the whole talk per tick for an answer that is one number.
    private(set) var revision = 0
    /// Where each tool's call sits, by the id its answer will name.
    private var calls: [String: (turn: Int, part: Int)] = [:]
    /// The tail of the file that is not a complete line yet.
    private var carry = Data()

    /// What the run is holding in its window right now: the newest turn's
    /// input — the cached part included, since a cache read is still in the
    /// window — plus what that turn answered. Not a sum over the talk: an
    /// agent's window holds the conversation once, and adding every turn's
    /// input would count the same words again for every turn that carried
    /// them.
    var spent: Int {
        for turn in turns.reversed() {
            guard let usage = turn.usage, usage.worth else { continue }
            return usage.input + usage.cached + usage.output
        }
        return 0
    }

    /// True while the agent is mid-work, read off the file rather than
    /// asked of the screen: a person's question nobody has answered yet, a
    /// tool it reached for, or a thought it is still in the middle of. An
    /// answer — the last thing said being the agent's own words — ends it.
    /// This is what puts the working row under the talk and takes it away.
    var working: Bool {
        guard let last = turns.last else { return false }
        if last.role == .person { return true }
        guard let tail = last.parts.last else { return true }
        switch tail {
        case .word: return false
        case .thought, .tool: return true
        }
    }
    /// How much the run's model can hold, when the agent writes it down.
    /// Codex is the one that does, once per turn; for the others the
    /// number comes from the catalog instead, so this stays nil.
    private(set) var window: Int? = nil

    init(agent: AgentTalk.Agent) {
        self.agent = agent
    }

    /// A conversation is what the file has added since the last read;
    /// `turns` is the whole of it afterwards.
    mutating func read(_ data: Data) {
        var buffer = carry
        buffer.append(data)
        // A record ends at a newline. What is left after the last one is
        // being written right now and parses as garbage if taken.
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if !line.isEmpty { take(Data(line)) }
            start = buffer.index(after: newline)
        }
        carry = Data(buffer[start...])
        // A file that ends in a complete record with no trailing newline
        // is a real thing (a process killed mid-append never wrote one),
        // but it is caught by the next read that adds one; holding it
        // costs nothing and taking it would show a half record.
    }

    // MARK: - One line, three shapes

    private mutating func take(_ line: Data) {
        guard let raw = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch agent {
        case .claude: takeClaude(raw)
        case .pi: takePi(raw)
        case .codex: takeCodex(raw)
        }
    }

    /// Claude Code: `{"type":"user"|"assistant","message":{"role":…,"content":[…}}`.
    /// The blocks are the content; the line's own type is a copy of the
    /// message's role, and a line that is neither is bookkeeping.
    private mutating func takeClaude(_ raw: [String: Any]) {
        let type = raw["type"] as? String ?? ""
        guard type == "user" || type == "assistant" else { return }
        // A subagent's talk is a talk of its own, held in the same file
        // and marked as a side chain. It would read as the main agent's.
        if (raw["isSidechain"] as? Bool) == true { return }
        guard let message = raw["message"] as? [String: Any] else { return }
        let at = date(raw["timestamp"])
        // What the turn cost, written on the same line as the answer.
        let cost = Self.usage(message["usage"])
        let role: Role = type == "assistant" ? .agent : .person
        let blocks = message["content"]
        if let text = blocks as? String {
            // A typed line arrives whole, and it is the person's.
            if role == .person, let words = personWords(text) { add(role: role, at: at, .word(words)) }
            return
        }
        guard let blocks = blocks as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String ?? "" {
            case "text":
                let text = block["text"] as? String ?? ""
                if role == .person {
                    if let words = personWords(text) { add(role: role, at: at, .word(words), usage: cost) }
                } else if !text.trimmed.isEmpty {
                    add(role: role, at: at, .word(text), usage: cost)
                }
            case "thinking":
                let text = block["thinking"] as? String ?? ""
                if !text.trimmed.isEmpty { add(role: role, at: at, .thought(text), usage: cost) }
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? "tool"
                let input = block["input"].map(json) ?? ""
                add(role: .agent, at: at, .tool(Tool(
                    name: name, summary: summary(of: name, input: block["input"]), input: input, output: "", failed: false
                )), holding: id, usage: cost)
            case "tool_result":
                let id = block["tool_use_id"] as? String ?? ""
                let said = text(block["content"])
                answer(id, said, failed: (block["is_error"] as? Bool) ?? false, at: at)
            default:
                break
            }
        }
    }

    /// Pi: `{"type":"message","message":{"role":…,"content":[…]}}`, with
    /// tool calls and their answers as blocks of their own — a result is
    /// a `toolResult` *message*, not a block in an agent's answer.
    private mutating func takePi(_ raw: [String: Any]) {
        guard raw["type"] as? String == "message", let message = raw["message"] as? [String: Any] else { return }
        let role = message["role"] as? String ?? ""
        let at = date(raw["timestamp"]) ?? date(message["timestamp"])
        let cost = Self.usage(message["usage"])
        let blocks = message["content"]
        if let text = blocks as? String {
            if role == "user", let words = personWords(text) { add(role: .person, at: at, .word(words)) }
            return
        }
        guard let blocks = blocks as? [[String: Any]] else { return }
        // A tool's answer is a message of its own, under its own role.
        if role == "toolResult" {
            let id = message["toolCallId"] as? String ?? ""
            answer(id, text(message["content"]), failed: (message["isError"] as? Bool) ?? false, at: at)
            return
        }
        for block in blocks {
            switch block["type"] as? String ?? "" {
            case "text":
                let said = block["text"] as? String ?? ""
                if role == "user" {
                    if let words = personWords(said) { add(role: .person, at: at, .word(words), usage: cost) }
                } else if !said.trimmed.isEmpty {
                    add(role: .agent, at: at, .word(said), usage: cost)
                }
            case "thinking":
                let said = block["thinking"] as? String ?? ""
                if !said.trimmed.isEmpty { add(role: .agent, at: at, .thought(said), usage: cost) }
            case "toolCall":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? "tool"
                add(role: .agent, at: at, .tool(Tool(
                    name: name, summary: summary(of: name, input: block["arguments"]),
                    input: block["arguments"].map(json) ?? "", output: "", failed: false
                )), holding: id, usage: cost)
            default:
                break
            }
        }
    }

    /// Codex: a rollout of `response_item` records, each a `payload` with
    /// its own type — and the same message said twice, once as a
    /// `response_item` and once as an `event_msg`. The response item is
    /// the one kept: it is the transcript, the event is the display cue.
    private mutating func takeCodex(_ raw: [String: Any]) {
        // A token count is an `event_msg` of its own, arriving after the
        // answer it counted — the one thing in this file that is not a
        // `response_item` and is still worth keeping.
        if raw["type"] as? String == "event_msg" {
            guard let payload = raw["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any]
            else { return }
            // `last_token_usage` is this turn; `total_token_usage` is the
            // whole session, which would put the same growing number
            // under every answer.
            if let cost = Self.usage(info["last_token_usage"] ?? info["total_token_usage"]) {
                counted(cost)
            }
            return
        }
        // What the run can hold, stated by Codex itself at the top of each
        // turn. This is the one place any of the three agents writes the
        // window into the record, so the chat reads it here rather than
        // keeping a table of models that would go stale.
        if raw["type"] as? String == "turn_context" {
            let said = raw["payload"] as? [String: Any] ?? [:]
            if let window = said["model_context_window"] as? Int, window > 0 {
                self.window = window
            }
            return
        }
        guard raw["type"] as? String == "response_item",
              let payload = raw["payload"] as? [String: Any] else { return }
        let at = date(raw["timestamp"])
        switch payload["type"] as? String ?? "" {
        case "message":
            guard let role = payload["role"] as? String else { return }
            // An agent's answer addressed to a specific recipient is a
            // message to a tool, not to the person.
            if role == "assistant", let to = payload["recipient"] as? String, to != "all" { return }
            let said = contentText(payload["content"])
            if role == "user" {
                if let words = personWords(said) { add(role: .person, at: at, .word(words)) }
            } else if !said.trimmed.isEmpty {
                add(role: .agent, at: at, .word(said))
            }
        case "reasoning":
            // The summary, not the raw reasoning: the latter is a private
            // chain of thought Codex encrypts or omits.
            let said = contentText(payload["summary"])
            if !said.trimmed.isEmpty { add(role: .agent, at: at, .thought(said)) }
        case "function_call", "custom_tool_call", "local_shell_call":
            let id = payload["call_id"] as? String ?? ""
            let name = payload["name"] as? String ?? "shell"
            let arguments = payload["arguments"] ?? payload["input"]
            add(role: .agent, at: at, .tool(Tool(
                name: name, summary: summary(of: name, input: arguments),
                input: arguments.map(json) ?? "", output: "", failed: false
            )), holding: id)
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            answer(payload["call_id"] as? String ?? "", contentText(payload["output"]), failed: false, at: at)
        default:
            break
        }
    }

    // MARK: - Putting one part down

    private mutating func add(
        role: Role, at: Date?, _ part: Part, holding id: String? = nil, usage: Usage? = nil
    ) {
        // An agent's parts arrive together and belong to one turn: a
        // thought, a tool, a word said in one breath are one answer, and
        // the transcript writes them as separate blocks of one line. A
        // person's saying is a turn on its own — two lines in a row are
        // two sayings, not one person talking twice in one breath.
        if role == .agent, let last = turns.last, last.role == .agent {
            var turn = turns[turns.count - 1]
            turn.parts.append(part)
            if let at { turn.until = at }
            if let usage { turn.usage = (turn.usage ?? Usage()).merging(usage) }
            turns[turns.count - 1] = turn
        } else {
            turns.append(Turn(
                id: turns.count, role: role, at: at, until: at, usage: usage, parts: [part]
            ))
        }
        revision += 1
        if let id, !id.isEmpty {
            calls[id] = (turns.count - 1, turns[turns.count - 1].parts.count - 1)
        }
    }

    /// Usage that arrives on a line of its own, with no part of the talk
    /// to hang it on: Codex writes a token count as its own event after
    /// the answer it belongs to. It goes on the last thing the agent
    /// said, which is the turn it was counted for.
    private mutating func counted(_ usage: Usage) {
        guard let last = turns.last, last.role == .agent else { return }
        var turn = turns[turns.count - 1]
        turn.usage = (turn.usage ?? Usage()).merging(usage)
        turns[turns.count - 1] = turn
        revision += 1
    }

    private mutating func answer(_ id: String, _ output: String, failed: Bool, at: Date? = nil) {
        guard !id.isEmpty, let where_ = calls.removeValue(forKey: id) else { return }
        guard where_.turn < turns.count, where_.part < turns[where_.turn].parts.count else { return }
        guard case .tool(var tool) = turns[where_.turn].parts[where_.part] else { return }
        tool.output = output
        tool.failed = failed
        turns[where_.turn].parts[where_.part] = .tool(tool)
        if let at { turns[where_.turn].until = at }
        revision += 1
    }

    /// The usage fields of one line, named the way that agent names them.
    /// Absent fields stay zero rather than becoming a wrong number: a
    /// footer that guessed would be worse than one that says less.
    private static func usage(_ raw: Any?) -> Usage? {
        guard let fields = raw as? [String: Any] else { return nil }
        func count(_ keys: [String]) -> Int {
            for key in keys {
                if let n = fields[key] as? Int { return n }
                if let n = fields[key] as? Double { return Int(n) }
            }
            return 0
        }
        let usage = Usage(
            input: count(["input_tokens", "input"]),
            output: count(["output_tokens", "output"]),
            cached: count(["cache_read_input_tokens", "cacheRead", "cached_input_tokens"])
        )
        return usage.worth ? usage : nil
    }

    // MARK: - Reading the shapes' loose ends

    /// A person's line, with the wrappers the CLIs put round what is not
    /// theirs taken out: a slash command's record is bookkeeping, and an
    /// injected context note is not something anyone said.
    private func personWords(_ text: String) -> String? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }
        for wrapper in ["<command-name>", "<local-command", "<task-", "<command-"] where trimmed.hasPrefix(wrapper) {
            return nil
        }
        // Codex and Claude both fence injected context in tags of their
        // own; those records are the harness talking, not the person.
        for wrapper in ["<user_instructions>", "<environment_context>", "<system-reminder>"] where trimmed.hasPrefix(wrapper) {
            return nil
        }
        return trimmed
    }

    /// A tool call in one line: what a person would call it, taken from
    /// the arguments a person would recognise — the command, the file,
    /// the pattern, the address.
    private func summary(of name: String, input: Any?) -> String {
        guard let fields = input as? [String: Any] else { return name }
        for key in ["command", "cmd", "file_path", "path", "pattern", "query", "url", "description"] {
            if let said = fields[key] as? String, !said.trimmed.isEmpty {
                let line = said.split(separator: "\n").first.map(String.init) ?? said
                return line.count > 120 ? String(line.prefix(117)) + "…" : line
            }
        }
        return name
    }

    /// Text out of a content field that may be a string, a list of blocks
    /// with `text`, or a list of blocks with `content`.
    private func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            if let text = block["input_text"] as? String { return text }
            if let text = block["output_text"] as? String { return text }
            if block["content"] != nil { return contentText(block["content"]) }
            return nil
        }.joined()
    }

    private func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let list = value as? [[String: Any]] { return contentText(list) }
        return ""
    }

    private func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return value as? String ?? "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func date(_ value: Any?) -> Date? {
        guard let said = value as? String else { return nil }
        return ChatLog.formatter.date(from: said)
    }

    private static let formatter: ISO8601DateFormatter = {
        let make = ISO8601DateFormatter()
        make.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return make
    }()
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Reading a file that is still being written

/// The file, and how far into it the conversation has been read. Every
/// look reads only what was added since the last one, so a 44 MB session
/// costs its last few kilobytes per tick rather than its whole self.
struct ChatReader {
    let talk: AgentTalk.Talk
    private(set) var log: ChatLog
    private var offset: UInt64 = 0
    /// What the file looked like when it was last read, so a file
    /// replaced or rewritten is read again from the top rather than
    /// continued at an offset that no longer means anything.
    private var stamp: FileStamp?

    struct FileStamp: Equatable {
        var size: UInt64
        var inode: UInt64
        var modified: Date
    }

    init(talk: AgentTalk.Talk) {
        self.talk = talk
        log = ChatLog(agent: talk.agent)
    }

    /// Reads what the file has added. The conversation afterwards is the
    /// whole of it, and the answer says whether anything came in — which
    /// is the only question a tick that changed nothing needs answered.
    @discardableResult
    mutating func update() -> Bool {
        // The talk said where it writes (or said nothing and named its
        // folder): a run whose first answer has not been written yet has
        // no file to read, and one appears later.
        guard let file = talk.file ?? AgentTalk.settle(talk) else { return false }
        guard let now = ChatReader.stamp(of: file) else { return false }
        if let stamp, stamp != now {
            // Rewritten: what was read is not what is there. A file that
            // only grew keeps its offset; anything else starts over.
            if now.size < stamp.size || now.inode != stamp.inode {
                log = ChatLog(agent: talk.agent)
                offset = 0
            }
        }
        self.stamp = now
        guard now.size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let added = try handle.readToEnd() ?? Data()
            offset += UInt64(added.count)
            guard !added.isEmpty else { return false }
            log.read(added)
            return true
        } catch {
            return false
        }
    }

    private static func stamp(of file: URL) -> FileStamp? {
        // A URL that has been asked once keeps answering with what it
        // saw then — the values are cached in the object itself on this
        // system — and a file being written changes under a URL held
        // from the first look. Each look asks a URL made for it.
        let file = URL(fileURLWithPath: file.path)
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .fileResourceIdentifierKey, .contentModificationDateKey]),
              let size = values.fileSize
        else { return nil }
        // The inode is what tells a rewritten file from an appended one;
        // the identifier Foundation gives is opaque, so it is hashed down
        // to a number rather than compared as one.
        let id = values.fileResourceIdentifier.map { "\($0)" } ?? ""
        return FileStamp(
            size: UInt64(size), inode: UInt64(truncatingIfNeeded: id.hashValue),
            modified: values.contentModificationDate ?? .distantPast
        )
    }
}
