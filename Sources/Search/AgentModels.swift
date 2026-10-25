import AppKit

// What models an agent in this terminal can be switched to, and what it is
// on now. Read from the files each CLI already keeps — never by asking the
// screen, which is the rule the talk reader follows and for the same
// reason: a menu drawn on a terminal is a picture, and a picture of a
// model list is not a list.
//
// Three CLIs keep three shapes here too, and each one's file is a cache it
// writes for itself: Claude's `modelPicker.options` in its settings, pi's
// catalog in `models.json`, Codex's in `models_cache.json`. None of them is
// required to exist — an agent nobody configured has no catalog, and the
// switch then offers nothing rather than a made-up list. The live model is
// a different question and gets a different answer: Claude says it on
// every assistant record of its transcript, pi writes a `model_change`
// line when it moves, and Codex keeps its choice in `config.toml`.
enum AgentModels {
    /// One thing that can be chosen: what it is called, what to send, and
    /// a line of context under it (where it comes from, what it costs).
    struct Row: Equatable {
        let label: String
        /// What the CLI is told — Claude's model id, pi's `provider/model`,
        /// Codex's slug.
        let value: String
        let note: String
        /// A heading rather than a choice: a section's name, over its rows.
        var head: Bool = false
        /// How much this model can hold, when the catalog says. The chat's
        /// ring needs the number, not the words `note` puts around it.
        var window: Int? = nil

        static func head(_ name: String) -> Row {
            Row(label: name, value: "", note: "", head: true)
        }
    }

    /// The context window a model's own name states, when it states one:
    /// `group/auto[1m]` is a million tokens and `…[128k]` is 128 thousand.
    /// This is the CLI's own way of naming the variant it runs, so it is
    /// read rather than guessed — a name that says nothing returns nil,
    /// and the chat then shows the count without a ring instead of
    /// inventing a denominator.
    static func window(of model: String) -> Int? {
        guard model.hasSuffix("]"), let open = model.lastIndex(of: "["), open < model.index(before: model.endIndex) else {
            return nil
        }
        let inside = model[model.index(after: open)..<model.index(before: model.endIndex)]
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = inside.last, unit == "m" || unit == "k",
              let number = Int(inside.dropLast()), number > 0 else { return nil }
        return unit == "m" ? number * 1_000_000 : number * 1_000
    }

    /// The rows the agent offers, grouped the way its own picker groups
    /// them. Empty when it keeps no catalog this Mac can read. `root` is
    /// the agent's own config folder — the tests' way in, and otherwise
    /// the one each CLI would use.
    static func rows(
        for agent: AgentTalk.Agent, talk: AgentTalk.Talk? = nil, root: URL? = nil
    ) -> [Row] {
        switch agent {
        case .claude: return claudeRows(root ?? claudeHome())
        case .pi: return piRows(root ?? piHome())
        case .codex: return codexRows(root ?? codexHome())
        }
    }

    /// What the agent is on right now, in the same words the rows use —
    /// so the chip and the open list agree about which row is the one.
    /// `talk` is the run's own file, which for pi is the only place the
    /// current model is written (its settings say where a run *starts*).
    static func current(
        for agent: AgentTalk.Agent, talk: AgentTalk.Talk? = nil, root: URL? = nil
    ) -> String? {
        switch agent {
        case .claude: return lastModel(in: talk?.file, key: "message", field: "model")
            ?? json((root ?? claudeHome()).appendingPathComponent("settings.json"))?["model"] as? String
        case .pi: return piCurrent(in: talk?.file) ?? piSettingsCurrent(root ?? piHome())
        case .codex: return codexConfig(root ?? codexHome())["model"]
        }
    }

    /// Where a pi run with no record yet starts: `defaultProvider` and
    /// `defaultModel`, said the one way a row is named. The settings keep
    /// them apart ("magpie" and "group/auto"), so they are joined here
    /// rather than compared half each.
    private static func piSettingsCurrent(_ home: URL) -> String? {
        let said = json(home.appendingPathComponent("settings.json")) ?? [:]
        guard let model = said["defaultModel"] as? String, !model.isEmpty else { return nil }
        guard let provider = said["defaultProvider"] as? String, !provider.isEmpty else {
            return model
        }
        return "\(provider)/\(model)"
    }

    /// The line that moves an agent to a model. All three take the same
    /// slash command with the model as its argument; what differs is only
    /// how a model is named, which is the row's `value`.
    static func switchCommand(_ value: String) -> String {
        "/model \(value)"
    }

    // MARK: - Claude

    /// Claude's own picker, from `settings.modelPicker.options`: a curated
    /// list of labels over model ids, which is exactly what its `/model`
    /// menu shows. Without one it has no list we can read, and the chip
    /// only says what the session is on.
    private static func claudeRows(_ home: URL) -> [Row] {
        let said = json(home.appendingPathComponent("settings.json")) ?? [:]
        guard let picker = said["modelPicker"] as? [String: Any],
              let options = picker["options"] as? [[String: Any]] else { return [] }
        let current = said["model"] as? String
        return options.compactMap { option in
            guard let label = option["label"] as? String,
                  let model = option["model"] as? String else { return nil }
            var note = option["description"] as? String ?? ""
            if model == current { note = note.isEmpty ? "in use" : note + " · in use" }
            return Row(label: label, value: model, note: note, window: window(of: model))
        }
    }

    private static func claudeHome() -> URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    // MARK: - pi

    /// pi's catalog: every provider it knows, each with its models, said
    /// as `provider/model` because that is what its `/model` takes.
    private static func piRows(_ home: URL) -> [Row] {
        guard let catalog = json(home.appendingPathComponent("models.json")),
              let providers = catalog["providers"] as? [String: Any] else { return [] }
        var rows: [Row] = []
        for provider in providers.keys.sorted() {
            guard let one = providers[provider] as? [String: Any],
                  let models = one["models"] as? [[String: Any]], !models.isEmpty else { continue }
            rows.append(.head(provider))
            for model in models {
                guard let id = model["id"] as? String else { continue }
                let name = model["name"] as? String ?? id
                var note: [String] = []
                var window: Int? = nil
                if let said = model["contextWindow"] as? Int, said > 0 {
                    note.append(context(said))
                    window = said
                }
                if (model["reasoning"] as? Bool) == true { note.append("reasoning") }
                rows.append(Row(
                    label: name, value: "\(provider)/\(id)", note: note.joined(separator: " · "),
                    window: window
                ))
            }
        }
        return rows
    }

    /// A context window said the way people say it: 1048576 tokens is 1M,
    /// not "1048k" — every power of two would otherwise read as a number
    /// nobody recognises. Millions and thousands, never a division that
    /// leaves a remainder nobody would quote.
    private static func context(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? "\(tokens / 1_000_000)M context" : "\(tokens / 1000)k context"
    }

    private static func piHome() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let said = env["PI_CODING_AGENT_DIR"], !said.isEmpty {
            return URL(fileURLWithPath: (said as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
    }


    /// A pi session records every move as `{"type":"model_change",
    /// "provider":…,"modelId":…}`, so the last one in the run's own file
    /// is what it is on now — including a change made from pi's own menu,
    /// which the settings know nothing about.
    private static func piCurrent(in file: URL?) -> String? {
        var found: String?
        for line in tail(of: file) {
            guard let raw = (try? JSONSerialization.jsonObject(with: Data(line)))
                as? [String: Any], raw["type"] as? String == "model_change" else { continue }
            guard let provider = raw["provider"] as? String,
                  let id = raw["modelId"] as? String else { continue }
            found = "\(provider)/\(id)"
        }
        return found
    }

    // MARK: - Codex

    /// Codex's cache of the models its account may use, each a slug with a
    /// display name. A cache older than the CLI is still the best list
    /// there is, and a slug the account has lost answers with an error in
    /// the terminal rather than silently.
    private static func codexRows(_ home: URL) -> [Row] {
        guard let cache = json(home.appendingPathComponent("models_cache.json")),
              let models = cache["models"] as? [[String: Any]] else { return [] }
        let current = codexConfig(home)["model"]
        return models.compactMap { model in
            guard let slug = model["slug"] as? String else { return nil }
            let name = model["display_name"] as? String ?? slug
            var note = model["description"] as? String ?? ""
            if slug == current { note = note.isEmpty ? "in use" : note + " · in use" }
            return Row(label: name, value: slug, note: note)
        }
    }

    /// Codex keeps `model` and `model_provider` at the top of its TOML
    /// config, before the first table. Read as lines: a TOML parser for
    /// two keys would be a dependency and a lie about what is read.
    private static func codexConfig(_ home: URL) -> [String: String] {
        let file = home.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var said: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The first table ends the global keys; everything after is
            // some other section's business.
            if trimmed.hasPrefix("[") { break }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            said[key] = value
        }
        return said
    }

    private static func codexHome() -> URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    // MARK: - shared

    /// The last `model` an agent said on its own records — Claude writes
    /// it on every assistant line, so the tail of the talk is where the
    /// current one is. Read as a tail rather than whole: a transcript is
    /// megabytes by the end of a day, and the answer is in its last few.
    private static func lastModel(in file: URL?, key: String, field: String) -> String? {
        var found: String?
        for line in tail(of: file) {
            guard let raw = (try? JSONSerialization.jsonObject(with: Data(line)))
                as? [String: Any] else { continue }
            guard let said = raw[key] as? [String: Any],
                  let model = said[field] as? String else { continue }
            found = model
        }
        return found
    }

    /// The last part of a session file, as whole lines. A line cut by the
    /// seek is dropped unless it is the file's first — a partial record
    /// is not a record, and the one before it is still true.
    private static func tail(of file: URL?, bytes: Int = 262_144) -> [Data] {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: from)
        guard let chunk = try? handle.readToEnd() else { return [] }
        var lines = chunk.split(separator: 0x0A).map { Data($0) }
        if from > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func json(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// How full the agent's context window is. The numbers come from the
/// transcript (the agent states what it spent) and from whatever said what
/// the window is; nothing here estimates either one.
enum ContextMeter {
    /// The fraction used, or nil when there is nothing to say — no window
    /// known, or nothing spent yet. Clamped, because a run that has
    /// overflowed its window would otherwise draw a ring past itself.
    static func fraction(used: Int, window: Int) -> CGFloat? {
        guard window > 0, used > 0 else { return nil }
        return min(1, CGFloat(used) / CGFloat(window))
    }

    /// The ring's colour: the terminal's own ink until the window is
    /// nearly full, then a warning, then an error. A ring that only ever
    /// changed length would make a person read the arc to know how bad it
    /// is; the colour says it before the length does.
    static func tint(_ fraction: CGFloat, ink: NSColor) -> NSColor {
        if fraction >= 0.90 { return .systemRed }
        if fraction >= 0.70 { return .systemOrange }
        return ink.withAlphaComponent(0.75)
    }

    /// `<1%` rather than `0%`: a window with something in it is not empty,
    /// and rounding it away would say the agent has spent nothing.
    static func percent(used: Int, window: Int) -> String {
        guard let fraction = fraction(used: used, window: window) else { return "" }
        let rounded = (fraction * 100).rounded()
        return used > 0 && rounded < 1 ? "<1%" : "\(Int(rounded))%"
    }
}
