import Foundation

// MARK: - The bridge

/// Everything written into the world to make the agents talk, and the
/// taking of it back out: one bridge script every hook runs, one pi
/// extension, and the settings that tell each CLI to run them. Pure work
/// on the paths given to it — nothing here knows where the real ones
/// are, so a test's folders serve as well as the world's.
enum IslandHooks {
    /// What the bridge is called, where the pi extension lives: the
    /// names the settings say and the settings are said by.
    static let bridgeName = "search-island.sh"
    static let piName = "search-island.ts"
    /// The name of the file of hooks that is ours alone, in the CLIs
    /// that look in a folder for any file of hooks (Grok's, Copilot's):
    /// its being ours is said by it.
    static let oursName = "search-island.json"

    /// The events that say something worth showing. Every CLI writes
    /// this same handful, borrowed from Claude Code; the ones that mean
    /// nothing to the bar (SubagentStart and its kin) are left to the
    /// CLIs, which run them without a word from Search.
    static let said = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "Notification", "SessionEnd",
    ]
    /// Codex's own handful, one shorter: it has no Notification to say.
    static let codexSaid = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Stop", "SessionEnd",
    ]
    /// Gemini's own handful, in its own words: it says a moment before
    /// every tool — a veto, not an asking, for the ones that need no
    /// person either — so all of it is sayings. Search shows what it's
    /// doing, and Gemini asks for permissions in its own terminal, the
    /// way it always has.
    static let geminiSaid = [
        "SessionStart", "BeforeAgent", "BeforeTool", "AfterTool",
        "AfterAgent", "SessionEnd",
    ]
    /// Cursor's handful, lower-case and its own — the moments are the
    /// ones the bar is built on, said its way.
    static let cursorSaid = [
        "beforeSubmitPrompt", "beforeShellExecution", "afterShellExecution",
        "beforeReadFile", "afterFileEdit", "beforeMCPExecution",
        "afterMCPExecution", "afterAgentResponse", "stop",
    ]
    /// Copilot CLI's handful, in its own lower-case.
    static let copilotSaid = [
        "sessionStart", "sessionEnd", "userPromptSubmitted",
        "preToolUse", "postToolUse", "errorOccurred",
    ]
    /// Grok's: Claude Code's contract whole, minus the permission —
    /// Grok doesn't wait on a hook's answer, so a permission said here
    /// would be asked and dropped in one breath; its own asking serves.
    static let grokSaid = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Stop", "Notification", "SessionEnd",
    ]
    /// The one event that must be waited on: a permission, held open
    /// until a person says. Everything else goes and is done with.
    static let held = "PermissionRequest"
    /// How long a CLI waits on us before asking its own way: a day, as
    /// CodeIsland has it — a person might well take that long.
    static let heldLong = 86_400

    // MARK: The bridge itself

    /// The bridge every hook runs: sh and curl, the two things every Mac
    /// has, so there's nothing of Search's to build or keep in sync. It
    /// hands the event to Search over the socket and Search's answer
    /// back — an approval given from the tab you're on reaches the agent
    /// without a visit to its own. Search not running: nothing to tell,
    /// and the agent asks its own way, as though this were never there.
    static let bridge = """
        #!/bin/sh
        # Search's agent watch (Settings > Terminal > Coding agents). Every
        # coding agent's hook runs this once. It hands the event to Search
        # over a socket, and Search's answer back; an approval given from
        # the tab you're on goes to the agent without a visit to its own.

        SOCK="/tmp/search-island-$(id -u).sock"
        [ -S "$SOCK" ] || exit 0

        # The terminal is the one fact the hook can't be told and must know
        # for itself. Not its own: an agent runs a hook with its output
        # piped, so the hook has no terminal at all (`ps` says ??) even
        # though the agent that spawned it sits in one. Walk up instead,
        # the way pi's extension does, until a process has a tty — the
        # agent and its shell are both above this one, and the nearest
        # with a terminal is the pane the words are meant for.
        TTY=''
        PID=$$
        N=0
        while [ -z "$TTY" ] && [ "$N" -lt 8 ]; do
            FOUND=$(ps -o tty=,ppid= -p "$PID" 2>/dev/null)
            TTY=$(printf '%s' "$FOUND" | awk '{print $1}')
            case "$TTY" in
                '' | '?' | '??') TTY='' ;;
            esac
            PID=$(printf '%s' "$FOUND" | awk '{print $2}')
            case "$PID" in '' | 0 | 1) break ;; esac
            N=$((N + 1))
        done
        [ -n "$TTY" ] && TTY="/dev/$TTY"

        # The saying, kept whole; an empty one says nothing and is not sent.
        BODY=$(cat)
        [ -n "$BODY" ] || exit 0

        # Two CLIs say no name for the moment in the saying itself — the
        # hook was told it when it was set up, and here it is again, the
        # second word. The folder is Search's to lean on where the saying
        # says none of its own.
        ANSWER=$(printf '%s' "$BODY" | curl -s --unix-socket "$SOCK" \\
            -H "X-Search-Tty: $TTY" -H "X-Search-Source: ${1:-}" \\
            -H "X-Search-Event: ${2:-}" -H "X-Search-Cwd: $PWD" \\
            -H 'Content-Type: application/json' --data-binary @- \\
            --connect-timeout 2 http://island/hook 2>/dev/null) || exit 0

        # Only a decision is worth the agent's ears; anything else is
        # Search's own business, and an empty stdout means "ask as you
        # would without me".
        case "$ANSWER" in *hookSpecificOutput*) printf '%s\\n' "$ANSWER" ;; esac
        exit 0
        """

    /// Writes the bridge where the app's own terminal files live, and
    /// returns where it is: the path the settings say by, absolute, as
    /// hooks must be told (they run from anywhere).
    static func writeBridge(_ folder: URL) throws -> String {
        let file = folder.appendingPathComponent(bridgeName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bridge.write(to: file, atomically: true, encoding: .utf8)
        // Runs, not just sits: every hook executes it.
        chmod(file.path, 0o755)
        return file.path
    }

    // MARK: The shape most of them share

    /// The shape Claude Code wrote and the families that borrowed its
    /// contract kept — a settings file holding a hooks object, each event
    /// holding rows, each row holding the hooks that run for it — put in
    /// place for one CLI: which events, which file, the one event that
    /// waits on a person (if the CLI has one), how long a wait is
    /// counted (Gemini's and Qwen's are milliseconds, the rest seconds),
    /// and whether the command must carry the event's own name, for the
    /// CLIs whose sayings don't.
    private static func put(
        _ home: URL, file: String, source: String, events: [String],
        held: String?, heldLong: Int, milliseconds: Bool = false,
        carriesEvent: Bool = false, timeout: Int? = nil, bridge: String
    ) throws {
        let file = home.appendingPathComponent(file)
        var settings = (try? JSON.read(file)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var rows = hooks[event] as? [[String: Any]] ?? []
            rows.removeAll { ours($0, bridge: bridge) }
            var hook: [String: Any] = [
                "type": "command",
                "command": quoted(bridge) + " \(source)" + (carriesEvent ? " \(event)" : ""),
            ]
            // A saying is answered the moment it arrives — a short
            // leash in case it isn't, for Qwen hangs on one that doesn't
            // say it's done. A permission is worth a wait, and a day of
            // one: a person might well take that long.
            if let timeout { hook["timeout"] = milliseconds ? timeout * 1000 : timeout }
            if event == held { hook["timeout"] = milliseconds ? heldLong * 1000 : heldLong }
            rows.append(["hooks": [hook]])
            hooks[event] = rows
        }
        settings["hooks"] = hooks
        try JSON.write(settings, to: file)
    }

    /// The taking-back of the shared shape: ours out of each event,
    /// theirs as it was, an event left with nothing gone, and a hooks
    /// with nothing left in it gone with it.
    private static func take(_ home: URL, file: String, events: [String], bridge: String) throws {
        let file = home.appendingPathComponent(file)
        guard var settings = try? JSON.read(file) else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in events {
            guard var rows = hooks[event] as? [[String: Any]] else { continue }
            rows.removeAll { ours($0, bridge: bridge) }
            if rows.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = rows }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        try JSON.write(settings, to: file)
    }

    /// Whether every event of ours is in place in the shared shape,
    /// whatever else is beside it. Half in place counts as not: the
    /// switches put it all back.
    private static func inPlace(_ home: URL, file: String, events: [String], bridge: String) -> Bool {
        guard let settings = try? JSON.read(home.appendingPathComponent(file)) else { return false }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            guard let rows = hooks[event] as? [[String: Any]] else { return false }
            return rows.contains { ours($0, bridge: bridge) }
        }
    }

    // MARK: The ones that borrowed Claude Code's contract

    /// Claude Code's settings, in its own home (or the one it was told
    /// to keep them in).
    static func installClaude(_ home: URL, bridge: String) throws {
        try put(home, file: "settings.json", source: "claude", events: said,
                held: held, heldLong: heldLong, bridge: bridge)
    }

    static func removeClaude(_ home: URL, bridge: String) throws {
        try take(home, file: "settings.json", events: said, bridge: bridge)
    }

    static func claudeHooked(_ home: URL, bridge: String) -> Bool {
        inPlace(home, file: "settings.json", events: said, bridge: bridge)
    }

    /// Codex keeps its hooks one nest over, in a file of their own —
    /// the same shape, one Notification shorter.
    static func installCodex(_ home: URL, bridge: String) throws {
        try put(home, file: "hooks.json", source: "codex", events: codexSaid,
                held: held, heldLong: heldLong, bridge: bridge)
    }

    static func removeCodex(_ home: URL, bridge: String) throws {
        try take(home, file: "hooks.json", events: codexSaid, bridge: bridge)
    }

    static func codexHooked(_ home: URL, bridge: String) -> Bool {
        inPlace(home, file: "hooks.json", events: codexSaid, bridge: bridge)
    }

    /// Qwen Code borrowed the contract whole — the same events, the
    /// same shape — but it counts in milliseconds and hangs on a hook
    /// that doesn't say it's done, so every wait is said: short for the
    /// sayings, the day for the permission.
    static func installQwen(_ home: URL, bridge: String) throws {
        try put(home, file: "settings.json", source: "qwen", events: said,
                held: held, heldLong: heldLong, milliseconds: true, timeout: 5, bridge: bridge)
    }

    static func removeQwen(_ home: URL, bridge: String) throws {
        try take(home, file: "settings.json", events: said, bridge: bridge)
    }

    static func qwenHooked(_ home: URL, bridge: String) -> Bool {
        inPlace(home, file: "settings.json", events: said, bridge: bridge)
    }

    /// Factory's Droid took the contract as Claude wrote it, seconds
    /// and all — the same shape, its own home.
    static func installDroid(_ home: URL, bridge: String) throws {
        try put(home, file: "settings.json", source: "droid", events: said,
                held: held, heldLong: heldLong, bridge: bridge)
    }

    static func removeDroid(_ home: URL, bridge: String) throws {
        try take(home, file: "settings.json", events: said, bridge: bridge)
    }

    static func droidHooked(_ home: URL, bridge: String) -> Bool {
        inPlace(home, file: "settings.json", events: said, bridge: bridge)
    }

    // MARK: The ones that grew their own

    /// Gemini keeps its hooks in its settings beside everything else
    /// there, in the same nest as Claude's but its own events and its
    /// own milliseconds — and no permission held open, for its Before
    /// is a veto on every tool, not an asking.
    static func installGemini(_ home: URL, bridge: String) throws {
        try put(home, file: "settings.json", source: "gemini", events: geminiSaid,
                held: nil, heldLong: 0, milliseconds: true, timeout: 10, bridge: bridge)
    }

    static func removeGemini(_ home: URL, bridge: String) throws {
        try take(home, file: "settings.json", events: geminiSaid, bridge: bridge)
    }

    static func geminiHooked(_ home: URL, bridge: String) -> Bool {
        inPlace(home, file: "settings.json", events: geminiSaid, bridge: bridge)
    }

    /// Cursor's hooks are flat — an event holds a list of commands, no
    /// nest and no matcher — and the saying carries no name for the
    /// moment, so the command carries it. Cursor runs a hook never
    /// waiting on its answer, so nothing of ours holds anything open.
    static func installCursor(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("hooks.json")
        var settings = (try? JSON.read(file)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in cursorSaid {
            var rows = hooks[event] as? [[String: Any]] ?? []
            rows.removeAll { ours($0, bridge: bridge) }
            rows.append(["command": quoted(bridge) + " cursor \(event)"])
            hooks[event] = rows
        }
        settings["hooks"] = hooks
        try JSON.write(settings, to: file)
    }

    static func removeCursor(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("hooks.json")
        guard var settings = try? JSON.read(file) else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in cursorSaid {
            guard var rows = hooks[event] as? [[String: Any]] else { continue }
            rows.removeAll { ours($0, bridge: bridge) }
            if rows.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = rows }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        try JSON.write(settings, to: file)
    }

    static func cursorHooked(_ home: URL, bridge: String) -> Bool {
        guard let settings = try? JSON.read(home.appendingPathComponent("hooks.json")) else { return false }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return cursorSaid.allSatisfy { event in
            guard let rows = hooks[event] as? [[String: Any]] else { return false }
            return rows.contains { ours($0, bridge: bridge) }
        }
    }

    /// Copilot CLI keeps its hooks in a versioned file of its own, flat
    /// like Cursor's but with its waits said, its own word for the
    /// command — and, like Cursor's, the command carries the moment's
    /// name, for the saying doesn't. A file of ours alone, empty of
    /// ours, is litter, and goes.
    static func installCopilot(_ home: URL, bridge: String) throws {
        let folder = home.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(oursName)
        var settings = (try? JSON.read(file)) ?? [:]
        if settings["version"] == nil { settings["version"] = 1 }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in copilotSaid {
            var rows = hooks[event] as? [[String: Any]] ?? []
            rows.removeAll { ours($0, bridge: bridge) }
            rows.append([
                "type": "command", "bash": quoted(bridge) + " copilot \(event)", "timeoutSec": 5,
            ])
            hooks[event] = rows
        }
        settings["hooks"] = hooks
        try JSON.write(settings, to: file)
    }

    static func removeCopilot(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(oursName)
        guard var settings = try? JSON.read(file) else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in copilotSaid {
            guard var rows = hooks[event] as? [[String: Any]] else { continue }
            rows.removeAll { ours($0, bridge: bridge) }
            if rows.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = rows }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
            if settings.count <= 1 { try? FileManager.default.removeItem(at: file); return }
        } else {
            settings["hooks"] = hooks
        }
        try JSON.write(settings, to: file)
    }

    static func copilotHooked(_ home: URL, bridge: String) -> Bool {
        guard let settings = try? JSON.read(
            home.appendingPathComponent("hooks", isDirectory: true).appendingPathComponent(oursName)
        ) else { return false }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return copilotSaid.allSatisfy { event in
            guard let rows = hooks[event] as? [[String: Any]] else { return false }
            return rows.contains { ours($0, bridge: bridge) }
        }
    }

    /// Grok reads any file of hooks in its hooks folder — ours is our
    /// own there, in the shape it shares with Claude's, gone whole on
    /// the taking-back. It never waits on a hook's answer, so every
    /// wait is the five seconds it gives and no permission is asked.
    static func installGrok(_ home: URL, bridge: String) throws {
        let folder = home.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try put(home, file: "hooks/" + oursName, source: "grok", events: grokSaid,
                held: nil, heldLong: 0, timeout: 5, bridge: bridge)
    }

    static func removeGrok(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("hooks", isDirectory: true).appendingPathComponent(oursName)
        try take(home, file: "hooks/" + oursName, events: grokSaid, bridge: bridge)
        // A file of ours alone, empty of ours, is litter.
        if let left = try? JSON.read(file), left.isEmpty {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func grokHooked(_ home: URL, bridge: String) -> Bool {
        inPlace(home, file: "hooks/" + oursName, events: grokSaid, bridge: bridge)
    }

    // MARK: Pi and Oh My Pi

    /// Pi runs extensions it finds on its own: the whole of Search's
    /// side is one file in the folder it looks in. Oh My Pi reads the
    /// same folder shape — the same file serves it, said for its own
    /// source.
    static func installPi(_ home: URL, bridge: String) throws {
        try putExtension(home, bridge: bridge, source: "pi")
    }

    static func installOmp(_ home: URL, bridge: String) throws {
        try putExtension(home, bridge: bridge, source: "omp")
    }

    private static func putExtension(_ home: URL, bridge: String, source: String) throws {
        let folder = home.appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try piScript(bridge: bridge, source: source).write(
            to: folder.appendingPathComponent(piName), atomically: true, encoding: .utf8
        )
    }

    static func removePi(_ home: URL) throws {
        try takeExtension(home)
    }

    static func removeOmp(_ home: URL) throws {
        try takeExtension(home)
    }

    private static func takeExtension(_ home: URL) throws {
        let file = home.appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(piName)
        try? FileManager.default.removeItem(at: file)
    }

    static func piHooked(_ home: URL) -> Bool { extensionIn(home) }

    static func ompHooked(_ home: URL) -> Bool { extensionIn(home) }

    private static func extensionIn(_ home: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent("extensions", isDirectory: true)
                .appendingPathComponent(piName).path
        )
    }

    /// The pi extension: the sayings go straight to the socket, bare, and
    /// the one asking — a bash that could take something away — goes by
    /// the bridge, because an answer has to be carried back and Node's
    /// own way of ending a write closes the connection too soon for
    /// Search to answer on. Oh My Pi runs the same file, told its own
    /// source, which the socket tells apart.
    static func piScript(bridge: String, source: String = "pi") -> String {
        """
        // Search's agent watch (Settings > Terminal > Coding agents). What
        // pi is doing goes to Search over a socket, and what it wants to do
        // that could take something away (rm -rf, sudo) is held open until
        // you say in Search's bar — allowed, denied, or left to pi's own
        // asking in this terminal. Search not running: everything goes on
        // exactly as though this file were not here.

        import { execFile, execFileSync } from "node:child_process";
        import { connect } from "node:net";
        import type { AssistantMessage } from "@earendil-works/pi-ai";
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        const SOCKET_PATH = `/tmp/search-island-${process.getuid?.() ?? 0}.sock`;
        const BRIDGE_PATH = "\(bridge)";
        const SOURCE = "\(source)";
        const DANGEROUS: RegExp[] = [
          /\\brm\\s+(-r[fF]|--recursive)/i,
          /\\bsudo\\b/i,
          /\\b(chmod|chown)\\b.*777/i,
        ];

        // The terminal, walked up the process tree: pi's own is somewhere
        // above, and the walk finds the nearest one that has it.
        function detectTty(): string | null {
          try {
            let pid = process.pid;
            for (let i = 0; i < 8; i++) {
              const out = execFileSync("ps", ["-o", "tty=,ppid=", "-p", String(pid)], {
                timeout: 1000,
              })
                .toString()
                .trim();
              const [tty, ppid] = out.split(/\\s+/);
              if (tty && tty !== "??" && tty !== "?") {
                return tty.startsWith("/dev/") ? tty : `/dev/${tty}`;
              }
              const up = parseInt(ppid ?? "0", 10);
              if (!up || up <= 1) break;
              pid = up;
            }
          } catch {}
          return null;
        }

        // A saying: sent and forgotten — Search shows it or doesn't, and
        // pi's work never waits on being watched.
        function say(event: Record<string, unknown>): void {
          try {
            const sock = connect({ path: SOCKET_PATH }, () => {
              sock.write(JSON.stringify(event));
              sock.end();
            });
            sock.on("error", () => {});
            sock.setTimeout(3_000, () => sock.destroy());
          } catch {}
        }

        // An asking: carried by the bridge, which can be answered (a plain
        // socket write from here ends too soon to be). Null is no answer —
        // pi goes on asking its own way.
        function ask(
          event: Record<string, unknown>,
        ): Promise<Record<string, unknown> | null> {
          return new Promise((resolve) => {
            try {
              const child = execFile(
                BRIDGE_PATH,
                [SOURCE],
                { timeout: 86_400_000, maxBuffer: 1_048_576 },
                (error, stdout) => {
                  if (error) return resolve(null);
                  try {
                    resolve(JSON.parse(stdout));
                  } catch {
                    resolve(null);
                  }
                },
              );
              child.stdin!.write(JSON.stringify(event));
              child.stdin!.end();
            } catch {
              resolve(null);
            }
          });
        }

        export default function searchIsland(pi: ExtensionAPI) {
          const tty = detectTty();

          function said(
            hook_event_name: string,
            ctx: any,
            extra: Record<string, unknown>,
          ): Record<string, unknown> {
            return {
              hook_event_name,
              session_id: `${SOURCE}-${ctx.sessionManager.getSessionId()}`,
              _source: SOURCE,
              _tty: tty,
              // Where this run keeps its own record. Search reads that
              // file for the chat view — the terminal is the screen,
              // this is the conversation. Asked each time rather than
              // once: pi only creates the file when the session's first
              // answer is written, so it is undefined for the first
              // minute of a run, and the reader knows how to wait.
              _sessionFile: ctx.sessionManager.getSessionFile?.() || undefined,
              cwd: ctx.cwd,
              ...extra,
            };
          }

          pi.on("session_start", async (_event, ctx) => {
            say(said("SessionStart", ctx, {}));
          });

          pi.on("session_shutdown", async (_event, ctx) => {
            say(said("SessionEnd", ctx, {}));
          });

          pi.on("before_agent_start", async (event, ctx) => {
            say(
              said("UserPromptSubmit", ctx, {
                prompt: event.prompt ?? "",
              }),
            );
          });

          pi.on("agent_end", async (event, ctx) => {
            const messages = Array.isArray(event.messages) ? event.messages : [];
            const last = [...messages]
              .reverse()
              .find(
                (m): m is AssistantMessage =>
                  !!m &&
                  typeof m === "object" &&
                  (m as { role?: string }).role === "assistant",
              );
            const words = Array.isArray(last?.content)
              ? last!.content
                  .filter(
                    (c): c is { type: "text"; text: string } => c?.type === "text",
                  )
                  .map((c) => c.text)
                  .join("")
                  .trim()
              : "";
            say(
              said("Stop", ctx, {
                last_assistant_message: words || undefined,
              }),
            );
          });

          pi.on("tool_call", async (event, ctx) => {
            const input = { ...event.input } as Record<string, unknown>;

            // A bash that could take something away is held open for a
            // person; everything else is only said.
            if (
              event.toolName === "bash" &&
              typeof input.command === "string" &&
              DANGEROUS.some((p) => p.test(input.command as string))
            ) {
              const answer = await ask(
                said("PermissionRequest", ctx, {
                  tool_name: "Bash",
                  tool_input: input,
                }),
              );
              const behavior = (
                (answer?.hookSpecificOutput as Record<string, unknown> | undefined)
                  ?.decision as Record<string, unknown> | undefined
              )?.behavior;
              if (behavior === "deny") {
                return { block: true, reason: "Denied from Search's bar" };
              }
              return undefined;
            }

            say(
              said("PreToolUse", ctx, {
                tool_name: event.toolName,
                tool_call_id: event.toolCallId,
                tool_input: input,
              }),
            );
            return undefined;
          });

          // A tool that has finished, named and numbered: Search takes that
          // tool down from the bar with it, and by its own id — a card names
          // one call, and two tools run side by side are two calls, so the
          // one still running keeps its line.
          pi.on("tool_result", async (event, ctx) => {
            say(
              said("PostToolUse", ctx, {
                tool_name: event.toolName,
                tool_call_id: event.toolCallId,
              }),
            );
          });
        }
        """
    }

    // MARK: Keeping what's installed current

    /// Writes every hook that is already installed again, from today's
    /// command and today's script. An install is a promise to be kept:
    /// the bridge's path has a space in it that once broke every hook
    /// silently ("/bin/sh: /Users/…/Library/Application: No such file"),
    /// and the pi extension grew a field an older copy on disk knows
    /// nothing of — and neither fix reached anyone who had already
    /// installed, because nothing ever wrote those files a second time.
    ///
    /// Only ever does what a person already asked for: an agent that was
    /// never installed stays that way. A home that isn't there is a CLI
    /// that isn't either, and its own check says no for it.
    static func keepCurrent(_ bridge: String, home: URL? = nil) {
        // Told a home, it is the home and nothing else overrides it — that
        // is what a test needs, and what the app always answers nil to. Said
        // before the home is filled in below, while it still says whether
        // one was told.
        let told = home == nil
        let home = home ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        func folder(_ path: String, told env: String) -> URL {
            guard told else { return home.appendingPathComponent(path) }
            return ProcessInfo.processInfo.environment[env].map(URL.init(fileURLWithPath:))
                ?? home.appendingPathComponent(path)
        }
        // The homes are the settings screen's, env overrides and all: a
        // file written for a home nobody installs into is litter.
        let claude = folder(".claude", told: "CLAUDE_CONFIG_DIR")
        let codex = folder(".codex", told: "CODEX_HOME")
        let gemini = folder(".gemini", told: "")
        let cursor = folder(".cursor", told: "")
        let qwen = folder(".qwen", told: "QWEN_HOME")
        let grok = folder(".grok", told: "GROK_HOME")
        let droid = folder(".factory", told: "")
        let copilot = folder(".copilot", told: "")
        if claudeHooked(claude, bridge: bridge) { try? installClaude(claude, bridge: bridge) }
        if codexHooked(codex, bridge: bridge) { try? installCodex(codex, bridge: bridge) }
        if geminiHooked(gemini, bridge: bridge) { try? installGemini(gemini, bridge: bridge) }
        if cursorHooked(cursor, bridge: bridge) { try? installCursor(cursor, bridge: bridge) }
        if qwenHooked(qwen, bridge: bridge) { try? installQwen(qwen, bridge: bridge) }
        if grokHooked(grok, bridge: bridge) { try? installGrok(grok, bridge: bridge) }
        if droidHooked(droid, bridge: bridge) { try? installDroid(droid, bridge: bridge) }
        if copilotHooked(copilot, bridge: bridge) { try? installCopilot(copilot, bridge: bridge) }
        // Pi and Oh My Pi keep the same file, each in its own home, and
        // the file says which source it speaks for — the pair is known
        // here, so it needn't be asked.
        for (path, source) in [(".pi/agent", "pi"), (".omp/agent", "omp")] {
            let pi = home.appendingPathComponent(path)
            if extensionIn(pi) { try? putExtension(pi, bridge: bridge, source: source) }
        }
    }

    // MARK: Inside

    /// The bridge as a shell command word. A hook's command is run by sh,
    /// which splits on spaces, and the bridge lives in Application Support
    /// — a folder with a space in it. Written plain, every hook of one of
    /// these agents dies on the first word ("/bin/sh: /Users/.../Library/
    /// Application: No such file"), silently, in the agent's own terminal.
    /// Quoted only when it has to be, and the path quoted is still the
    /// path: `ours` recognises the hook by it either way.
    static func quoted(_ bridge: String) -> String {
        bridge.contains(" ") || bridge.contains("'")
            ? "'" + bridge.replacingOccurrences(of: "'", with: "'\\''") + "'"
            : bridge
    }

    /// Whether a row of settings is ours: the command is the bridge,
    /// whatever else the row says. Ours is told by what it runs, not by
    /// a name — nothing of ours is in the settings that the user would
    /// read, and this way another name on the same command is still
    /// taken care of. Cursor's rows and Copilot's say the command
    /// themselves, unnested — Copilot under its own word for it.
    private static func ours(_ row: [String: Any], bridge: String) -> Bool {
        let hooks = row["hooks"] as? [[String: Any]] ?? []
        if hooks.contains(where: { ($0["command"] as? String)?.contains(bridge) == true }) { return true }
        for field in ["command", "bash"] where (row[field] as? String)?.contains(bridge) == true {
            return true
        }
        return false
    }
}

// MARK: - The settings' own JSON

/// Reading and writing the settings files that run hooks: whole JSON,
/// nothing taken out and nothing put in but what's asked for. Slashes
/// stay slashes (a path escaped is a path half-read), and the spaces are
/// the pretty ones the CLIs themselves write.
private enum JSON {
    static func read(_ file: URL) throws -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
    }

    static func write(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        try data.write(to: file, options: .atomic)
    }
}
