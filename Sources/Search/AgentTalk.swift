import Foundation

// Which agent is in a terminal, and where its own record of the talk is.
//
// A coding agent's terminal is a screen: words go by, and the ones that
// scrolled away are gone. Every one of them keeps its own transcript
// besides — a JSONL file it appends to as it talks — and that file, not
// the screen, is the whole conversation. This is where the two are tied
// together: a tty says which agent is in it and which of its runs, and
// that says which file to read.
//
// The tie comes from the agent itself, through the same hooks the notch
// already listens to (IslandHooks): Claude Code's hook payload carries
// `transcript_path`, and the pi extension can ask its own session for
// its file. Nothing here guesses. A path is only taken when it is a
// session file that exists, inside a store that agent writes to — a
// terminal whose agent never said where it writes gets no chat, because
// a chat showing someone else's conversation is worse than a terminal.
enum AgentTalk {
    /// The agents that can be shown as a conversation, and how each one's
    /// transcript reads. The set is deliberately short: every one of them
    /// is a JSONL parser with its own shape, and a shape read wrongly is
    /// a conversation made up.
    enum Agent: String, CaseIterable {
        case claude, pi, codex

        /// What a person calls it, in the chip that switches the view.
        var name: String {
            switch self {
            case .claude: return "Claude Code"
            case .pi: return "Pi"
            case .codex: return "Codex"
            }
        }

        /// The `source` its hooks say, which is the name the settings
        /// wrote and the notch shows. Pi's extension is installed for
        /// both pi and omp, under two names.
        static func of(source: String) -> Agent? {
            switch source {
            case "claude": return .claude
            case "pi", "omp", "omo": return .pi
            case "codex": return .codex
            default: return nil
            }
        }
    }

    /// One run of one agent in one terminal: what the chip says, and
    /// what a reader reads.
    struct Talk: Equatable {
        let agent: Agent
        /// The store's own name for the run — Claude's UUID, pi's, Codex's
        /// thread id. Two runs are two talks even in the same terminal.
        let id: String
        /// The transcript file, absolute, or nil while the agent has not
        /// written its first answer yet (pi holds the file back until
        /// then).
        let file: URL?
        /// Where the run began, for a file that is not written yet: the
        /// folder whose store it will appear in.
        let cwd: String?

        static func == (a: Talk, b: Talk) -> Bool {
            a.agent == b.agent && a.id == b.id && a.file == b.file
        }
    }

    // MARK: - Reading what the hooks said

    /// The talk a hook's payload names, if it names one this file can
    /// read. `raw` is the payload as the hook wrote it: Claude's
    /// `transcript_path` is right there, and our own pi extension puts
    /// `_sessionFile` in. Independent of the moment being said — a hook
    /// that says a session exists names its file the same way.
    static func talk(
        in raw: [String: Any], source: String, cwd: String?, stores: [URL]? = nil
    ) -> Talk? {
        guard let agent = Agent.of(source: source) else { return nil }
        guard let said = string(raw["transcript_path"]) ?? string(raw["_sessionFile"])
            ?? string(raw["rollout_path"]) else { return nil }
        let path = URL(fileURLWithPath: (said as NSString).expandingTildeInPath)
        guard let id = identifier(of: path, agent: agent) else { return nil }
        guard let verified = verify(path, agent: agent, in: stores) else {
            // A run that has not written its file yet is still a run: pi
            // waits for its first answer. Its folder is enough to say
            // which one it is, and the reader waits for the file.
            return Talk(agent: agent, id: id, file: nil, cwd: cwd)
        }
        return Talk(agent: agent, id: id, file: verified, cwd: cwd)
    }

    /// The name a run goes by, from the file it lives in. Claude names
    /// the file after its session; so does pi (the last underscore
    /// field); Codex puts its thread id in the file's own head, which
    /// this cannot read without opening it — so a rollout goes by its
    /// file name, which is just as unique.
    private static func identifier(of path: URL, agent: Agent) -> String? {
        let name = path.lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        switch agent {
        case .claude:
            return stem.isEmpty ? nil : stem
        case .pi:
            // 2026-10-22T00-17-16-154Z_01a160f8-1f7a-7442-8026-ccf3bb9c327b
            guard let cut = stem.lastIndex(of: "_") else { return stem.isEmpty ? nil : stem }
            let id = String(stem[stem.index(after: cut)...])
            return id.isEmpty ? nil : id
        case .codex:
            // rollout-2026-10-22T00-17-16-01a160f8-1f7a-7442-8026-ccf3bb9c327b
            return stem.isEmpty ? nil : stem
        }
    }

    /// The file, if it is a session file this agent writes: a regular
    /// `.jsonl` inside the agent's own store, resolved through any link
    /// so a path pointing out of the store cannot pass for one inside it.
    private static func verify(_ path: URL, agent: Agent, in given: [URL]? = nil) -> URL? {
        let fm = FileManager.default
        let real = path.resolvingSymlinksInPath().standardizedFileURL
        guard real.pathExtension == "jsonl" else { return nil }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: real.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        // The store the agent keeps its sessions in: a file elsewhere is
        // not a session, whatever it is named. (A caller with its own
        // store — a test — says so; nobody else.)
        let stores = given ?? stores(for: agent)
        guard !stores.isEmpty else { return nil }
        let inside = stores.contains { store in
            let root = store.resolvingSymlinksInPath().standardizedFileURL.path
            return real.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        return inside ? real : nil
    }

    /// Every folder an agent writes sessions into, for this Mac's user.
    /// Codex files its rollouts by date, so its store is the root of the
    /// year folders. A store named by the environment is honoured when it
    /// is one: `PI_CODING_AGENT_SESSION_DIR` moves pi's, exactly as
    /// `CODEX_HOME` moves Codex's.
    static func stores(for agent: Agent) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        func folder(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        switch agent {
        case .claude:
            // ~/.claude/projects/<cwd with slashes as dashes>/*.jsonl
            if let said = env["CLAUDE_CONFIG_DIR"], !said.isEmpty {
                return [folder(said).appendingPathComponent("projects")]
            }
            return [home.appendingPathComponent(".claude/projects")]
        case .pi:
            if let said = env["PI_CODING_AGENT_SESSION_DIR"], !said.isEmpty { return [folder(said)] }
            if let agent = env["PI_CODING_AGENT_DIR"], !agent.isEmpty {
                return [folder(agent).appendingPathComponent("sessions")]
            }
            return [home.appendingPathComponent(".pi/agent/sessions")]
        case .codex:
            if let said = env["CODEX_HOME"], !said.isEmpty { return [folder(said).appendingPathComponent("sessions")] }
            return [home.appendingPathComponent(".codex/sessions")]
        }
    }

    /// The file a talk named but could not hand over yet, found in the
    /// store once it is there. Pi holds its session file back until the
    /// first answer is in, so the hook names a path that does not exist
    /// for the first minute of a run — and a path outside the store, or
    /// one that is not a session, is never found this way either, which
    /// is the point: searching adds nothing the hook did not already
    /// say, it only waits for a file that was said to be coming.
    ///
    /// The search is bounded — Codex files its rollouts three folders
    /// deep by date, the others one — and matches on the run's own name,
    /// so two runs in one folder are never confused for one another.
    static func settle(_ talk: Talk, in given: [URL]? = nil) -> URL? {
        guard talk.file == nil else { return talk.file }
        let fm = FileManager.default
        for store in given ?? stores(for: talk.agent) {
            guard let walked = fm.enumerator(
                at: store, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walked {
                guard url.pathExtension == "jsonl" else { continue }
                // Run names are long and unique; a file whose name does
                // not end in this one is another run's.
                guard url.deletingPathExtension().lastPathComponent.hasSuffix(talk.id) else { continue }
                if let real = verify(url, agent: talk.agent, in: given) { return real }
            }
        }
        return nil
    }

    /// A string out of a hook payload, whichever of the shapes a CLI
    /// wrote it in — the same reading the notch does, kept here so a
    /// payload is read one way in both places.
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text != "null" else { return nil }
        return text
    }
}
