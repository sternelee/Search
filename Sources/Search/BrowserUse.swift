import SwiftUI
import AppKit

// Settings › Browser Use: the browser as an agent CLI's hands. One switch
// — the bench's own, "Let a script drive Search" — and everything an agent
// on this Mac (Claude Code, Codex, a script of your own) needs to reach
// it: a small MCP server inside the app (search-mcp, see Sources/SearchMCP)
// with the config that registers it, the skills folder it can share, and
// the words that explain what all of it does.
//
// The page never opens anything by itself: copying config and linking
// skills are the person's own acts, and the switch is the one consent the
// bench has always had — nothing listens without it, and what listens is
// this Mac's own user and nobody else.

struct BrowserUseSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var hub = MCPHub.shared
    @State private var shelf: [Skills.Listed] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            theSwitch
            if let missing = missing { Caution(missing) }
            if prefs.bench {
                forClaude
                forCodex
            }
            skills
            servers
            howItWorks
        }
        .onAppear { shelf = Skills.listed() }
    }

    // MARK: - the switch

    private var theSwitch: some View {
        Card {
            Line(
                "Let agents drive this browser",
                "The same switch as Settings › General: a local socket on this Mac, readable by your user and nobody else. An agent's pages open beside yours marked with a flask, never take over, and never enter the session or the history. Off, nothing listens"
            ) {
                Switch(on: $prefs.bench)
            }
            if prefs.bench {
                Rule()
                Line("The socket", Bench.socket.path) {
                    Pill("Copy") { copy(Bench.socket.path) }
                }
                Rule()
                Line(
                    "Agents' pages out of sight",
                    "Their tabs work on as ever — the bridge, ./bench, everything — but nothing of them shows in the row: no flask, no titles, no coming and going. ⌘K and the number keys reach only what you can see; the socket still reaches them all"
                ) {
                    Switch(on: $prefs.benchQuiet)
                }
                if prefs.benchQuiet {
                    Rule()
                    Line("Out of sight right now", outOfSight) {
                        EmptyView()
                    }
                }
            }
        }
    }

    /// Said when the bridge isn't beside the app — a build from before it
    /// came, or a run straight out of .build without it. Only while the
    /// service is on: with it off, the configs aren't shown either.
    private var missing: String? {
        guard prefs.bench, let bridge, !FileManager.default.fileExists(atPath: bridge.path) else { return nil }
        return "search-mcp, the MCP server the configs below point at, isn't beside this app — build it with ./build.sh and the configs will reach it"
    }

    /// How many agent pages are working out of sight, as the page says it.
    private var outOfSight: String {
        let working = browser.tabs.filter(\.bench).count
        guard working > 0 else { return "None at work right now — a page an agent opens will be there, unseen, until it closes it" }
        return "\(working) agent page\(working == 1 ? "" : "s") at work, unseen — turn this off to see them again"
    }

    /// The bridge inside the app bundle, beside the browser itself.
    private var bridge: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("search-mcp")
    }

    // MARK: - the configs, copyable

    private var forClaude: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("For Claude Code")
            Card {
                Line(
                    "Add Search as an MCP server",
                    "Into a project's .mcp.json, or ~/.claude.json for all of them — then Claude Code drives the browser with list_pages, snapshot, act and the rest"
                ) {
                    Pill("Copy JSON", filled: true) { copy(claudeJSON) }
                }
                Block(text: claudeJSON)
                Rule()
                Line("Or from the shell, once", "Does the same, into Claude Code's own settings") {
                    Pill("Copy command") { copy(claudeCommand) }
                }
                Block(text: claudeCommand)
            }
        }
    }

    private var forCodex: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("For Codex")
            Card {
                Line(
                    "Add Search as an MCP server",
                    "Into ~/.codex/config.toml — Codex then has the same hands Claude Code does"
                ) {
                    Pill("Copy TOML", filled: true) { copy(codexTOML) }
                }
                Block(text: codexTOML)
                Rule()
                Line("Or from the shell, once", "Does the same, into Codex's own settings") {
                    Pill("Copy command") { copy(codexCommand) }
                }
                Block(text: codexCommand)
            }
        }
    }

    private var path: String { bridge?.path ?? "/Applications/Search.app/Contents/MacOS/search-mcp" }

    private var claudeJSON: String {
        """
        {
          "mcpServers": {
            "search": {
              "command": "\(path)"
            }
          }
        }
        """
    }

    private var claudeCommand: String { "claude mcp add search -- \(path)" }

    private var codexTOML: String {
        """
        [mcp_servers.search]
        command = "\(path)"
        """
    }

    private var codexCommand: String { "codex mcp add search -- \(path)" }

    // MARK: - the skills, shared

    private var skills: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Skills")
            Card {
                Line(
                    "The skills folder",
                    Skills.folder.path
                ) {
                    HStack(spacing: 6) {
                        Pill("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([Skills.folder]) }
                        Pill("Copy") { copy(Skills.folder.path) }
                    }
                }
                Rule()
                Line(
                    "Share with Claude Code",
                    "Symlinks every enabled skill into ~/.claude/skills, where Claude Code reads them — the same SKILL.md folders work in both places, and nothing is copied"
                ) {
                    Pill("Link") { link() }
                }
                ForEach(shelf) { skill in
                    Rule()
                    Line(skill.name, skill.description.isEmpty ? "No description" : skill.description) {
                        Switch(on: Binding(
                            get: { Skills.enabled(skill.id) },
                            set: { Skills.setEnabled(skill.id, $0) }
                        ))
                    }
                }
                if shelf.isEmpty {
                    Rule()
                    Line("No skills yet", "A folder with a SKILL.md in it — a name and description at the top, the rest its words — becomes one. Made in Settings › AI › Skills, or dropped into the folder above") {
                        EmptyView()
                    }
                }
            }
        }
    }

    /// The skills, linked into Claude Code's own folder: one symlink
    /// apiece, never over something that's already there.
    private func link() {
        let claude = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)) != nil else {
            browser.announce("Couldn't make Claude Code's skills folder")
            return
        }
        var linked = 0, kept = 0
        for skill in shelf {
            let to = claude.appendingPathComponent(skill.id)
            guard !FileManager.default.fileExists(atPath: to.path) else { kept += 1; continue }
            if (try? FileManager.default.createSymbolicLink(at: to, withDestinationURL: Skills.folder.appendingPathComponent(skill.id))) != nil {
                linked += 1
            }
        }
        browser.announce(
            linked > 0 ? "Linked \(linked) skill\(linked == 1 ? "" : "s") into Claude Code"
                : kept > 0 ? "Claude Code already has these skills"
                : "No skills to link"
        )
    }

    // MARK: - the servers, shown

    private var servers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("MCP servers on this Mac")
            Card {
                ForEach(Array(hub.servers.enumerated()), id: \.element.id) { place, server in
                    if place > 0 { Rule() }
                    ServerRow(server: server, on: hub.enabled(server.config.name))
                }
                if hub.servers.isEmpty {
                    Line(
                        "No servers yet",
                        "These are the tool-bearers the browser's own bot can call, added and switched in Settings › AI › MCP. They stay with the browser — the agent CLIs above get only the bridge"
                    ) {
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: - the words

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("How it works")
            Card {
                Line(
                    "The tools",
                    "list_pages · open_page · snapshot · act · read · wait · close_page. A snapshot is the page in words — button \"Sign in\" @12 — one line a thing, hidden things not listed; act works a thing by its number, or by words on it (text=Sign in), or by role (loc=role:button[name='Sign in'])"
                ) {
                    EmptyView()
                }
                Rule()
                Line("A page worked, from end to end", nil) { EmptyView() }
                Block(text: """
                    open_page   url=https://example.com/signin label=signin
                    snapshot    page=signin        →  textbox "Email" @3 · button "Sign in" @12
                    act         page=signin verb=fill target=@3 text=me@here.com
                    act         page=signin verb=press target=@3 text=Enter
                    read        page=signin target=@12
                    close_page  page=signin
                """)
                Rule()
                Line(
                    "What holds",
                    "The bridge runs nothing on this Mac itself: no shell, no files, only pages. The pages it opens are bench pages — apart from yours, gone when the agent closes them, marked with a flask in the row or out of sight entirely, as the switch above says. The socket is this Mac's own user only, and that switch is the whole of the consent: off, and no agent reaches anything"
                ) {
                    EmptyView()
                }
                Rule()
                Line(
                    "From the shell, too",
                    "The same verbs without an MCP server in between: ./bench agent open, snapshot, act, read, wait — see the repository's README, \"An agent at the wheel\""
                ) {
                    EmptyView()
                }
            }
        }
    }

    // MARK: - the pieces

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        browser.announce("Copied")
    }

    /// A saying of the page's own: config and example, monospaced, there to
    /// be read whole and copied whole.
    private struct Block: View {
        let text: String

        var body: some View {
            Text(verbatim: text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
        }
    }

    /// One server in the list: its own state, watched (a server that
    /// connects while the page is open says so when it does).
    private struct ServerRow: View {
        @ObservedObject var server: MCPServer
        let on: Bool

        var body: some View {
            Line(
                server.config.name,
                "\(server.state.words)\(server.config.url != nil ? " · over HTTP" : " · a program on this Mac")"
            ) {
                Image(systemName: on ? "checkmark.circle" : "pause.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Palette.ink : Palette.faint)
            }
        }
    }
}
