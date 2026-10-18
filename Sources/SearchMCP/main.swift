import Foundation

// The bridge: Search as an agent CLI's hands. Claude Code, Codex and the
// rest speak MCP over stdio; the browser speaks the bench socket (one JSON
// object a line — see Agent.swift). This is the small program between them,
// one binary in the app bundle beside the browser itself, and it is all an
// agent needs: it opens pages of its own, sees each page as a numbered
// list of what it holds, and works it by those numbers.
//
//   list_pages                     the agent's pages, by name
//   open_page {url, label?}        a new one, named
//   snapshot {page, full?}         the page in words, a number a thing
//   act {page, verb, target, …}    click @12 · fill @3 words · press @3 Enter
//   read {page, target}            the words at a thing, its value, its link
//   wait {page, target|text|url}   until something is there
//   close_page {page}              gone when the agent says so
//
// Nothing here is a second implementation of the hands: every call goes to
// the socket as one `do: "agent"` request, so everything the bench stands
// for holds — the switch in Settings (the socket answers nothing without
// it), pages that are the bench's own, marked with a flask, never the
// person's, never in the session or the history, and nobody off this Mac.
//
// The protocol spoken over stdio is MCP's own half of it: initialize,
// tools/list, tools/call, ping — JSON-RPC 2.0, one object a line, the
// same shape the browser speaks to its own servers (see MCP.swift's Link,
// the other direction of the same wire).

// MARK: - the socket, one request a connection

/// One request to the bench socket, one answer back. The socket's own
/// patience answers even when nothing else does, so a blocking read is
/// never a wait without end.
func ask(_ request: [String: Any], at path: String) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Unreachable(words: "no socket to speak") }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let room = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < room else { throw Unreachable(words: "the socket's path is too long") }
    withUnsafeMutablePointer(to: &address.sun_path) { sun in
        sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
            _ = strlcpy(bytes, path, room)
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let joined = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard joined == 0 else {
        throw Unreachable(words: "Search isn't listening — turn on “Let a script drive Search” in its Settings")
    }
    // The browser's own patience answers everything it is asked; a browser
    // wedged on its main thread is the one thing that doesn't. Ninety
    // seconds is past every patience the bench has, and short of any wait
    // a client would sit out anyway.
    var patience = timeval(tv_sec: 90, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
    var out = try JSONSerialization.data(withJSONObject: request)
    out.append(0x0A)
    try out.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
            if n < 0 {
                if errno == EINTR { continue }
                throw Unreachable(words: "the socket wouldn't take the request")
            }
            sent += n
        }
    }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while buffer.last != 0x0A {
        let n = read(fd, &chunk, chunk.count)
        if n == 0 { break }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw Unreachable(words: "the browser took too long to answer")
            }
            break
        }
        buffer.append(contentsOf: chunk[0..<n])
    }
    guard let cut = buffer.firstIndex(of: 0x0A),
          let said = (try? JSONSerialization.jsonObject(with: buffer[buffer.startIndex..<cut])) as? [String: Any]
    else { throw Unreachable(words: "the socket said nothing") }
    return said
}

struct Unreachable: Error { let words: String }

// MARK: - the tools

/// One tool as MCP meets it: its name, the words that tell a model what it
/// is, what it takes (and what it can't be called without), and the bench
/// request it becomes. The names are the agent surface's own words (see
/// README, "An agent at the wheel"), so one vocabulary serves the shell,
/// the bot and the CLI alike.
struct Tool {
    let name: String
    let description: String
    let takes: [String: Any]
    let without: [String]
    let make: ([String: Any]) -> [String: Any]

    var listed: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": takes,
                "required": without,
            ] as [String: Any],
        ]
    }
}

/// A schema line: a string argument.
func string(_ about: String) -> [String: Any] {
    ["type": "string", "description": about] as [String: Any]
}
/// A schema line: a boolean argument.
func boolean(_ about: String) -> [String: Any] {
    ["type": "boolean", "description": about] as [String: Any]
}

let tools: [Tool] = [
    Tool(
        name: "list_pages",
        description: "Every page the agent has open, each with its id, its label, its address and title. Agent pages are the browser's bench tabs: marked with a flask, never one of the person's own.",
        takes: [:], without: []
    ) { _ in ["do": "agent", "action": "pages"] },
    Tool(
        name: "open_page",
        description: "Open a page of the agent's own and name it (short: letters, digits, dash). Comes back with the page's id and label — a label is how the other tools mean this page.",
        takes: ["url": string("The address to open"), "label": string("A short name for the page, like signin")],
        without: ["url"]
    ) { args in
            var request: [String: Any] = ["do": "agent", "action": "open", "url": args["url"] as? String ?? ""]
            if let label = args["label"] as? String { request["as"] = label }
            return request
    },
    Tool(
        name: "snapshot",
        description: "What a page holds, one line a thing: button \"Sign in\" @12, textbox \"Email\" @3, states such as [checked] in brackets. Hidden things are not listed; the whole page, not only what's in view, with full. The numbers (@n) last until the next snapshot, and are how act and read mean a thing.",
        takes: [
            "page": string("The page's label or id, from list_pages or open_page"),
            "full": boolean("The whole page, not only what's in view"),
        ],
        without: ["page"]
    ) { args in
            var request: [String: Any] = ["do": "agent", "action": "snapshot", "id": args["page"] as? String ?? ""]
            if args["full"] as? Bool == true { request["full"] = true }
            return request
    },
    Tool(
        name: "act",
        description: "Work the page: click, fill, press, select, check, uncheck, hover, scroll, clear, focus — or goto, whose target is an address. A target is a number from the snapshot (@12), words on the thing (text=Sign in), a role and name (loc=role:button[name='Sign in']), css=… or xpath=…. fill takes the text to type (pages hear it the way they listen — React included); press takes a key (Enter, Tab, Escape, ArrowDown); select takes an option.",
        takes: [
            "page": string("The page's label or id"),
            "verb": string("click, fill, press, select, check, uncheck, hover, scroll, clear, focus, goto"),
            "target": string("A number from the snapshot (@12), text=Words, loc=role:…, css=…, xpath=… — an address for goto"),
            "text": string("What fill types, select picks, or press presses"),
        ],
        without: ["page", "verb", "target"]
    ) { args in
            var request: [String: Any] = [
                "do": "agent", "action": "act", "id": args["page"] as? String ?? "",
                "verb": args["verb"] as? String ?? "", "target": args["target"] as? String ?? "",
            ]
            if let text = args["text"] as? String { request["text"] = text }
            return request
    },
    Tool(
        name: "read",
        description: "One thing of the page, closely: the words at it, the value it holds, where a link goes. Reads are free — nothing is changed.",
        takes: [
            "page": string("The page's label or id"),
            "target": string("A number from the snapshot (@12), or any target act would take"),
        ],
        without: ["page", "target"]
    ) { args in
            ["do": "agent", "action": "read", "id": args["page"] as? String ?? "", "target": args["target"] as? String ?? ""]
    },
    Tool(
        name: "wait",
        description: "Wait until something is so: a thing there (target), words on the page (text), or the page at an address (url). Without any of those, until the page has loaded. Says whether it came.",
        takes: [
            "page": string("The page's label or id"),
            "target": string("A thing to wait to be there"),
            "text": string("Words to wait to be on the page"),
            "url": string("An address the page should be at"),
        ],
        without: ["page"]
    ) { args in
            var request: [String: Any] = ["do": "agent", "action": "wait", "id": args["page"] as? String ?? ""]
            if let target = args["target"] as? String { request["target"] = target }
            if let text = args["text"] as? String { request["text"] = text }
            if let url = args["url"] as? String { request["url"] = url }
            return request
    },
    Tool(
        name: "close_page",
        description: "Close one of the agent's pages. Only the agent's own close: the person's tabs are never here.",
        takes: ["page": string("The page's label or id")],
        without: ["page"]
    ) { args in ["do": "agent", "action": "close", "id": args["page"] as? String ?? ""] },
]

// MARK: - MCP over stdio

/// One line out: a result, or an error, for the request it answers.
func say(_ id: Any?, result: [String: Any]) {
    var line: [String: Any] = ["jsonrpc": "2.0"]
    if let id { line["id"] = id }
    line["result"] = result
    write(line)
}

func say(_ id: Any?, error code: Int, _ words: String) {
    var line: [String: Any] = ["jsonrpc": "2.0"]
    if let id { line["id"] = id }
    line["error"] = ["code": code, "message": words]
    write(line)
}

func write(_ line: [String: Any]) {
    guard let data = (try? JSONSerialization.data(withJSONObject: line)) else { return }
    var out = Data(data)
    out.append(0x0A)
    out.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let n = write(STDOUT_FILENO, raw.baseAddress! + sent, raw.count - sent)
            if n <= 0 {
                if errno == EINTR { continue }
                exit(1)
            }
            sent += n
        }
    }
}

/// Where the browser's socket is: beside everything else it keeps, under
/// Application Support — the same place Store.file puts it in the app.
/// (A browser run straight out of .build is a test run, and keeps its
/// socket in "Search (test)" instead — name it with --socket there.)
func defaultSocket() -> String {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Search/bench.sock").path
}

// MARK: - one request handled

func handle(_ request: [String: Any], socket: String) {
    let id = request["id"]
    guard let method = request["method"] as? String else { return }
    let params = request["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        // The version spoken back: the client's own when it is one this
        // server knows, and the one it was built on otherwise — never a
        // version echoed that nothing here has ever spoken.
        let known = ["2024-11-05", "2025-03-26", "2025-06-18"]
        let asked = (params["protocolVersion"] as? String) ?? ""
        say(id, result: [
            "protocolVersion": known.contains(asked) ? asked : "2025-06-18",
            "capabilities": ["tools": [:]] as [String: Any],
            "serverInfo": ["name": "search", "version": "1.0"],
            // The honest half of an MCP handshake: what this server is for.
            "instructions": "Drive the person's browser through these tools. Pages you open are the browser's bench tabs — marked with a flask, apart from the person's own, gone when you close them. Take a snapshot, act by the numbers it gave, and read what you need. Nothing runs on the Mac itself: no shell, no files — only pages.",
        ])
    case "notifications/initialized", "notifications/cancelled":
        return
    case "ping":
        say(id, result: [:])
    case "tools/list":
        say(id, result: ["tools": tools.map(\.listed)])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            say(id, result: [
                "content": [["type": "text", "text": "There's no tool called \(name)"] as [String: Any]],
                "isError": true,
            ])
            return
        }
        do {
            let answer = try ask(tool.make(arguments), at: socket)
            let failed = answer["error"] != nil
            say(id, result: [
                "content": [["type": "text", "text": text(of: answer)] as [String: Any]],
                "isError": failed,
            ])
        } catch let gone as Unreachable {
            say(id, result: [
                "content": [["type": "text", "text": gone.words] as [String: Any]],
                "isError": true,
            ])
        } catch {
            say(id, result: [
                "content": [["type": "text", "text": "The browser couldn't be reached — is Search running, with “Let a script drive Search” on in its Settings?"] as [String: Any]],
                "isError": true,
            ])
        }
    case "resources/list":
        say(id, result: ["resources": []])
    case "prompts/list":
        say(id, result: ["prompts": []])
    default:
        say(id, error: -32601, "There's no method \(method) here")
    }
}

/// An answer as text a model reads: pretty JSON, sorted, so the same
/// answer always looks the same.
func text(of answer: [String: Any]) -> String {
    guard let data = (try? JSONSerialization.data(
        withJSONObject: answer, options: [.prettyPrinted, .sortedKeys]
    )) else { return "the browser said something unreadable" }
    return String(data: data, encoding: .utf8) ?? "the browser said something unreadable"
}

// MARK: - main

var socketPath = defaultSocket()
var given = Array(CommandLine.arguments.dropFirst())
while !given.isEmpty {
    switch given.removeFirst() {
    case "--socket":
        guard let path = given.first else {
            FileHandle.standardError.write(Data("--socket needs a path after it\n".utf8))
            exit(2)
        }
        given.removeFirst()
        socketPath = path
    case "--help", "-h":
        print("""
        search-mcp — Search as an MCP server: an agent CLI's hands on the browser.

        Spoken over stdio (JSON-RPC 2.0, one object a line). The browser's side
        needs "Let a script drive Search" on in its Settings.

          --socket PATH   Where the browser's bench socket is
                          (default: \(defaultSocket()))
        """)
        exit(0)
    default:
        break
    }
}

// One line in, one answer out. MCP clients wait for each answer, so a
// plain loop is the whole server; stdin closing is the client going away.
// A client that frames with \r\n is read as well as one that frames
// with \n: the trim takes both.
while let line = readLine() {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { continue }
    handle(request, socket: socketPath)
}
