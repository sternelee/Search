import AppKit
import XCTest

@testable import Search

/// What the chat's model list is made of, and that choosing a row writes
/// the agent's own `/model` line into the terminal rather than pretending
/// to switch anything itself.
///
/// The catalogs are read from a temp home in each test, never from this
/// Mac's: a test that says "pi offers provider/model" must not depend on
/// what the machine running it happens to have configured.
@MainActor
final class AgentComposerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    /// A config folder of the agent's shape, made fresh for one test.
    private func root(_ agent: AgentTalk.Agent, _ files: [String: String]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-models-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, body) in files {
            try? body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        roots.append(root)
        return root
    }

    // MARK: - the catalogs

    /// pi says its models as `provider/model`, and its providers as
    /// headings over them: that is what its `/model` takes and how its own
    /// picker groups them.
    func testPisCatalogIsReadAsProviderOverModel() {
        let home = root(.pi, [
            "models.json": #"""
            {"providers":{
              "anthropic":{"models":[
                {"id":"claude-opus-4-5","name":"Opus 4.5","contextWindow":200000,"reasoning":true},
                {"id":"claude-haiku-4-5","name":"Haiku 4.5","contextWindow":200000}
              ]},
              "openai":{"models":[{"id":"gpt-5","name":"GPT-5"}]}
            }}
            """#,
            "settings.json": #"{"defaultProvider":"anthropic","defaultModel":"claude-opus-4-5"}"#,
        ])
        let rows = AgentModels.rows(for: .pi, root: home)
        XCTAssertEqual(rows.map(\.label), [
            "anthropic", "Opus 4.5", "Haiku 4.5", "openai", "GPT-5",
        ])
        XCTAssertEqual(rows[0].head, true, "a provider is a heading, not a choice")
        XCTAssertEqual(rows[1].value, "anthropic/claude-opus-4-5")
        XCTAssertEqual(rows[1].note, "200k context · reasoning")
        XCTAssertEqual(
            AgentModels.current(for: .pi, root: home), "anthropic/claude-opus-4-5",
            "the settings keep provider and model apart; a row is named with both"
        )
    }

    /// A pi run that moved away from its setting says so in its own file,
    /// one `model_change` line at a time — the last of them is the truth,
    /// because that is the one the session is on.
    func testPisCurrentModelComesFromItsOwnRecordOfTheChange() throws {
        let home = root(.pi, [
            "settings.json": #"{"defaultProvider":"anthropic","defaultModel":"claude-opus-4-5"}"#,
        ])
        let file = home.appendingPathComponent("run.jsonl")
        try """
        {"type":"model_change","provider":"anthropic","modelId":"claude-opus-4-5"}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        {"type":"model_change","provider":"openai","modelId":"gpt-5"}
        """.write(to: file, atomically: true, encoding: .utf8)
        let talk = AgentTalk.Talk(agent: .pi, id: "run", file: file, cwd: nil)
        XCTAssertEqual(
            AgentModels.current(for: .pi, talk: talk, root: home), "openai/gpt-5",
            "the record of the change wins over where the run started"
        )
    }

    /// Claude's picker is its own list of labels over model ids. The one
    /// in use is marked in the row's note, so the open list says which one
    /// it is without the drawing having to guess.
    func testClaudesPickerIsItsOwnLabelAndModel() {
        let home = root(.claude, [
            "settings.json": #"""
            {"model":"claude-opus-4-5-20251001","modelPicker":{"options":[
              {"label":"Opus 4.5","model":"claude-opus-4-5-20251001","description":"Deepest"},
              {"label":"Sonnet 4.5","model":"claude-sonnet-4-5-20250929"}
            ]}}
            """#,
        ])
        let rows = AgentModels.rows(for: .claude, root: home)
        XCTAssertEqual(rows.map(\.label), ["Opus 4.5", "Sonnet 4.5"])
        XCTAssertEqual(rows[0].value, "claude-opus-4-5-20251001")
        XCTAssertEqual(rows[0].note, "Deepest · in use")
        XCTAssertEqual(rows[1].note, "")
        XCTAssertEqual(AgentModels.current(for: .claude, root: home), "claude-opus-4-5-20251001")
    }

    /// A CLI nobody configured offers nothing. An invented list would
    /// send a `/model` the agent has never heard of, and the terminal
    /// would answer with an error the person did not ask for.
    func testAnAgentWithNoCatalogOffersNoRows() {
        let home = root(.claude, [:])
        XCTAssertEqual(AgentModels.rows(for: .claude, root: home), [])
        XCTAssertNil(AgentModels.current(for: .claude, root: home))
    }

    /// Codex keeps its models in a cache of slugs and its choice in the
    /// top of a TOML file, before any table starts. A key after the first
    /// `[table]` belongs to that table and is not the config's model.
    func testCodexReadsItsCacheAndTheTopOfItsConfig() {
        let home = root(.codex, [
            "models_cache.json": #"""
            {"models":[
              {"slug":"gpt-5-codex","display_name":"GPT-5 Codex","description":"For code"},
              {"slug":"gpt-5","display_name":"GPT-5"}
            ]}
            """#,
            "config.toml": """
            model = "gpt-5-codex"
            model_provider = "openai"

            [tools]
            model = "not-the-configs"
            """,
        ])
        let rows = AgentModels.rows(for: .codex, root: home)
        XCTAssertEqual(rows.map(\.label), ["GPT-5 Codex", "GPT-5"])
        XCTAssertEqual(rows[0].note, "For code · in use")
        XCTAssertEqual(
            AgentModels.current(for: .codex, root: home), "gpt-5-codex",
            "the model after the first table is that table's, not the config's"
        )
    }

    // MARK: - the composer

    /// The switch is a line written to the agent, not a state we keep: the
    /// pty is the one channel both views share, and the agent's own
    /// `/model` is what makes the change real. Same command for all three
    /// — what differs is only how a model is named.
    func testChoosingAModelWritesTheAgentsOwnCommand() throws {
        let view = TerminalView(terminal: Terminal(command: TerminalCommand(
            argv: ["/bin/sh", "-c", "printf 'ready\\n'; sleep 10"]
        )))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        window.orderFrontRegardless()
        window.orderOut(nil)

        var said: [String] = []
        let plate = TerminalChatView()
        plate.spoke = { said.append($0) }
        plate.switched = { said.append(AgentModels.switchCommand($0)) }
        plate.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        plate.takeModels([
            .head("anthropic"),
            AgentModels.Row(label: "Opus 4.5", value: "anthropic/claude-opus-4-5", note: ""),
            AgentModels.Row(label: "Haiku 4.5", value: "anthropic/claude-haiku-4-5", note: ""),
        ], current: "anthropic/claude-opus-4-5")

        // The chip says the current one, short enough to fit a corner.
        XCTAssertEqual(plate.model.label, "anthropic/claude-opus-4-5")
        XCTAssertEqual(TerminalModelChip.short("anthropic/claude-opus-4-5"), "anthropic/claude-opus-4-5")
        XCTAssertEqual(
            TerminalModelChip.short("some/deep/provider/model-4-5"), "provider/model-4-5",
            "a long id keeps its tail, which is the part that tells models apart"
        )

        // The list opens on the model in use, so opening and pressing
        // return changes nothing.
        plate.toggleModels(open: true)
        XCTAssertTrue(plate.askingModels)
        XCTAssertEqual(plate.list.highlighted, 1)

        // Two steps down and back up: the heading is skipped both ways.
        _ = plate.list.step(1)
        XCTAssertEqual(plate.list.highlighted, 2)
        _ = plate.list.step(1)
        XCTAssertEqual(plate.list.highlighted, 1, "a heading is never the highlighted row")
        _ = plate.list.step(-1)
        XCTAssertEqual(plate.list.highlighted, 2)

        // Choosing writes the command the agent listens for and closes
        // the list; the chip already says the new model.
        plate.take(try XCTUnwrap(plate.list.choose()))
        XCTAssertEqual(said, ["/model anthropic/claude-haiku-4-5"])
        XCTAssertFalse(plate.askingModels)
        XCTAssertEqual(plate.modelWords, "anthropic/claude-haiku-4-5", "the chip says the new one at once")
    }

    /// The composer's furniture is placed once and agreed on: the talk sits
    /// above the box, the line inside it, the chip in its footer, and the
    /// list above the whole box rather than over the text being typed. A
    /// drawing bug here would be invisible in a unit test that only asked
    /// the model questions, so the frames are asserted too.
    func testTheComposerPlacesItsPartsAndTheListAboveThem() {
        let plate = TerminalChatView()
        plate.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        plate.takeModels([
            .head("magpie"),
            AgentModels.Row(label: "DeepSeek V4.1 Flash", value: "auto/deepseek-v4.1-flash", note: ""),
            AgentModels.Row(label: "GLM-5.3", value: "auto/glm-5.3", note: ""),
        ], current: "auto/glm-5.3")
        plate.layoutSubtreeIfNeeded()

        let box = plate.model.frame.union(plate.field.frame)
        XCTAssertGreaterThan(
            box.maxY, 0, "the composer sits in the pane's lower edge, not off it"
        )
        XCTAssertGreaterThan(
            plate.paper.frame.minY, box.maxY - 30,
            "the talk starts above the composer rather than under it"
        )
        XCTAssertTrue(plate.list.isHidden, "the list waits to be asked for")

        plate.toggleModels(open: true)
        plate.layoutSubtreeIfNeeded()
        XCTAssertFalse(plate.list.isHidden)
        let list = plate.list.frame
        XCTAssertGreaterThanOrEqual(
            list.minY, box.maxY, "the list opens above the chip it belongs to"
        )
        XCTAssertLessThanOrEqual(
            list.maxY, plate.bounds.maxY, "and never past the top of the pane"
        )
        XCTAssertGreaterThan(list.height, 40, "with room for its rows")
        XCTAssertEqual(
            plate.list.highlighted, 2, "opening the list lands on the model in use"
        )
    }

    /// A run's own file is read from its tail, not whole: a day of
    /// transcripts is megabytes, and the current model is in the last few
    /// records. The line the seek cuts is not a record and is dropped — the
    /// one before it is still true.
    func testTheCurrentModelIsFoundInATailThatStartsMidRecord() throws {
        let home = root(.pi, [:])
        let file = home.appendingPathComponent("big.jsonl")
        // A first record that is a real change, then enough padding to
        // push it out of any reasonable tail, then the change that counts.
        var text = #"{"type":"model_change","provider":"openai","modelId":"gpt-4"}"# + "\n"
        for i in 0..<4000 {
            text += #"{"type":"message","id":\#(i),"message":{"role":"user","content":[{"type":"text","text":"\#(String(repeating: "x", count: 90))"}]}}"# + "\n"
        }
        text += #"{"type":"model_change","provider":"magpie","modelId":"group/auto"}"# + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0, 262_144)

        let talk = AgentTalk.Talk(agent: .pi, id: "big", file: file, cwd: nil)
        XCTAssertEqual(
            AgentModels.current(for: .pi, talk: talk, root: home), "magpie/group/auto",
            "the last change is found from the tail"
        )
    }

    /// The line grows with the question and stops growing: a box that kept
    /// expanding upward as a person typed would eat the conversation it is
    /// asking about, so past a few lines the text scrolls inside a box
    /// that has stopped.
    func testTheLineGrowsWithTheQuestionAndThenStops() {
        let plate = TerminalChatView()
        plate.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        plate.layoutSubtreeIfNeeded()
        let one = plate.paper.frame.height
        XCTAssertGreaterThan(one, 0)

        plate.field.stringValue = String(
            repeating: "把 dock 的行数让位再检查一遍，特别是 gridFloor 那一段的 slack。", count: 6
        )
        plate.needsLayout = true
        plate.layoutSubtreeIfNeeded()
        let many = plate.paper.frame.height
        XCTAssertLessThan(many, one, "the talk gives up room to the growing line")

        // And no further: past its most lines the box stops, and the field
        // editor scrolls the rest. Asked by writing twice as much again —
        // a page and two pages must be the same box, or the talk would be
        // eaten a line at a time.
        plate.field.stringValue = String(repeating: "再长一点。", count: 200)
        plate.needsLayout = true
        plate.layoutSubtreeIfNeeded()
        let page = plate.paper.frame.height
        plate.field.stringValue = String(repeating: "再长一点。", count: 400)
        plate.needsLayout = true
        plate.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            abs(plate.paper.frame.height - page), 0.5,
            "past its most lines the box stops growing"
        )
        XCTAssertGreaterThan(page, 0, "and the talk is still there")
    }
}
