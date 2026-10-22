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
        # for itself: this shell is the agent's child, and the agent's
        # terminal is this one's. ps says ttysNNN; the /dev is Search's to add.
        TTY=$(ps -o tty= -p $$ 2>/dev/null)
        case "$TTY" in '' | '?' | '??') TTY='' ;; *) TTY="/dev/$TTY" ;; esac

        # The saying, kept whole; an empty one says nothing and is not sent.
        BODY=$(cat)
        [ -n "$BODY" ] || exit 0

        ANSWER=$(printf '%s' "$BODY" | curl -s --unix-socket "$SOCK" \\
            -H "X-Search-Tty: $TTY" -H "X-Search-Source: ${1:-}" \\
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

    // MARK: Claude Code

    /// Claude Code's settings, the flat shape: every event holds a list
    /// of matchers, each holding the hooks that run for it. Ours is one
    /// matcher with no matcher of its own — every tool — and one command.
    static func installClaude(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("settings.json")
        var settings = (try? JSON.read(file)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in said {
            var rows = hooks[event] as? [[String: Any]] ?? []
            rows.removeAll { ours($0, bridge: bridge) }
            var hook: [String: Any] = ["type": "command", "command": bridge + " claude"]
            // The one event that waits: everything else goes and is done
            // with, and a hook that never answers costs the CLI a hanging
            // moment of its own.
            if event == held { hook["timeout"] = heldLong }
            rows.append(["hooks": [hook]])
            hooks[event] = rows
        }
        settings["hooks"] = hooks
        try JSON.write(settings, to: file)
    }

    /// Takes Search's hooks back out of Claude Code's settings, leaving
    /// whatever else was there — the user's own, another tool's — as it
    /// was. An event left with nothing to run goes, and a hooks with
    /// nothing left in it goes with it.
    static func removeClaude(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("settings.json")
        guard var settings = try? JSON.read(file) else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in said {
            guard var rows = hooks[event] as? [[String: Any]] else { continue }
            rows.removeAll { ours($0, bridge: bridge) }
            if rows.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = rows }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        try JSON.write(settings, to: file)
    }

    /// Whether every event of ours is in place, whatever else is beside
    /// it. Half in place counts as not: the switches put it all back.
    static func claudeHooked(_ home: URL, bridge: String) -> Bool {
        guard let settings = try? JSON.read(home.appendingPathComponent("settings.json")) else { return false }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return said.allSatisfy { event in
            guard let rows = hooks[event] as? [[String: Any]] else { return false }
            return rows.contains { ours($0, bridge: bridge) }
        }
    }

    // MARK: Codex

    /// Codex's hooks, one nest deeper than Claude's: the event holds a
    /// list, each row holds the hooks that run, and no matcher comes
    /// into it.
    static func installCodex(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("hooks.json")
        var settings = (try? JSON.read(file)) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in codexSaid {
            var rows = hooks[event] as? [[String: Any]] ?? []
            rows.removeAll { ours($0, bridge: bridge) }
            var hook: [String: Any] = ["type": "command", "command": bridge + " codex"]
            if event == held { hook["timeout"] = heldLong }
            rows.append(["hooks": [hook]])
            hooks[event] = rows
        }
        settings["hooks"] = hooks
        try JSON.write(settings, to: file)
    }

    static func removeCodex(_ home: URL, bridge: String) throws {
        let file = home.appendingPathComponent("hooks.json")
        guard var settings = try? JSON.read(file) else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in codexSaid {
            guard var rows = hooks[event] as? [[String: Any]] else { continue }
            rows.removeAll { ours($0, bridge: bridge) }
            if rows.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = rows }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        try JSON.write(settings, to: file)
    }

    static func codexHooked(_ home: URL, bridge: String) -> Bool {
        guard let settings = try? JSON.read(home.appendingPathComponent("hooks.json")) else { return false }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return codexSaid.allSatisfy { event in
            guard let rows = hooks[event] as? [[String: Any]] else { return false }
            return rows.contains { ours($0, bridge: bridge) }
        }
    }

    // MARK: Pi

    /// Pi runs extensions it finds on its own: the whole of Search's
    /// side is one file in the folder it looks in. Overwritten whole on
    /// every install, so what's there is never half of two versions.
    static func installPi(_ home: URL, bridge: String) throws {
        let folder = home.appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try piScript(bridge: bridge).write(
            to: folder.appendingPathComponent(piName), atomically: true, encoding: .utf8
        )
    }

    static func removePi(_ home: URL) throws {
        let file = home.appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(piName)
        try? FileManager.default.removeItem(at: file)
    }

    static func piHooked(_ home: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent("extensions", isDirectory: true)
                .appendingPathComponent(piName).path
        )
    }

    /// The pi extension: the sayings go straight to the socket, bare, and
    /// the one asking — a bash that could take something away — goes by
    /// the bridge, because an answer has to be carried back and Node's
    /// own way of ending a write closes the connection too soon for
    /// Search to answer on.
    static func piScript(bridge: String) -> String {
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
                ["pi"],
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
            sessionId: string,
            cwd: string,
            extra: Record<string, unknown>,
          ): Record<string, unknown> {
            return {
              hook_event_name,
              session_id: `pi-${sessionId}`,
              _source: "pi",
              _tty: tty,
              cwd,
              ...extra,
            };
          }

          pi.on("session_start", async (_event, ctx) => {
            say(said("SessionStart", ctx.sessionManager.getSessionId(), ctx.cwd, {}));
          });

          pi.on("session_shutdown", async (_event, ctx) => {
            say(said("SessionEnd", ctx.sessionManager.getSessionId(), ctx.cwd, {}));
          });

          pi.on("before_agent_start", async (event, ctx) => {
            say(
              said("UserPromptSubmit", ctx.sessionManager.getSessionId(), ctx.cwd, {
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
              said("Stop", ctx.sessionManager.getSessionId(), ctx.cwd, {
                last_assistant_message: words || undefined,
              }),
            );
          });

          pi.on("tool_call", async (event, ctx) => {
            const sessionId = ctx.sessionManager.getSessionId();
            const input = { ...event.input } as Record<string, unknown>;

            // A bash that could take something away is held open for a
            // person; everything else is only said.
            if (
              event.toolName === "bash" &&
              typeof input.command === "string" &&
              DANGEROUS.some((p) => p.test(input.command as string))
            ) {
              const answer = await ask(
                said("PermissionRequest", sessionId, ctx.cwd, {
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
              said("PreToolUse", sessionId, ctx.cwd, {
                tool_name: event.toolName,
                tool_input: input,
              }),
            );
            return undefined;
          });

          pi.on("tool_result", async (_event, ctx) => {
            say(said("PostToolUse", ctx.sessionManager.getSessionId(), ctx.cwd, {}));
          });
        }
        """
    }

    // MARK: Inside

    /// Whether a row of settings is ours: the command is the bridge,
    /// whatever else the row says. Ours is told by what it runs, not by
    /// a name — nothing of ours is in the settings that the user would
    /// read, and this way another name on the same command is still
    /// taken care of.
    private static func ours(_ row: [String: Any], bridge: String) -> Bool {
        let hooks = row["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains(bridge) == true }
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
