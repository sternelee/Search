import SwiftUI

// The AI add-on as you meet it: Summarize Page and Ask About This Page…, and
// the panel the answer comes in. One page at a time, from your click; the
// questions after the first stay in the panel, and close it and they are
// gone — nothing is kept anywhere. The answer is plain text, never a link to
// follow or a picture to fetch, marked for what it is: a model's reading,
// which may be wrong, and where it ran. What the page says goes to the model
// as the page's words to read, never as orders (see AIPage), and anything
// in the answer the page didn't have is pointed out.
//
// A provider off this Mac is shown what it will be sent the first time it is
// used, before anything goes. A private tab uses only what runs on this Mac.

/// One conversation about one page.
@MainActor
final class Assistant: ObservableObject, Identifiable {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        /// Nil for the summary.
        let question: String?
        var answer = ""
        /// The model is thinking — shown while the answer has no words yet
        /// (see `answer()`).
        var thinking = false
        var done = false
        var failed: String?
        /// Addresses, emails and numbers in the answer the page doesn't have.
        var strays: [String] = []
    }

    let id = UUID()
    let tab: Tab.ID
    let provider: AIProvider
    let model: String
    /// Asked for a summary, rather than opened for a question.
    let summary: Bool

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var reading = true
    @Published var draft = ""
    /// What a provider off this Mac is sent, not yet agreed to.
    @Published private(set) var notice: String?
    @Published private(set) var trouble: String?
    /// The page has words addressed to an AI (see AIPage.addressesAI).
    @Published private(set) var addressed = false

    private var read: AIPage.Read?
    private let fence = AIPage.newFence()
    private var messages: [AIMessage] = []
    private var waiting: AIPage.Ask?
    private var task: Task<Void, Never>?
    /// Tool calls and skills asked for in this conversation, bounded (see
    /// `follow`).
    private var steps = 0

    init(tab: Tab, provider: AIProvider, model: String, summary: Bool) {
        self.tab = tab.id
        self.provider = provider
        self.model = model
        self.summary = summary
        // The read-only tools the person keeps are offered to this panel
        // (see AIDescribed.forAsking): their servers connected in the
        // background while the page is being read, so the tools are there
        // to list by the time a question is asked.
        MCPHub.shared.wake()
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            self.read = await AIPage.read(tab)
            self.addressed = self.read?.addressed ?? false
            self.reading = false
            guard self.read != nil else {
                self.trouble = "There's nothing on this page to read."
                return
            }
            if summary { self.ask(.summary) }
        }
    }

    var busy: Bool { reading || turns.last.map { !$0.done } ?? false }

    /// Where it ran, for the foot of every answer.
    var place: String {
        provider == .thisMac ? "on this Mac · \(model)"
            : provider.isLocal ? "on this Mac · \(provider.name) · \(model)" : "sent to \(provider.name) · \(model)"
    }

    func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, notice == nil, read != nil else { return }
        draft = ""
        ask(.question(String(question.prefix(2000))))
    }

    private func ask(_ ask: AIPage.Ask) {
        if !provider.isLocal, !Store.settings.bool(forKey: "ai.told.\(provider.rawValue)") {
            waiting = ask
            notice = AIAssist.notice(for: provider)
            return
        }
        send(ask)
    }

    /// The notice read and agreed to: what was asked goes.
    func agree() {
        Store.settings.set(true, forKey: "ai.told.\(provider.rawValue)")
        notice = nil
        if let waiting { send(waiting) }
        waiting = nil
    }

    private func send(_ ask: AIPage.Ask) {
        guard let read else { return }
        switch ask {
        case .summary:
            messages = [AIMessage(role: .user, text: AIPage.opening(read, .summary, fence: fence))]
            turns.append(Turn(question: nil))
        case .question(let question):
            messages.append(AIMessage(role: .user, text: messages.isEmpty ? AIPage.opening(read, ask, fence: fence) : question))
            turns.append(Turn(question: question))
        }
        steps = 0
        answer()
    }

    /// The turn is asked of the model — the first time, and again when a
    /// tool's or a skill's material has come back (see `follow`). Tools and
    /// skills of the person's ride along when there are any, only the ones
    /// that say they read (see AIDescribed.forAsking).
    private func answer() {
        guard read != nil else { return }
        if !turns.isEmpty { turns[turns.count - 1].answer = "" }
        let system = AIPage.system(fence: fence) + AIDescribed.forAsking()
        // The key, read now and let go with the request.
        let key = provider.isLocal ? nil : AIKeys.key(for: provider)
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: system, messages: messages)
            : AIClient.shared.stream(provider, model: model, system: system, messages: messages, key: key)
        task = Task { @MainActor [weak self] in
            do {
                for try await piece in stream {
                    guard let self, !self.turns.isEmpty else { return }
                    // A thinking model's thoughts are not the answer about
                    // the page; they go by (see AIPiece).
                    guard piece.kind == .answer else {
                        self.turns[self.turns.count - 1].thinking = true
                        continue
                    }
                    self.turns[self.turns.count - 1].answer += piece.words
                    // Longer than any answer about a page needs: a model
                    // talked into writing on and on is stopped.
                    if self.turns[self.turns.count - 1].answer.count > Assistant.longest { break }
                }
                // A reply that is one call is followed, not finished (see
                // `follow`); anything else ends the turn.
                if let self, !self.turns.isEmpty,
                   let call = AIDescribed.call(in: self.turns[self.turns.count - 1].answer),
                   self.follow(call) { return }
                self?.finish(nil)
            } catch {
                self?.finish(error.localizedDescription)
            }
        }
    }

    /// A reply given over to one tool call or one skill is followed, not
    /// shown: the call is made — only tools that say they read are offered,
    /// so this panel never touches anything — and what comes back goes in
    /// as the next material, the same turn answered again. Bounded, so a
    /// model that calls on and on is stopped and its last words stand.
    private func follow(_ call: (tool: (name: String, arguments: [String: Any])?, skill: String?)) -> Bool {
        guard steps < Assistant.steps, !turns.isEmpty else { return false }
        steps += 1
        // What the model said stays part of the conversation; the person
        // sees a word on what's happening instead.
        messages.append(AIMessage(role: .assistant, text: turns[turns.count - 1].answer))
        turns[turns.count - 1].answer = call.tool != nil ? "Looking something up…" : "Reading one of your skills…"
        task = Task { @MainActor [weak self] in
            guard let self, !self.turns.isEmpty else { return }
            var material: String
            if let tool = call.tool {
                do {
                    let said = try await MCPHub.shared.call(tool.name, arguments: tool.arguments)
                    var words = said.text.isEmpty ? "nothing" : said.text
                    if words.count > Assistant.pageful { words = String(words.prefix(Assistant.pageful)) + "…" }
                    material = "The tool \(tool.name) \(said.failed ? "said it failed" : "said"):\n\(words)"
                } catch {
                    material = "The tool \(tool.name) didn't work: \(error.localizedDescription). Answer without it."
                }
            } else if let skill = call.skill {
                if let id = Skills.listed().first(where: { $0.name == skill })?.id,
                   let body = Skills.body(id) {
                    var words = body
                    if words.count > Assistant.pageful { words = String(words.prefix(Assistant.pageful)) + "…" }
                    material = "The skill \(skill), the person's own words:\n\n\(words)"
                } else {
                    material = "There's no skill called \(skill) — answer without it."
                }
            } else { return }
            self.messages.append(AIMessage(role: .user, text: material))
            self.answer()
        }
        return true
    }

    nonisolated static let longest = 16_000
    /// What a tool or a skill may say into the conversation, capped like a
    /// page (see AIPage).
    nonisolated static let pageful = 8_000
    /// Tool calls and skills asked for in one conversation, before the
    /// model is made to answer in words.
    static let steps = 6

    private func finish(_ failed: String?) {
        guard !turns.isEmpty, let read else { return }
        var turn = turns[turns.count - 1]
        turn.done = true
        turn.thinking = false
        turn.failed = failed
        turns[turns.count - 1] = turn
        // Checked away from the window's thread: a long answer is a long look.
        let id = turn.id, answer = turn.answer
        Task.detached(priority: .userInitiated) { [weak self] in
            let strays = AIPage.strays(in: answer, from: read)
            await MainActor.run { [weak self] in
                guard let self, let index = self.turns.firstIndex(where: { $0.id == id }) else { return }
                self.turns[index].strays = strays
            }
        }
        if failed == nil, !turn.answer.isEmpty {
            messages.append(AIMessage(role: .assistant, text: turn.answer))
        } else if !messages.isEmpty {
            // A question that got no answer isn't part of what follows; the
            // page goes again with the next one if it was the first.
            messages.removeLast()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

enum AIAssist {
    /// What a provider off this Mac is sent, said once, the first time it is
    /// used — and a word on what it does with it where that matters.
    static func notice(for provider: AIProvider) -> String {
        var text = "When you ask, Search sends this page's text, its address and your question to \(provider.host)"
        text += provider == .openRouter ? ", which passes them to the model's provider." : "."
        text += " Their terms and privacy policy apply. Nothing is sent until you ask, never from a private tab, and Search keeps no copy."
        // Reads allowed beyond the page go to the provider too, each held
        // for an Allow first — the person should know from the start that
        // allowing one is sending it.
        text += " Reads you allow beyond the page — your history, for one — go with it."
        switch provider {
        case .gemini:
            text += "\n\nOn Gemini's free tier, outside the EEA, Switzerland and the UK, Google may use this to improve its products, and people may read it. Don't use it on sensitive pages."
        case .openRouter:
            text += "\n\nSearch asks OpenRouter to use only providers that keep nothing (zero data retention)."
        default:
            break
        }
        return text
    }
}

extension Browser {
    func summarizePage() { startAssistant(summary: true) }
    func askAboutPage() { startAssistant(summary: false) }

    private func startAssistant(summary: Bool) {
        guard AI.shipped || Store.testing, let tab = active, !tab.isBlank else { return }
        guard prefs.ai, let provider = prefs.aiProvider else {
            settingsPage = .ai
            tuning = true
            announce(prefs.ai ? "Choose where the AI runs" : "Turn on AI in Settings › AI")
            return
        }
        // A web page, nothing else: not a file, not an extension's page.
        guard let scheme = tab.pageAddress?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            announce("AI works on web pages")
            return
        }
        // A private tab leaves nothing behind anywhere, a provider included.
        let shy = tab.shy || tab.built.map { !$0.configuration.websiteDataStore.isPersistent } == true
        guard !shy || provider.isLocal else {
            announce("In a private tab, only an AI on this Mac")
            return
        }
        if provider == .thisMac, AIEngine.shared.state != .ready {
            settingsPage = .ai
            tuning = true
            announce("The model isn't on this Mac yet")
            return
        }
        let model = prefs.aiModel(for: provider)
        guard !model.isEmpty else {
            settingsPage = .ai
            tuning = true
            announce("Choose a model for \(provider.name)")
            return
        }
        guard provider.isLocal || AIKeys.hint(for: provider) != nil else {
            settingsPage = .ai
            tuning = true
            announce("No key for \(provider.name) yet")
            return
        }
        // Asked again on the page the panel is already about: the same
        // conversation goes on.
        if !summary, let open = assisting, open.tab == tab.id, open.provider == provider { return }
        assisting?.stop()
        assisting = Assistant(tab: tab, provider: provider, model: model, summary: summary)
    }

    func closeAssistant() {
        assisting?.stop()
        assisting = nil
    }
}

// MARK: - the panel

struct AssistantPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var assistant: Assistant
    /// Drawn off screen, for a picture (bench ai picture): what an image
    /// renderer can't draw — a scroll view, a field — stood in for.
    var drawn = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text(assistant.summary ? "Summary" : "About this page")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Door(icon: "xmark", help: "Close   esc") { browser.closeAssistant() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if drawn {
                conversation.padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                scrolling
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                if drawn {
                    Text("Ask about this page…").font(.system(size: 12.5)).foregroundStyle(Palette.faint)
                } else {
                    TextField("", text: $assistant.draft, prompt: Text("Ask about this page…").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .focused($typing)
                        .onSubmit { assistant.submit() }
                        .disabled(assistant.notice != nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Text("AI — may be wrong · \(assistant.place)")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(width: 380, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 8)
        .onAppear { if !assistant.summary, !drawn { typing = true } }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = assistant.notice {
                noticeCard(notice)
            } else if let trouble = assistant.trouble {
                Text(trouble).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            } else if assistant.reading {
                Text("Reading the page…").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
            if assistant.addressed, assistant.notice == nil {
                caution("This page has text written for an AI to follow. The answer may have been steered by it.")
            }
            ForEach(assistant.turns) { turn in
                TurnView(turn: turn, openLink: openLink).id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caution(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
            Text(verbatim: text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(8)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var scrolling: some View {
            ScrollViewReader { scroller in
                ScrollView(showsIndicators: false) {
                    conversation
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                .onChange(of: assistant.turns.last?.answer) { _, _ in
                    if let last = assistant.turns.last { scroller.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: 420)
    }

    /// A link tapped in the answer: opened the browser's way, the
    /// same as a link on any page — never by the model's words alone.
    private func openLink(_ url: URL) {
        browser.open(url, foreground: true)
    }

    private func noticeCard(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Answers from \(assistant.provider.name)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(verbatim: notice)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Pill("Continue", filled: true) { assistant.agree() }
                Pill("Cancel") { browser.closeAssistant() }
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private struct TurnView: View {
        let turn: Assistant.Turn
        /// A link's tap, opened the browser's way — the panel's own open.
        let openLink: (URL) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let question = turn.question {
                    Text(verbatim: question)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                if turn.answer.isEmpty, !turn.done {
                    Text(turn.thinking ? "Thinking…" : "…")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                }
                // The answer as the model wrote it: headings, lists,
                // code blocks, bold, links — read the way they were
                // written (see MarkdownText).
                if !turn.answer.isEmpty {
                    MarkdownText(open: openLink, text: turn.answer, size: 13)
                }
                if let failed = turn.failed {
                    Text(verbatim: failed).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                if !turn.strays.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .medium))
                        Text(verbatim: "Not on the page: " + turn.strays.joined(separator: ", "))
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

// MARK: - Settings › AI

struct AISettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// Drawn off screen, for a picture: menus and fields stood in for.
    var drawn = false
    /// The side stayed on, kept between visits (the words on top, see
    /// Tabs): the AI itself, the tools of the wider world, the skills.
    @State private var side: Side = Side(rawValue: Store.settings.string(forKey: "ai.page") ?? "") ?? .ai
    @State private var pasted = ""
    @State private var hint: String?
    @State private var models: [String] = []
    @State private var looking = false
    @ObservedObject private var engine = AIEngine.shared
    /// The Test row's one message: on its way, and what came of it.
    @State private var testing = false
    @State private var testResult: String?
    @State private var testTrouble: String?
    @State private var testTask: Task<Void, Never>?

    /// The sides of Settings › AI.
    enum Side: String {
        case ai, mcp, skills, chores
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Tabs(picked: Binding(get: { side.rawValue },
                                set: { side = Side(rawValue: $0) ?? .ai }),
                 (id: "ai", title: "AI"), (id: "mcp", title: "MCP"), (id: "skills", title: "Skills"), (id: "chores", title: "Tasks"))
            switch side {
            case .ai:
                theAI
            case .mcp:
                MCPServersView(drawn: drawn)
            case .skills:
                SkillsShelf(drawn: drawn)
            case .chores:
                ChoresList(drawn: drawn)
            }
        }
        // The side stayed on, kept between visits.
        .onChange(of: side) { _, fresh in
            Store.settings.set(fresh.rawValue, forKey: "ai.page")
        }
    }

    /// The AI side: the bot, the add-on, where it runs, and the keys.
    private var theAI: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("The bot on pages", "Summon it over a page with ⌥⌘B: it reads the page, talks about it, and works it for you — every change waits for your Allow. Nothing is sent until you ask") {
                    Switch(on: $prefs.bot)
                }
            }
            if AI.shipped {
                Card {
                    Line("Use AI on pages", "Summarize a page, or ask about it, from the View menu. Nothing is sent until you ask") {
                        Switch(on: $prefs.ai)
                    }
                }
            }
            if prefs.bot || prefs.ai {
                Card {
                    Line("Where it runs", place) {
                        if drawn {
                            Stand(prefs.aiProvider.map { $0.isLocal ? "\($0.name), on this Mac" : $0.name } ?? "Choose…", menu: true)
                        } else {
                        Picker("", selection: Binding(get: { prefs.aiProvider }, set: { prefs.aiProvider = $0 })) {
                            Text("Choose…").tag(AIProvider?.none)
                            ForEach(AIProvider.allCases.filter { $0 != .thisMac || engine.available || prefs.aiProvider == .thisMac }) { provider in
                                Text(provider == .thisMac ? provider.name : provider.isLocal ? "\(provider.name), on this Mac" : provider.name)
                                    .tag(AIProvider?.some(provider))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        }
                    }
                    if let provider = prefs.aiProvider {
                        Rule()
                        if provider == .thisMac {
                            onThisMac
                            // Nothing to ask until the model is here.
                            if engine.state == .ready { Rule(); test(provider) }
                        } else if provider.isLocal {
                            localModel(provider)
                            Rule()
                            test(provider)
                        } else {
                            address(provider)
                            Rule()
                            key(provider)
                            Rule()
                            cloudModel(provider)
                            Rule()
                            test(provider)
                        }
                    }
                }
                .onChange(of: prefs.aiProvider) { _, _ in
                    // A key typed for one provider is never saved for another.
                    pasted = ""
                    forgetTest()
                    refresh()
                }
                .onAppear(perform: refresh)
                Card {
                    Line("Thinking", "How hard the model reasons before it speaks — off for providers that don't think, and for the model on this Mac") {
                        if drawn {
                            Stand(prefs.botThinking.name, menu: true)
                        } else {
                            Picker("", selection: $prefs.botThinking) {
                                ForEach(BotThinking.allCases) { level in
                                    Text(level.name).tag(level)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                    Rule()
                    Line("Tool calls", "The most tool calls one turn makes before it wraps up with an answer") {
                        if drawn {
                            Stand("\(prefs.botSteps)")
                        } else {
                            Stepper(value: $prefs.botSteps, in: 1...50) {
                                Text("\(prefs.botSteps)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Palette.ink)
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .fixedSize()
                        }
                    }
                }
                Card {
                    Line("Forget every key", "Deletes them from this Mac's keychain. A key made by signing in with OpenRouter still works until you delete it on openrouter.ai") {
                        Pill("Forget") {
                            AIKeys.forgetAll()
                            refresh()
                            browser.announce("Keys forgotten")
                        }
                    }
                }
            }
        }
    }

    /// The model here: downloaded when you say, checked, prepared once.
    @ViewBuilder
    private var onThisMac: some View {
        let size = ByteCountFormatter.string(fromByteCount: engine.downloadSize, countStyle: .file)
        if AIEngine.translated {
            Line("Model", "Needs the Apple Silicon version of Search — this copy runs translated") { EmptyView() }
        } else {
            switch engine.state {
            case .absent:
                Line("Model", "\(AIEngine.model.name), downloaded once (\(size)) and checked. Nothing leaves this Mac") {
                    Pill("Download", filled: true) { engine.install() }
                }
            case .downloading(let done):
                Line("Model", "Downloading… \(Int(done * 100))%") {
                    Pill("Cancel") { engine.cancelInstall() }
                }
            case .preparing:
                Line("Model", "Preparing it for this Mac — about twenty seconds, once") { EmptyView() }
            case .ready:
                Line("Model", "\(AIEngine.model.name), on this Mac. Nothing leaves it") {
                    Pill("Remove") { engine.remove() }
                }
            case .failed(let why):
                Line("Model", why) {
                    Pill("Try Again") { engine.install() }
                }
            }
        }
    }

    private var place: String {
        guard let provider = prefs.aiProvider else { return "A provider you have a key with, or an app on this Mac" }
        return provider.isLocal
            ? "Nothing leaves this Mac. Also in private tabs"
            : "Your key, kept in this Mac's keychain, sent only to \(provider.host). Never from a private tab"
    }

    /// Where requests go, for the two providers that take an address of their
    /// own: a gateway, a relay, an account under another name. Empty is the
    /// provider's own address, and a key is kept for the host named here and
    /// sent nowhere else (see AIKeys.account).
    @ViewBuilder
    private func address(_ provider: AIProvider) -> some View {
        if provider.takesAnotherAddress {
            Line("Base URL", "Leave empty for \(provider.own.host() ?? ""). A key is kept for the host named here and sent nowhere else") {
                if drawn {
                    Stand(prefs.aiBase(for: provider).isEmpty ? (provider.own.host() ?? "") : prefs.aiBase(for: provider), width: 170)
                } else {
                    TextField("", text: Binding(get: { prefs.aiBase(for: provider) },
                                                set: { prefs.setAIBase($0, for: provider) }),
                              prompt: Text(provider.own.host() ?? "").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 170)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        // The key line below is about the host, so it says a
                        // key is wanted as soon as an address is named.
                        .onChange(of: prefs.aiBase(for: provider)) { _, _ in
                            // A test of the address that was there says nothing
                            // about this one.
                            forgetTest()
                            refresh()
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func key(_ provider: AIProvider) -> some View {
        if let hint {
            // Where a key is kept, and how long it lasts: this Mac's keychain
            // unless it wouldn't take one (see AIKeys.available).
            Line("Key", "\(hint)\(AIKeys.available ? ", in this Mac's keychain" : ", kept for this run only")") {
                Pill("Forget") {
                    AIKeys.forget(provider)
                    refresh()
                }
            }
        } else if provider.takesAnotherAddress, let elsewhere = AIKeys.held(for: provider).first {
            // A key given for the provider's own address, with another one
            // named since: said, and offered for the address in use now.
            Line("Key", "••••\(elsewhere.tail), kept for \(elsewhere.host) — not for \(provider.host)") {
                Pill("Keep for This Address") {
                    _ = AIKeys.carry(provider, from: elsewhere.host)
                    refresh()
                }
            }
        } else {
            Line("Key", keyPrompt(provider)) {
                HStack(spacing: 6) {
                    SecureField("", text: $pasted, prompt: Text("Key").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 130)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit { save(provider) }
                    Pill("Save") { save(provider) }
                    if provider == .openRouter {
                        Pill("Sign In…") {
                            browser.tuning = false
                            AISignIn.start(in: browser)
                        }
                    }
                }
                // The field and its buttons keep their size, and the words
                // above wrap instead: squeezed, a pill's label stands on end.
                .fixedSize()
            }
        }
    }

    private func cloudModel(_ provider: AIProvider) -> some View {
        Line("Model", "Leave empty for \(provider.defaultModel)") {
            if drawn {
                Stand(prefs.aiModels[provider.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel, width: 170)
            } else {
            TextField("", text: Binding(get: { prefs.aiModels[provider.rawValue] ?? "" },
                                        set: { prefs.setAIModel($0, for: provider) }),
                      prompt: Text(provider.defaultModel).foregroundStyle(Palette.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 170)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    /// One short message to the provider, sent and shown: whether the address,
    /// the key and the model work together. Said plainly, because a bot that
    /// answers nothing is the thing this is for.
    @ViewBuilder
    private func test(_ provider: AIProvider) -> some View {
        Line("Test", testing ? "Asking \(provider.host)…" : "Send one short message to \(provider.host), and read what comes back") {
            if drawn {
                Stand("Test")
            } else {
                Pill(testing ? "Testing…" : "Test") { ask(provider) }
            }
        }
        if let said = testResult {
            Line("It answered", said) { EmptyView() }
        }
        if let trouble = testTrouble {
            Line("It didn't answer", trouble) { EmptyView() }
        }
    }

    /// The Test row's one message, sent: the answer, or why there wasn't one.
    private func ask(_ provider: AIProvider) {
        forgetTest()
        testing = true
        let model = prefs.aiModel(for: provider)
        let key = provider.isLocal ? nil : AIKeys.key(for: provider)
        testTask = Task { @MainActor in
            var said: String?
            var why: String?
            do { said = try await AITest.answer(provider, model: model, key: key) }
            catch { why = error.localizedDescription }
            // Another provider, another address, another test: this answer is
            // about something that is no longer on the page.
            guard !Task.isCancelled else { return }
            testing = false
            if let why { testTrouble = why }
            else if let said { testResult = said.isEmpty ? "It answered with nothing at all." : said }
        }
    }

    /// Let go of the last test: it was about another provider or another
    /// address, and its answer would be read as this one's.
    private func forgetTest() {
        testTask?.cancel()
        testTask = nil
        testing = false
        testResult = nil
        testTrouble = nil
    }

    /// A menu or a field, as a picture shows it.
    struct Stand: View {
        let text: String
        var menu = false
        var width: CGFloat?
        init(_ text: String, menu: Bool = false, width: CGFloat? = nil) { self.text = text; self.menu = menu; self.width = width }
        var body: some View {
            HStack(spacing: 5) {
                Text(text).font(.system(size: 12)).foregroundStyle(menu ? Palette.ink : Palette.faint)
                if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted) }
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(menu ? Palette.ground : Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(menu ? Palette.hairline : .clear, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func localModel(_ provider: AIProvider) -> some View {
        if models.isEmpty {
            Line("Model", looking ? "Asking \(provider.name)…" : "\(provider.name) isn't running, or has no model yet") {
                Pill("Look Again") { refresh() }
            }
        } else {
            Line("Model", "From \(provider.name) on this Mac") {
                Picker("", selection: Binding(get: { prefs.aiModel(for: provider) }, set: { prefs.setAIModel($0, for: provider) })) {
                    Text("Choose…").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private func save(_ provider: AIProvider) {
        let key = pasted
        pasted = ""
        switch AIKeys.save(key, for: provider) {
        case .kept: browser.announce("Key kept in this Mac's keychain")
        case .unavailable: browser.announce("The keychain wouldn't take the key — kept for this run")
        case .failed: browser.announce("The key wasn't kept")
        }
        refresh()
    }

    /// What the key line says under a paste field: where a pasted key is kept,
    /// which depends on whether the keychain will take one at all (see
    /// AIKeys.available).
    private func keyPrompt(_ provider: AIProvider) -> String {
        let open = AIKeys.available ? "Paste your API key — kept in this Mac's keychain"
            : "Paste your API key — kept for this run only"
        return provider == .openRouter ? "Paste one, or sign in and OpenRouter makes one for you" : open
    }

    /// Looked at when the page is: a local app is asked for its models only
    /// now, never in the background.
    private func refresh() {
        guard let provider = prefs.aiProvider else { return }
        hint = provider.isLocal ? nil : AIKeys.hint(for: provider)
        models = []
        guard provider.isLocal else { return }
        looking = true
        Task { @MainActor in
            models = await AIClient.shared.localModels(provider)
            looking = false
        }
    }
}

/// The MCP side of Settings › AI: the person's own servers, switched on
/// apiece and taken out by hand, one added by hand too — a program run on
/// this Mac or an address elsewhere (see MCP). Nothing is contacted until
/// a server is switched on, and none runs behind the person's back.
private struct MCPServersView: View {
    var drawn = false
    @ObservedObject private var hub = MCPHub.shared
    @State private var name = ""
    /// A program run on this Mac, or an address elsewhere.
    @State private var program = true
    @State private var command = ""
    @State private var arguments = ""
    @State private var address = ""
    /// Headers to give with every request over HTTP, as they're typed in.
    @State private var headerRows: [HeaderField] = []
    @State private var trouble: String?

    /// One header of an address, as it's typed in: its name, and what it says.
    private struct HeaderField: Identifiable {
        let id = UUID()
        var name = ""
        var worth = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                if hub.servers.isEmpty {
                    Nothing("No servers yet — the bot has no tools beyond the page. Add one below")
                } else {
                    ForEach(Array(hub.servers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 { Rule() }
                        Line(server.config.name, "\(whereItIs(server.config)) · \(server.state.words)") {
                            HStack(spacing: 8) {
                                if drawn {
                                    AISettings.Stand(hub.enabled(server.config.name) ? "On" : "Off")
                                } else {
                                    Switch(on: Binding(get: { hub.enabled(server.config.name) },
                                                       set: { hub.setEnabled(server.config.name, $0) }))
                                }
                                Quick("Remove") { hub.remove(server.config.name) }
                            }
                        }
                    }
                }
            }
            Card {
                Line("Add a server", "Its tools are offered to the bot, and the ones that say they read to the questions about a page") {
                    EmptyView()
                }
                Rule()
                Line("Name", "Its tools are met by it: Name · tool") {
                    field($name, prompt: "weather", width: 130)
                }
                Rule()
                Line("Kind", nil) {
                    if drawn {
                        AISettings.Stand(program ? "Program" : "Address", menu: true)
                    } else {
                        Picker("", selection: $program) {
                            Text("Program").tag(true)
                            Text("Address").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                if program {
                    Rule()
                    Line("Program", "Run on this Mac, spoken to over its pipes") {
                        field($command, prompt: "/opt/homebrew/bin/weather", width: 170)
                    }
                    Rule()
                    Line("Arguments", "One after another, apart") {
                        field($arguments, prompt: "--unit celsius", width: 170)
                    }
                } else {
                    Rule()
                    Line("Address", "Over HTTP, answered one request at a time") {
                        field($address, prompt: "https://example.com/mcp", width: 170)
                    }
                    Rule()
                    Line("Headers", "Given with every request — a token to say who's asking, or whatever else the server wants to hear") {
                        Quick("+ Header") { headerRows.append(HeaderField()) }
                    }
                    ForEach($headerRows) { $header in
                        Rule()
                        Line("Header", "Its name, and what it says") {
                            HStack(spacing: 6) {
                                field($header.name, prompt: "Authorization", width: 105)
                                field($header.worth, prompt: "Bearer …", width: 125)
                                Quick("Remove") { headerRows.removeAll { $0.id == header.id } }
                            }
                            // The fields and the Remove keep their size, and the
                            // words above wrap instead: squeezed, a pill's label
                            // stands on end.
                            .fixedSize()
                        }
                    }
                }
                if let trouble {
                    Rule()
                    Line("It wasn't added", trouble) { EmptyView() }
                }
                Rule()
                Line("", nil) {
                    Pill("Add Server", filled: true) { add() }
                }
            }
        }
    }

    /// A program on this Mac, or an address elsewhere — with the headers
    /// it was given, if an address with some.
    private func whereItIs(_ config: MCPServer.Config) -> String {
        if let command = config.command?.trimmingCharacters(in: .whitespaces), !command.isEmpty {
            let rest = (config.args ?? []).joined(separator: " ")
            return "on this Mac: \(command)\(rest.isEmpty ? "" : " \(rest)")"
        }
        let headers = config.headers?.count ?? 0
        return (config.url ?? "") + (headers > 0 ? " · \(headers) header\(headers == 1 ? "" : "s")" : "")
    }

    /// The field of a line, as the plate draws them.
    @ViewBuilder
    private func field(_ text: Binding<String>, prompt: String, width: CGFloat) -> some View {
        if drawn {
            AISettings.Stand(prompt, width: width)
        } else {
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: width)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onSubmit { add() }
        }
    }

    private func add() {
        var config = MCPServer.Config(name: name)
        if program {
            config.command = command
            config.args = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        } else {
            config.url = address
            // A header named is a header kept; of two of one name, the last
            // word wins.
            let kept = Dictionary(
                headerRows.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.worth) }
                    .filter { !$0.0.isEmpty },
                uniquingKeysWith: { _, last in last })
            config.headers = kept.isEmpty ? nil : kept
        }
        do {
            try hub.add(config)
            // A field cleared is the sign it was taken; the words said under
            // it before are gone with it.
            name = ""; command = ""; arguments = ""; address = ""; headerRows = []
            trouble = nil
        } catch {
            trouble = error.localizedDescription
        }
    }
}

/// The Skills side of Settings › AI: the person's own instruction files,
/// one folder apiece in the skills folder (see Skills), on until they're
/// switched off. Nothing is written here — the words are the person's own,
/// made by hand or dropped in.
private struct SkillsShelf: View {
    var drawn = false
    @State private var found: [Skills.Listed] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                if found.isEmpty {
                    Nothing("No skills yet — a folder in the skills folder, holding a SKILL.md with its name and description between --- lines at the top, and its words below")
                } else {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, skill in
                        if index > 0 { Rule() }
                        Line(skill.name, skill.description.isEmpty ? "One of your own files" : skill.description) {
                            if drawn {
                                AISettings.Stand(Skills.enabled(skill.id) ? "On" : "Off")
                            } else {
                                Switch(on: Binding(get: { Skills.enabled(skill.id) },
                                                   set: { Skills.setEnabled(skill.id, $0) }))
                            }
                        }
                    }
                }
            }
            Card {
                Line("The folder", Skills.folder.path) {
                    Quick("Show") {
                        // Made if it isn't there yet, so there's something to
                        // show; opened for the person, never from a test.
                        try? FileManager.default.createDirectory(at: Skills.folder, withIntermediateDirectories: true)
                        if !Store.testing { NSWorkspace.shared.open(Skills.folder) }
                    }
                }
            }
        }
        .onAppear { found = Skills.discover() }
    }
}

/// The bot's tasks for a time to come (see Chores): the goal in its own
/// words, when it comes, and what came of it — taken off here, watched
/// here, missed here.
private struct ChoresList: View {
    var drawn = false
    @ObservedObject private var chores = Chores.shared

    /// A task's state, as a person reads it.
    private func spoken(_ task: Chores.Chore) -> String {
        switch task.state {
        case .waiting:
            if task.lastState == .human {
                return "waiting for its next round — its last round needed you: \(task.words ?? "")"
            }
            return task.every != nil ? "waiting for its next round" : "waiting"
        case .running: return "running now"
        case .done: return "done — \(task.words ?? "")"
        case .human: return "needs you — \(task.words ?? "")"
        case .failed: return "didn't come to it — \(task.words ?? "")"
        case .missed: return "missed — \(task.words ?? "")"
        case .interrupted: return "interrupted — \(task.words ?? "")"
        }
    }

    /// A task's time, as a person reads it: for one that comes round
    /// again, the gap and the next time it comes.
    private func timing(_ task: Chores.Chore) -> String {
        if let every = task.every {
            return "every \(Chores.gap(every)) · next \(Chores.spoken(task.at))"
        }
        return Chores.spoken(task.at)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                if chores.tasks.isEmpty {
                    Nothing("No tasks for later yet — ask the bot over a page for something at a time to come (\"tomorrow at eight, sign me up\", or \"every ten minutes, pull the feed\"), and it notes the goal in its own words and does it when the time comes")
                } else {
                    ForEach(Array(chores.tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Rule() }
                        Line(task.goal, "\(timing(task)) · \(spoken(task)) · \(task.page)") {
                            if drawn {
                                AISettings.Stand(task.state == .waiting ? "Waiting" : spoken(task))
                            } else {
                                Pill("Remove") { chores.remove(task.id) }
                            }
                        }
                    }
                }
            }
            Card {
                Line("When the time comes", "The page is opened again and the bot works it, Auto on, while Search is running — a time that passes with Search closed is missed, not run, and says so here. A task asked for as one that comes round again (\"every ten minutes\") comes round until it's taken off: each round's answer is kept with it, a round that finds Search closed is skipped, not piled up, and one that goes wrong tries again at its next time") { EmptyView() }
            }
        }
    }
}
