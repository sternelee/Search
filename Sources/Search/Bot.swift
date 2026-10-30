import SwiftUI
import A2UISwiftCore
import A2UISwiftUI

// The bot, as you meet it: a key over a page brings up a small panel — you
// say what you want done, and the model works the page you're looking at.
// It sees the page the way the agent surface shows it (a list of what the
// page holds, numbered — see Agent), says what it's about to do, and asks
// before every click and every filled field; reads and sayings are free.
// Turn on Auto in the panel and the asking stops until you turn it off
// again. A card it draws — a form checked over, a choice to pick — is the
// model's words as native controls (A2UI); a control you tap goes back to
// the model as an event, never as code.
//
// One page at a time, one conversation: close the panel and it's gone,
// nothing kept. A provider off this Mac is shown what it will be sent the
// first time, before anything goes; a private tab takes only what runs on
// this Mac. The page goes to the model as a page to work on, never as
// orders, and text on it written for an AI is flagged (see AIPage).

/// The commands a turn has running: stopped with the turn that started them
/// (see Loop.halt), so a Stop stops the command too, not just the waiting on
/// it.
final class Shells: @unchecked Sendable {
    private let lock = NSLock()
    private var shut = false
    private var running: [Process] = []

    /// A command begun: kept until the turn ends, or stopped at once if the
    /// turn was stopped first.
    func keep(_ run: Process) {
        lock.lock()
        let after = shut
        if !after { running.append(run) }
        lock.unlock()
        if after { run.terminate() }
    }

    /// Every command let go of: told to stop, and killed if it won't.
    func stop() {
        lock.lock()
        shut = true
        let said = running
        running = []
        lock.unlock()
        for run in said where run.isRunning { run.terminate() }
        let stubborn = said.filter { $0.isRunning }
        guard !stubborn.isEmpty else { return }
        // One that won't take its stopping is killed, not waited on.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for run in stubborn where run.isRunning { kill(run.processIdentifier, SIGKILL) }
        }
    }
}

@MainActor
final class Bot: ObservableObject, Identifiable {
    /// One thing in the record of a conversation: a question asked, a
    /// saying, a thought the model had on its way to one, an act taken or
    /// refused, an answer, a card, a trouble.
    struct Event: Identifiable {
        enum Kind { case ask, say, think, act, answer, human, card, trouble }
        let id: UUID
        let kind: Kind
        let words: String
        var act: Act?

        init(id: UUID = UUID(), kind: Kind, words: String, act: Act?) {
            self.id = id
            self.kind = kind
            self.words = words
            self.act = act
        }
    }

    /// An act on the page: what was done, where, and how it came out.
    struct Act: Identifiable, Equatable {
        let id = UUID()
        let verb: String
        let target: String
        let text: String
        var outcome: String?
        /// What the act said: a tool's reply, a command's print — shown
        /// whole under the line of the act (see BotEventView), so what the
        /// model was shown is read by the person too.
        var said: String?
    }

    /// An act waiting on you: nothing has touched the page yet. The tab
    /// it was held on — the one the line came for — so that, let go, it
    /// goes to that tab, whatever tab the browser is on now.
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let act: Act
        var tab: Tab.ID?
    }

    /// The talk, set down while its panel is away: what the panel showed
    /// and what the model was told, taken up again when the panel comes
    /// back to the same page (see Browser.openBot).
    struct Held {
        let provider: AIProvider
        let model: String
        let events: [Event]
        let messages: [AIMessage]
    }

    let id = UUID()
    let tab: Tab.ID
    let provider: AIProvider
    let model: String
    /// A bot that is a tab of its own — the Agent Chat tab (see
    /// ChatTab.swift): no page under it, every tab its reach, and the page
    /// in front its page of the moment.
    let chat: Bool
    /// Where it works: this page, or every tab (see Mode). The switch on
    /// the panel can turn it on the talk it's already carrying on.
    @Published private(set) var mode: Mode
    /// The page it works on, held weakly: the tab outliving the bot means
    /// nothing.
    private(set) weak var page: Tab?

    @Published private(set) var events: [Event] = []
    /// Held for the person to allow or refuse (the loop waits on it).
    @Published var pending: Pending?
    @Published private(set) var working = false
    @Published private(set) var notice: String?
    @Published private(set) var trouble: String?
    /// What the loop is doing while it works, in place of the plain
    /// "working…" when there's more to say (the loop sets it: its other half).
    @Published fileprivate(set) var status: String?
    /// The page has words addressed to an AI (see AIPage.addressesAI).
    @Published private(set) var addressed = false
    /// Asked for, the asking stops: acts go ahead on their own.
    @Published var auto = false
    /// An Always on a held act: the page's own acts go ahead from here, but
    /// nothing beyond the page does — that still asks (see Loop.route).
    /// Auto, the switch on the panel, is the whole asking stopped.
    @Published private(set) var alwaysPage = false
    /// A run with no one at the keys — a task come due (see Chores): the
    /// page is worked as ever, but nothing beyond the page goes, for there
    /// is no hand there to allow it.
    var unattended = false
    @Published var draft = ""
    /// How hard the model thinks before it speaks (see BotThinking). Read
    /// by the loop when it asks the model; the person changes it in Settings.
    var thinking: BotThinking = .off
    /// The most tool calls one turn makes before it wraps up. Read by the
    /// loop in place of Bot.steps; the person changes it in Settings.
    var steps: Int = Bot.steps
    /// Told when a turn is over — an answer, a card, a trouble, or the panel
    /// closed on it — with the trouble's words, or nothing. The scheduled
    /// run listens (see Chores); nothing else does.
    var onOver: ((String?) -> Void)?
    /// The cards it has drawn, in the order they came — each answered by
    /// the ask that follows it, and gone.
    @Published private(set) var surfaces: [SurfaceViewModel] = []

    /// The loop working one ask (fileprivate: the loop is its other half).
    fileprivate var loop: Loop?
    /// The talk so far, kept between asks while the panel is open.
    fileprivate var messages: [AIMessage] = []
    private var waiting: String?
    private var cards: [String: SurfaceViewModel] = [:]

    init(tab: Tab, provider: AIProvider, model: String, mode: Mode = .page) {
        self.tab = tab.id
        self.page = tab
        self.chat = false
        self.mode = mode
        self.provider = provider
        self.model = model
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            self.addressed = (await AIPage.read(tab))?.addressed ?? false
        }
    }

    /// The Agent Chat tab's own bot: no page under it, every tab its reach.
    init(chat tab: Tab, provider: AIProvider, model: String) {
        self.tab = tab.id
        self.page = nil
        self.chat = true
        self.mode = .every
        self.provider = provider
        self.model = model
    }

    var busy: Bool { working || pending != nil }

    /// Where it works: one page, or every one of them — which shapes what
    /// the model is shown (see Loop) and what the person meets (BotPanel).
    enum Mode: String {
        case page
        case every
    }

    /// Where it ran, for the foot of the panel.
    var place: String {
        let where_ = mode == .every ? "over every tab" : "on this page"
        let runs: String
        if provider == .thisMac {
            runs = "on this Mac · \(model)"
        } else if provider.isLocal {
            runs = "on this Mac · \(provider.name) · \(model)"
        } else {
            runs = "sent to \(provider.name) · \(model)"
        }
        return "\(where_) · \(runs)"
    }

    func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, notice == nil else { return }
        // The person's own hand at the keys: whatever ran unattended here
        // before (a task come due, working its round) has someone to ask
        // from now on.
        unattended = false
        draft = ""
        ask(question, shown: question)
    }

    /// A question or a tap, in the model's own words, to be worked.
    private func ask(_ words: String, shown: String?) {
        if let shown { events.append(Event(kind: .ask, words: shown, act: nil)) }
        if !provider.isLocal, !Store.settings.bool(forKey: "ai.told.\(provider.rawValue)") {
            waiting = words
            notice = AIAssist.notice(for: provider)
            return
        }
        send(words)
    }

    /// The notice read and agreed to: what was asked goes.
    func agree() {
        Store.settings.set(true, forKey: "ai.told.\(provider.rawValue)")
        notice = nil
        if let waiting { send(waiting) }
        waiting = nil
    }

    private func send(_ words: String) {
        // The chat tab has no page under it — its asks go all the same.
        guard page != nil || chat else { return }
        // A live turn let go for a new ask: whoever was listening on its
        // end (a scheduled run, see Chores) is told it was taken back.
        if loop != nil { onOver?("the person took the panel back") }
        // A card is answered by the ask that starts this turn: it has
        // served, and goes. (The model can end one sooner with a delete.)
        cards.removeAll()
        surfaces.removeAll()
        working = true
        trouble = nil
        // The chat tab's loop carries no page of its own (see Loop.observe:
        // the page in front stands in, when one is).
        loop = Loop(bot: self, page: page, question: words, messages: messages)
        loop?.start()
    }

    /// A tap on a control in one of its cards: back to the model as an
    /// event, with what the card holds.
    func tapped(_ action: ResolvedAction) {
        guard !busy, notice == nil else { return }
        var context: [String: Any] = [:]
        for (key, value) in action.context { context[key] = value.description }
        let line: [String: Any] = ["tap": ["name": action.name, "context": context]]
        let words = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"tap\":{\"name\":\"\(action.name)\"}}"
        ask(words, shown: "tapped \(action.name)")
    }

    /// An act held for you (see pending): let it go, or not.
    func resolve(_ allowed: Bool) {
        loop?.resume(allowed)
    }

    /// Allowed, and asked not to be asked again — for the page's own acts:
    /// what goes beyond the page (a command, the clipboard, a tool, the
    /// person's history, a task for a time to come) still asks, Auto aside.
    func always() {
        alwaysPage = true
        resolve(true)
    }

    /// The switch on the panel turned: the talk it's carrying on goes on,
    /// and from here it is for this page only, or for every tab.
    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    /// The talk so far, set down for keeping — the panel's half and the
    /// model's, so the same page can take it up again (see Held).
    func hold() -> Held {
        Held(provider: provider, model: model, events: events, messages: messages)
    }

    /// A talk taken up again: the panel shows what was said, and the
    /// model is told what it was told — it goes on where it left off.
    func takeUp(_ held: Held) {
        events = held.events
        messages = held.messages
    }

    /// The talk, wiped: the panel emptied, the model's share of it gone,
    /// a working turn stopped where it stands — the next ask starts from
    /// nothing. The copy held for the page went with it (see
    /// Browser.clearBot).
    func clear() {
        if working { onOver?("the talk was cleared") }
        loop?.halt()
        loop = nil
        working = false
        pending = nil
        status = nil
        drafting = nil
        musing = nil
        events.removeAll()
        messages.removeAll()
        surfaces.removeAll()
        cards.removeAll()
        waiting = nil
        trouble = nil
        notice = nil
        auto = false
        alwaysPage = false
    }

    /// Stop everything, quietly: the panel closing, a new ask coming.
    func stop() {
        // A turn still working was closed on: whoever listened on its end
        // (a scheduled run, see Chores) is told it came to nothing.
        if working { onOver?("the bot was closed on it") }
        // An act still waiting was let go: told so, rather than vanishing
        // with the turn (see Loop.halt).
        if pending != nil { trouble = "The act was let go, unanswered — stopped." }
        loop?.halt()
        loop = nil
        working = false
        pending = nil
        status = nil
        drafting = nil
        musing = nil
    }

    /// The turn is over — an answer, or nothing more to try.
    fileprivate func over(_ failed: String?) {
        working = false
        loop = nil
        pending = nil
        status = nil
        drafting = nil
        musing = nil
        if let failed { trouble = failed }
        onOver?(failed)
    }

    /// A trouble told of a turn already over — stopped mid-request, and the
    /// request failed under it: said on the panel, and nothing restarted.
    fileprivate func fault(_ words: String) {
        trouble = words
    }

    fileprivate func tell(_ event: Event) {
        events.append(event)
    }

    // MARK: - the reply coming in

    /// The reply as it comes: plain words shown as they're said, a saying
    /// on the panel grown piece by piece (see Loop.think). Kept on the bot,
    /// not the loop, so the saying stands even when the turn is stopped
    /// mid-word.
    @Published fileprivate(set) var drafting: (id: UUID, words: String)?

    /// A saying begun: its id, steady while it grows (the panel holds one
    /// view for it, its words redrawn as they come).
    fileprivate func beginDraft() -> UUID {
        let id = UUID()
        drafting = (id, "")
        return id
    }

    /// The saying grown: the words it's come to.
    fileprivate func grow(_ id: UUID, _ words: String) {
        drafting = (id, words)
    }

    /// The reply's all in: the saying that grew goes — what it stood as is
    /// told by `carry` (plain words stand, a JSON line becomes what it is).
    fileprivate func finishDraft() {
        drafting = nil
    }

    // MARK: - the thinking coming in

    /// The model's thinking as it comes: shown muted while it's thought, in
    /// the record never — the messages the model reads back hold only what
    /// was asked and answered, where thoughts held in would be answered
    /// again (see Loop.think). When it's done it stands in the record as a
    /// thought of its own (see `thought`).
    @Published fileprivate(set) var musing: (id: UUID, words: String)?

    /// A thinking begun: its id, steady while it grows. Begun for every
    /// reply — a model that never thinks never grows it past empty.
    fileprivate func beginMusing() -> UUID {
        let id = UUID()
        musing = (id, "")
        return id
    }

    /// The thinking grown: the words it's come to, capped as everything the
    /// panel holds is (see Bot.pageful).
    fileprivate func growMusing(_ id: UUID, _ words: String) {
        musing = (id, words)
    }

    /// The thinking done: what it came to stands in the record as one
    /// thought of the model's — muted, over what it was on its way to (see
    /// BotEventView) — and the thinking itself goes. Nothing thought — a
    /// model that doesn't think, or one stopped before it said a thing —
    /// leaves nothing.
    fileprivate func thought(_ id: UUID, _ words: String) {
        guard musing?.id == id else { return }
        musing = nil
        var words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.count > Bot.pageful { words = String(words.prefix(Bot.pageful)) + "…" }
        if !words.isEmpty { tell(Event(kind: .think, words: words, act: nil)) }
    }

    /// The model's ui payload, drawn: decoded as A2UI messages, checked
    /// against the catalog, rendered as native controls. Nothing in it can
    /// run; a card is a picture with controls, not code.
    func draw(_ list: [[String: Any]]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: list)
            let messages = try JSONDecoder().decode([A2uiMessage].self, from: data)
            for message in messages {
                let id = surface(message)
                if case .deleteSurface = message {
                    _ = cards[id]?.processMessages([message])
                    cards[id] = nil
                    surfaces.removeAll { $0.surface.id == id }
                    continue
                }
                if cards[id] == nil {
                    // A surface it updates without having made it: made now,
                    // from the plain catalog, with its data sent on taps.
                    cards[id] = SurfaceViewModel(surface: SurfaceModel(id: id, catalog: basicCatalog, sendDataModel: true))
                    surfaces.append(cards[id]!)
                    tell(Event(kind: .card, words: id, act: nil))
                }
                let errors = cards[id]?.processMessages([message]) ?? []
                if let first = errors.first {
                    tell(Event(kind: .trouble, words: "A card it drew didn't take: \(first.localizedDescription)", act: nil))
                }
            }
        } catch {
            tell(Event(kind: .trouble, words: "A card it drew didn't parse: \(error.localizedDescription)", act: nil))
        }
    }

    private func surface(_ message: A2uiMessage) -> String {
        switch message {
        case .createSurface(let payload): return payload.surfaceId
        case .updateComponents(let payload): return payload.surfaceId
        case .updateDataModel(let payload): return payload.surfaceId
        case .deleteSurface(let payload): return payload.surfaceId
        }
    }

    static let steps = 12
    /// More of the page than this is a page the model shouldn't be shown
    /// whole: it can ask for the rest.
    nonisolated static let pageful = 6000

    /// How much of a table's rows or a list's items one read comes back as:
    /// enough of a table to work from, and not more than a reply carries.
    /// What doesn't fit is said — how many rows were left — so a read that
    /// came back short is known to be short, not taken for the whole.
    nonisolated static let readful = 3000
    /// Longer than any one reply needs.
    nonisolated static let longest = 8000

    // MARK: - what it remembers

    /// A thought kept for every talk to come, with when it was kept.
    struct Thought: Codable {
        let words: String
        let at: Date
    }

    /// What the bot keeps of the person, from one talk to the next: a
    /// hundred thoughts at most, the oldest let go when a new one comes
    /// in, kept in the app's own settings. Told to every bot from the
    /// start (see `remembered`); a "note" in a reply is held for the
    /// person's Allow before anything is kept.
    private static let kept = "bot.notes"

    static func notes() -> [Thought] {
        guard let held = Store.settings.string(forKey: kept),
              let data = held.data(using: .utf8),
              let read = try? JSONDecoder().decode([Thought].self, from: data) else { return [] }
        return read
    }

    static func keep(_ words: String) {
        var all = notes()
        all.append(Thought(words: String(words.prefix(500)), at: Date()))
        if all.count > 100 { all = Array(all.suffix(100)) }
        if let data = try? JSONEncoder().encode(all) {
            Store.settings.set(String(data: data, encoding: .utf8), forKey: kept)
        }
    }

    static func forget() { Store.settings.removeObject(forKey: kept) }

    /// The kept thoughts, as the model is told them: with every ask, from
    /// the start, whatever page the talk is on — the last twenty, newest
    /// last.
    static var remembered: String {
        let all = notes()
        guard !all.isEmpty else { return "" }
        return "\n\nWhat you remember about the person, kept from talks before:\n"
            + all.suffix(20).map { "- \($0.words) (kept \(day.string(from: $0.at)))" }
                .joined(separator: "\n")
    }

    /// A kept thought's when, as a person reads it.
    static let day: DateFormatter = {
        let made = DateFormatter()
        made.dateStyle = .short
        made.timeStyle = .short
        return made
    }()

    /// A command's minute: longer than that, it's stopped (see `shell`).
    nonisolated static let runFor: TimeInterval = 60

    /// A command run for the bot: zsh, in the person's home, given its
    /// minute. What it printed — said out loud and gone wrong together —
    /// comes back capped like any long reply is (see pageful). A command
    /// that never ends is stopped, and what it had printed is what there
    /// is. (The process is waited on away from the app's own thread; a
    /// child it leaves holding the pipe is waited out, not hung on.)
    nonisolated static func shell(_ command: String, kept: (Process) -> Void = { _ in }) -> (said: String, code: Int32, timedOut: Bool) {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/zsh")
        run.arguments = ["-c", command]
        run.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let spoken = Pipe(), goneWrong = Pipe()
        run.standardOutput = spoken
        run.standardError = goneWrong
        do { try run.run() } catch { return ("couldn't start: \(error.localizedDescription)", -1, false) }
        kept(run)
        var said = Data(), heard = Data()
        let both = DispatchGroup()
        both.enter()
        DispatchQueue.global().async { said = spoken.fileHandleForReading.readDataToEndOfFile(); both.leave() }
        both.enter()
        DispatchQueue.global().async { heard = goneWrong.fileHandleForReading.readDataToEndOfFile(); both.leave() }
        let deadline = Date().addingTimeInterval(runFor)
        var timedOut = false
        while both.wait(timeout: .now() + 0.1) == .timedOut, !timedOut {
            if Date() > deadline {
                timedOut = true
                run.terminate()
            }
        }
        // A child still holding the pipe: its sayings are let go of, not
        // waited on. And a command that won't take its stopping is killed,
        // not waited on forever.
        _ = both.wait(timeout: .now() + 2)
        if timedOut, run.isRunning { kill(run.processIdentifier, SIGKILL) }
        run.waitUntilExit()
        var text = String(decoding: said + heard, as: UTF8.self)
        if text.count > Bot.pageful { text = String(text.prefix(Bot.pageful)) + "…" }
        return (text, run.terminationStatus, timedOut)
    }

    /// The talk's shape: what the model is told before anything.
    static let system = """
        You are the bot inside a web browser, working for the person who summoned you.\
        You see one page at a time, as a numbered list of what it holds: each line is a kind\
        (like textbox, button, link, heading), its name in quotes if it has one, its state\
        (checked, disabled…), and a number (@12). You act on things by those numbers.\
        Where you see TABS — every tab the browser holds, each with its id (like tab-a1b2c3) —\
        an act, a read, a goto or a wait can carry a "tab" with one of those ids, and the page\
        shown after TABS is the one the browser is on now. What you're shown of a tab isn't\
        all there is: the whole of it can be asked for (full), and read closely.

        Every reply you make is ONE line of JSON, nothing else — no markdown, no fence.\
        One of:

        {"say": "…"}  — tell the person what you're doing, then carry on
        {"act": {"verb": "…", "target": "…", "text": "…"}}  — work the page
        {"read": "target"}  — read one thing closely (its text, value or address; a table as its rows, a list as its items)
        {"console": 30}  — the page's own story: its console, its errors, its network — the last 30 lines, what went badly said plainly
        {"ui": [ … ]}  — draw a card: a form, a choice, a picture of what you found.\
        A card ends your turn: the person answers it with a tap, and the card goes
        {"goto": "https://…"}  — go to an address: an act on the page the person is shown,\
        so it waits for their Allow like an act, Auto aside
        {"wait": "target"}  — wait for something to be on the page
        {"full": true}  — you were shown only what's in view; ask for the whole page
        {"answer": "…"}  — the task is done (or can't be done); the person reads this
        {"human": "…"}  — what's left is only a person's to do (a password, a code from \
        another place, a payment, a puzzle only a person can read): say so, and your turn \
        ends there, the words shown to the person plainly — never pretend it was done, and \
        never spend steps on what only a person can do. Not for what's merely hard: a \
        thing you can't find is not a person's to do; keep looking until you run out of steps
        {"later": {"goal": "…", "at": "…", "every": 600}}  — note a task for a time to come, the goal your own\nsumming up of what's to be done, at as ISO 8601 (like 2026-10-15T08:00:00+08:00).\nEach page comes with NOW, the time it is — turn "tomorrow at eight" into a time\nto come, in the person's own timezone given with it. For a task that comes round\nagain ("every ten minutes"), give every as the gap in seconds (a minute at least)\nand at as the first time to come — at can be left out, and the first time is one\ngap from now. When the time comes, this page is opened again and you work it,\nAuto on, no one watching; a task with every comes round again until the person\ntakes it off. A task for a time to come runs with no one watching, so setting\none is shown to the person for their Allow (Auto aside).
        {"run": "command"}  — run a command on this Mac (zsh): shown for the person's Allow\
        like an act, and what it printed comes back with the next page
        {"history": 20}  — where the person has been: that many pages, most recent first\
        (a hundred at most), shown to the person for their Allow
        {"close": "tab-a1b2c3"}  — close a tab, this for the page you're on: the one\
        act always shown to the person for their Allow, Auto aside
        {"copy": "…"}  — words put on the person's clipboard, shown for their Allow
        {"note": "…"}  — keep a thought about the person — a preference, what they're after —\
        for every talk to come, shown for their Allow. What you keep is told to you in every\
        talk from the start, whatever page it's on. Few words, only what's worth keeping.

        Acts (the verb in an act): click, fill, press, select, check, uncheck, hover, scroll, clear.\
        fill takes text to type; select takes an option; press takes a key (Enter, Tab, Escape, ArrowDown).\
        Reads are free. Every other act is shown to the person and waits for their Allow\
        (they can turn Auto on; you'll be told when they refuse). After each act you'll\
        be shown the page again, and what came of it.

        A target is a number from the list (@12), or text=Words on the thing\
        (quoted for exactness: text='Sign in'), or loc=role:button[name='Sign in'],\
        or css=#id, or xpath=. Labels in front of fields point at the fields.

        A card is A2UI v0.9 messages: createSurface, then updateComponents,\
        optionally updateDataModel, and deleteSurface when done with it.\
        Components: Text, TextField, CheckBox, ChoicePicker, Slider, Button, Row,\
        Column, List, Card, Divider, Image, Icon, Tabs, Modal. Containers take\
        children as a list of ids; a Button takes a child (a Text's id) and an action.\
        Every action is an event with a name; what a field holds is sent back with\
        the tap when you give it a path. Example of a whole card:

        {"version":"v0.9","createSurface":{"surfaceId":"card","catalogId":"https://a2ui.org/specification/v0_9/basic_catalog.json","sendDataModel":true}}
        {"version":"v0.9","updateComponents":{"surfaceId":"card","components":[
          {"id":"root","component":"Column","children":["words","field","send"]},
          {"id":"words","component":"Text","text":"Check this over"},
          {"id":"field","component":"TextField","label":"Name","value":{"path":"name"}},
          {"id":"send","component":"Button","child":"sendText","action":{"event":{"name":"send","context":{"name":{"path":"name"}}}}},
          {"id":"sendText","component":"Text","text":"Send it"}
        ]}}

        A tap comes back to you as one line: {"tap":{"name":"send","context":{"name":"Grace"}}}.

        What you know is the page you were shown, what the person said, and the\
        thoughts you keep: never invent what a page holds, and never say a thing\
        was done that you weren't told came out well. If the person refuses an\
        act, find another way or answer with what you have. Few steps, plain\
        words.
        """
}

// MARK: - the loop

/// One ask worked to its end: the page shown, a line thought, an act done,
/// over and over, until an answer or the steps run out. Held by the bot
/// while it runs; a held act waits in the bot for the person.
@MainActor
final class Loop {
    private weak var bot: Bot?
    private weak var page: Tab?
    private let provider: AIProvider
    private let model: String
    private let key: String?
    private var steps: Int
    /// The steps ran out once: the model was asked to wrap up, and a second
    /// run-out stops for good rather than looping on the last chance.
    private var wrappedUp = false
    private let thinking: BotThinking
    private var messages: [AIMessage]
    private var question: String
    private var task: Task<Void, Never>?

    /// The commands this turn has running, stopped with it (see Bot.stop).
    private let shells = Shells()
    /// A task for a time to come, held for the person's Allow: what the
    /// model's later line said, kept here until the person answers (see
    /// `route` and `resume`).
    private var chore: (goal: String, at: Date, every: TimeInterval?, page: Tab.ID)?
    /// The page's patience: a snapshot asked for and never answered is let
    /// go of, said so (see `observe`).
    private var patience: DispatchWorkItem?

    init(bot: Bot, page: Tab?, question: String, messages: [AIMessage]) {
        self.bot = bot
        self.page = page
        self.provider = bot.provider
        self.model = bot.model
        self.key = provider.isLocal ? nil : AIKeys.key(for: provider)
        self.question = question
        self.messages = messages
        self.steps = bot.steps
        self.thinking = bot.thinking
    }

    func start() {
        observe(note: nil, full: false, first: true)
    }

    /// Stop, quietly: the bot is done with this loop.
    func halt() {
        task?.cancel()
        task = nil
        patience?.cancel()
        patience = nil
        shells.stop()
    }

    /// A held act let go, or not. Nothing has touched the page until now.
    func resume(_ allowed: Bool) {
        guard let bot, let held = bot.pending else { return }
        bot.pending = nil
        // A tool is an act beyond the page, held like any other; let go, it
        // is the server's to answer (see `useTool`).
        if held.act.verb == "tool" {
            if allowed {
                useTool(held.act.target, arguments: held.act.text)
            } else {
                var refused = held.act
                refused.outcome = "refused"
                bot.tell(Bot.Event(kind: .act, words: "", act: refused))
                observe(note: "The person refused your tool \(held.act.target).", full: false, first: false)
            }
            return
        }
        // A task for a time to come, held for the person (see `route`): let
        // go, it is kept — it will run with no one watching, so the setting
        // of it was theirs to agree to; turned away, said so.
        if held.act.verb == "later" {
            if allowed, let task = chore,
               let work = TabsOfBrowser.all.first(where: { $0.id == task.page }) ?? bot.page {
                setChore(task.goal, at: task.at, every: task.every, on: work)
            } else if !allowed {
                turnedAway(held, why: "The person wouldn't have it set. Find another way, or answer with what you have.")
            } else {
                // Allowed, but the page it was set over is gone: said so,
                // rather than the talk standing still on nothing.
                observe(note: "The page that task was set over is gone — there is nothing to keep it for. Ask the person, or answer with what you have.", full: false, first: false)
            }
            chore = nil
            return
        }
        // A tab closed at the model's asking: let go, it closes — the one
        // act that asks even under Auto, for a tab is the person's own.
        if held.act.verb == "close" {
            if allowed { closeTab(held) }
            else { turnedAway(held, why: "The person kept the tab. Find another way, or answer with what you have.") }
            return
        }
        // Where the person has been, held for their Allow like any read
        // that goes beyond the page.
        if held.act.verb == "history" {
            if allowed { showHistory(Int(held.act.text) ?? 20) }
            else { turnedAway(held, why: "The person wouldn't have their history read. Answer without it.") }
            return
        }
        // A command run on this Mac, words to the person's clipboard, a
        // thought kept for talks to come (see `route`): let go, they go;
        // turned away, said so.
        if held.act.verb == "run" {
            if allowed { runShell(held.act.text) }
            else { turnedAway(held, why: "The person wouldn't have it run. Find another way.") }
            return
        }
        if held.act.verb == "copy" {
            if allowed { copyOut(held.act.text) }
            else { turnedAway(held, why: "The person wouldn't have it copied. Find another way.") }
            return
        }
        if held.act.verb == "note" {
            if allowed { keepNote(held.act.text) }
            else { turnedAway(held, why: "The person wouldn't have it kept. Carry on.") }
            return
        }
        // A page gone to, held for the person like any act on the page:
        // it changes what they're shown, so it's theirs to allow — let
        // go, the page goes (see `route`).
        if held.act.verb == "goto" {
            let workTab = (held.tab.flatMap { id in TabsOfBrowser.all.first { $0.id == id } })
                ?? bot.page
            if allowed {
                guard let workTab else {
                    var gone = held.act
                    gone.outcome = "the tab is gone"
                    bot.tell(Bot.Event(kind: .act, words: "", act: gone))
                    observe(note: "The tab that act was for is gone — the tabs are listed for you with their ids (TABS). Say it again with one of those.", full: false, first: false)
                    return
                }
                if let url = URL(string: held.act.target),
                   let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    workTab.go(to: url)
                    observe(note: "You went to \(held.act.target).", full: false, first: false)
                } else {
                    var gone = held.act
                    gone.outcome = "didn't work: the address wouldn't be read"
                    bot.tell(Bot.Event(kind: .act, words: "", act: gone))
                    observe(note: "That address wouldn't be read. Say it again.", full: false, first: false)
                }
            } else {
                var refused = held.act
                refused.outcome = "refused"
                bot.tell(Bot.Event(kind: .act, words: "", act: refused))
                observe(note: "The person refused your goto on \(held.act.target).", full: false, first: false)
            }
            return
        }
        // A page act goes to the tab it was held on — the one the line came
        // for — or, when it came for none, the one the panel was open on.
        // The chat tab's beyond-page acts came for no tab at all, and need
        // none: only here is one asked for.
        let workTab = (held.tab.flatMap { id in TabsOfBrowser.all.first { $0.id == id } })
            ?? bot.page
        if allowed {
            guard let workTab else {
                var gone = held.act
                gone.outcome = "the tab is gone"
                bot.tell(Bot.Event(kind: .act, words: "", act: gone))
                observe(note: "The tab that act was for is gone — the tabs are listed for you with their ids (TABS). Say it again with one of those.", full: false, first: false)
                return
            }
            perform(held.act.verb, held.act.target, held.act.text, on: workTab)
        } else {
            var refused = held.act
            refused.outcome = "refused"
            bot.tell(Bot.Event(kind: .act, words: "", act: refused))
            observe(note: "The person refused your \(held.act.verb) on \(held.act.target).", full: false, first: false)
        }
    }

    /// A held act turned away: told as one, and the talk goes on. (The
    /// page's own acts have their own words for it, in `resume`.)
    private func turnedAway(_ held: Bot.Pending, why: String) {
        var refused = held.act
        refused.outcome = "refused"
        bot?.tell(Bot.Event(kind: .act, words: "", act: refused))
        observe(note: why, full: false, first: false)
    }

    /// The page shown to the model: what it holds, numbered, and what came
    /// of the last thing done. The first showing carries the question.
    /// The time it is, told with every page (ISO 8601, the person's own
    /// timezone): what "tomorrow at eight" is worked out from.
    static let clock: ISO8601DateFormatter = {
        let made = ISO8601DateFormatter()
        made.timeZone = .current
        return made
    }()

    private func observe(note: String?, full: Bool, first: Bool) {
        guard let bot else { return }
        // The page worked: the bot's own, or — for the chat tab, which has
        // no page under it — whichever page is in front, if one is.
        let work = bot.chat ? TabsOfBrowser.active : page
        bot.status = work == nil ? "looking at the tabs…" : "looking at the page…"
        guard let work else {
            // Nothing in front to work: the tabs alone, said so plainly —
            // every act from here names its tab.
            var seen = ""
            if first { seen += self.question + "\n\n" }
            if let note { seen += note + "\n\n" }
            if bot.mode == .every { seen += "TABS\n\(TabsOfBrowser.line())\n\n" }
            seen += "NOW \(Self.clock.string(from: Date()))\n"
            seen += "No page is in front — every act, read, goto or wait carries its tab.\n"
            self.messages.append(AIMessage(role: .user, text: seen))
            self.think()
            return
        }
        // A page that never answers: said so, rather than waiting on it
        // forever with a bare "working…" for company.
        var dead = false
        let tired = DispatchWorkItem { [weak self] in
            guard let self, let bot = self.bot else { return }
            dead = true
            bot.over("The page never answered the bot — say it again, or try another page.")
        }
        patience = tired
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: tired)
        Agent.ask(work, ["op": "snapshot", "full": full]) { [weak self] said in
            tired.cancel()
            guard !dead, let self, let bot = self.bot else { return }
            if let error = said["error"] as? String {
                bot.over("The page wouldn't show itself: \(error)")
                return
            }
            var seen = ""
            if first { seen += self.question + "\n\n" }
            if let note { seen += note + "\n\n" }
            // Every tab it may work on, first — then the page the browser is
            // on now, worked like any other (see Mode).
            if bot.mode == .every { seen += "TABS\n\(TabsOfBrowser.line())\n\n" }
            // Where it is, what it's called: what a person reads before the
            // page itself, and what a model needs to know an address by.
            seen += "NOW \(Self.clock.string(from: Date()))\n"
            seen += "PAGE \(work.address?.absoluteString ?? "")\nTITLE \(work.title)\n\n"
            var tree = said["tree"] as? String ?? ""
            if tree.count > Bot.pageful {
                tree = String(tree.prefix(Bot.pageful)) + "\n… the page holds more; ask for the whole of it"
            }
            seen += tree
            self.messages.append(AIMessage(role: .user, text: seen))
            self.think()
        }
    }

    private func think() {
        guard let bot else { return }
        guard steps > 0 else {
            guard !wrappedUp else {
                // The wrap-up chance was already given and the model didn't
                // answer: stopped for good, the person told so they can carry
                // on with their own words.
                bot.tell(Bot.Event(kind: .trouble, words: "The task ran out of steps — say more of what you want and it can carry on.", act: nil))
                bot.over(nil)
                return
            }
            wrappedUp = true
            // The steps are done: one more ask, so the model can wrap up with
            // an answer rather than the talk just stopping mid-work.
            bot.tell(Bot.Event(kind: .say, words: "wrapping up…", act: nil))
            observe(note: "You've used your steps. Give your answer now — what you found, what you did, or what's left undone — in one reply, and stop.", full: false, first: false)
            return
        }
        steps -= 1
        bot.status = "asking \(provider.name)…"
        // Tools and skills of the person's, when there are any, ride along
        // with the same words every time (see AIDescribed).
        let system = Bot.system + Bot.remembered + AIDescribed.forTheBot()
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: system, messages: messages)
            : AIClient.shared.stream(provider, model: model, system: system, messages: messages, key: key, thinking: thinking)
        var whole = ""
        // The reply coming in, shown as it comes: plain words as they're
        // said, and the words a JSON line holds while it's still arriving.
        // The saying the panel holds is begun here and grown piece by
        // piece (see Bot.grow).
        let draft = bot.beginDraft()
        var thought = ""
        // A thinking model's thoughts, shown as they come too — muted, over
        // the saying when one follows — and never kept in the messages the
        // model reads back (see Bot.musing). Begun like the saying: a model
        // that never thinks never grows it past empty.
        let muse = bot.beginMusing()
        task = Task { @MainActor [self] in
            do {
                for try await piece in stream {
                    // A thought is not the reply: it grows its own saying,
                    // muted, apart from the reply the model is read back
                    // (see AIPiece).
                    if piece.kind == .thought {
                        thought += piece.words
                        var grown = thought
                        if grown.count > Bot.pageful { grown = String(grown.prefix(Bot.pageful)) + "…" }
                        bot.growMusing(muse, grown)
                    } else {
                        whole += piece.words
                        // The words said as they come: plain words plainly, and
                        // the say or answer inside a JSON line while the line is
                        // still arriving — the rest of the line waits for the
                        // whole of it (see Loop.wordsComing). Not every piece holds
                        // a piece: a line can be thinking, or empty.
                        var grown = Loop.wordsStanding(in: whole) ?? ""
                        if !piece.words.isEmpty, !grown.isEmpty {
                            if grown.count > Bot.pageful { grown = String(grown.prefix(Bot.pageful)) + "…" }
                            bot.grow(draft, grown)
                        }
                    }
                    // A model talked into going on and on is stopped —
                    // thinking on and on, too.
                    if whole.count > Bot.longest || thought.count > Bot.longest { break }
                }
                // Stopped by the person: the request came to nothing on
                // purpose (the stream ends quietly on a cancel), and the
                // words it had come to are carried nowhere (see Bot.stop).
                if Task.isCancelled { return }
                bot.finishDraft()
                bot.thought(muse, thought)
                self.carry(whole)
            } catch {
                // Stopped by the person (see Bot.stop and BotPanel's stop):
                // the turn is already over on the panel, and the request
                // coming to nothing is no trouble to report.
                if Task.isCancelled {
                    // Stopped on purpose — but an error under the stopping
                    // is still told: a broken request is no quieter for it.
                    if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                        self.bot?.fault("Stopped, with an error under it: \(error.localizedDescription)")
                    }
                    return
                }
                self.bot?.finishDraft()
                self.bot?.thought(muse, thought)
                self.failed(error.localizedDescription)
            }
        }
    }

    /// One line of JSON back, or it isn't: said so, and shown the page again.
    /// A model that talks around its answer is still heard — the JSON alone
    /// or wrapped in words or a fence is taken (see `shape`).
    private func carry(_ reply: String) {
        guard let bot else { return }
        guard let object = Self.shape(reply) else {
            // The model's words are shown even when they're not the protocol:
            // a person watching sees what it said, never silence (a model
            // spoken to in words answers in words — "hi" — before it finds
            // the protocol again).
            var words = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if words.count > Bot.pageful { words = String(words.prefix(Bot.pageful)) + "…" }
            if !words.isEmpty { bot.tell(Bot.Event(kind: .say, words: words, act: nil)) }
            bot.status = "asking again — the last reply wasn't in shape"
            observe(note: "Your last reply wasn't JSON with say, act, read, ui, goto, wait, full, answer, later, run, history, copy, note, tool or skill — one object, alone or wrapped in words. Try again.", full: false, first: false)
            return
        }
        bot.status = nil
        messages.append(AIMessage(role: .assistant, text: reply.trimmingCharacters(in: .whitespacesAndNewlines)))
        route(object)
    }

    /// The reply's JSON: the whole of it, one line of it, or the braces it
    /// holds — the first that parses as an object with something to do.
    private static func shape(_ reply: String) -> [String: Any]? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model that fences its one line: the fence comes off.
        if text.hasPrefix("```") {
            text = text
                .drop(while: { $0 != "\n" }).dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        let object = { (cut: String) -> [String: Any]? in
            guard let data = cut.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        if let whole = object(text) { return whole }
        let known: Set<String> = ["say", "act", "read", "console", "ui", "goto", "wait", "full", "answer", "human", "later", "run", "history", "copy", "note", "tab", "tool", "skill"]
        for line in text.split(separator: "\n").map(String.init) {
            if let one = object(line), !known.isDisjoint(with: one.keys) { return one }
        }
        if let open = text.firstIndex(of: "{"), let shut = text.lastIndex(of: "}"), open < shut,
           let held = object(String(text[open...shut])), !known.isDisjoint(with: held.keys) {
            return held
        }
        return nil
    }

    /// The words a reply is standing on while it's still coming: what the
    /// person is being shown this moment, whatever shape the reply is in.
    /// A JSON line says it in its say or its answer (see wordsComing); a
    /// model that wraps its line in a fence — as models do, whatever the
    /// prompt says — says it inside the fence, and the fence and the
    /// language word over it are not words to read; a reply in plain words
    /// says it plainly. Nothing yet is nothing.
    static func wordsStanding(in reply: String) -> String? {
        let head = reply.drop(while: { " \n\t\r".contains($0) })
        for fence in ["```", "~~~"] where head.hasPrefix(fence) {
            var body = head.dropFirst(fence.count)
            // The fence's own line holds the language and nothing else: it
            // goes by, and until it has, there is nothing yet to show.
            guard let lineEnd = body.firstIndex(of: "\n") else { return "" }
            body = body[body.index(after: lineEnd)...]
            // A fence not yet closed — the reply is still coming — keeps
            // the words it has come to.
            if let shut = body.range(of: fence) { body = body[..<shut.lowerBound] }
            let inside = body.drop(while: { " \n\t\r".contains($0) })
            if inside.first == "{" { return wordsComing(in: String(body)) ?? "" }
            return String(body)
        }
        if head.first == "{" { return wordsComing(in: reply) ?? "" }
        return String(head)
    }

    /// The words a reply holds for the person, taken while it's still
    /// coming: the value of its say or its answer, read plainly —
    /// half-made JSON isn't parsed, the string inside it is simply taken
    /// as it stands (\n as a line, \" as a quote). No such field, or a
    /// value not yet begun, is nothing.
    private static func wordsComing(in reply: String) -> String? {
        guard let open = reply.firstIndex(of: "{") else { return nil }
        let body = reply[open...]
        for key in ["say", "answer"] {
            guard let spot = body.range(of: "\"\(key)\"") else { continue }
            // the colon, then the quote the value opens with
            let rest = body[spot.upperBound...].drop(while: { " \n\t:".contains($0) })
            guard rest.first == "\"" else { return "" }
            var out = ""
            var escape = false
            for char in rest.dropFirst() {
                if escape {
                    switch char {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    default: out.append(char)
                    }
                    escape = false
                } else if char == "\\" {
                    escape = true
                } else if char == "\"" {
                    break
                } else {
                    out.append(char)
                }
            }
            return out
        }
        return nil
    }

    /// What the line asked for, in the order the person meets it: said,
    /// drawn, answered; gone, waited for, acted on.
    private func route(_ line: [String: Any]) {
        // The chat tab's loop carries no page; what a line without a tab of
        // its own means is settled just below.
        guard let bot else { return }
        // A line for one tab of many (see Tabs): taken out, and what it held
        // — a verb, an address, a target — goes to what follows, on that tab.
        // What a line without a tab of its own means: the bot's own page,
        // or — for the chat tab — the page in front, if one is. Lines that
        // need no page (a saying, an answer, a card) never ask for it; the
        // ones that do say so when there is none.
        var line = line
        let onTab: Tab?
        if let held = line.removeValue(forKey: "tab") as? String {
            guard let found = TabsOfBrowser.byID(held) else {
                observe(note: "There's no tab called \(held) — the tabs are listed for you with their ids (TABS). Say it again with one of those.", full: false, first: false)
                return
            }
            onTab = found
        } else {
            onTab = bot.chat ? TabsOfBrowser.active : page
        }
        let work = onTab
        if let say = line["say"] as? String, !say.isEmpty {
            bot.tell(Bot.Event(kind: .say, words: say, act: nil))
        }
        if let ui = line["ui"] {
            switch ui {
            case let list as [[String: Any]]: bot.draw(list)
            case let one as [String: Any]: bot.draw([one])
            default: break
            }
        }
        // A card is an answer the person answers: drawn, the turn is over,
        // until a tap or a question comes back.
        if line["ui"] != nil {
            bot.messages = messages
            bot.over(nil)
            return
        }
        if let answer = line["answer"] as? String, !answer.isEmpty {
            bot.tell(Bot.Event(kind: .answer, words: answer, act: nil))
            bot.messages = messages
            bot.over(nil)
            return
        }
        // What's left is only a person's to do — said, and the turn ends
        // there, nothing touched. It needs no Allow: it touches nothing,
        // and it's the one honest way out of a task no one is watching
        // (a task come due — see Chores) that runs into a password, a
        // code from another place, a payment.
        if let human = line["human"] as? String, !human.isEmpty {
            bot.tell(Bot.Event(kind: .human, words: human, act: nil))
            bot.messages = messages
            bot.over(nil)
            return
        }
        // A task for a time to come, set: the goal noted in the model's own
        // words, kept with the page and the time (see Chores) — the turn is
        // over, and the time will bring it back to work the page again. One
        // that comes round again carries the gap between rounds (every, in
        // seconds): a time already come, or none given with one, starts a
        // gap from now.
        if let later = line["later"] as? [String: Any],
           let goal = later["goal"] as? String, !goal.isEmpty,
           (later["at"] as? String)?.isEmpty == false || later["every"] != nil {
            let every: TimeInterval? = (later["every"] as? Double) ?? (later["every"] as? Int).map(Double.init)
            if let every, every < Chores.roundLeast {
                observe(note: "That gap between rounds is too small — a task that comes round again needs a minute or more between them. Say the task again, with a gap of at least a minute.", full: false, first: false)
                return
            }
            var at = (later["at"] as? String).flatMap(Chores.read)
            if (at == nil || at! <= Date()), let every { at = Date().addingTimeInterval(every) }
            if let at, at > Date() {
                // A task set is a task that will run with no one watching,
                // so the setting of it is the person's to agree to — and
                // with no one at the keys at all (a task come due, working
                // its own round), never: one task cannot beget another in
                // the small hours.
                if bot.unattended {
                    observe(note: "No one is at the keys to allow a task for a time to come — this run works its page and answers. Ask the person when they're back.", full: false, first: false)
                    return
                }
                if bot.auto {
                    if let work { setChore(goal, at: at, every: every, on: work) }
                } else if let work {
                    chore = (goal, at, every, work.id)
                    bot.pending = Bot.Pending(
                        act: Bot.Act(verb: "later",
                                     target: "at \(Chores.spoken(at))\(every.map { ", every \(Chores.gap($0))" } ?? "")",
                                     text: goal),
                        tab: work.id
                    )
                }
            } else {
                observe(note: "That time couldn't be read, or it has already come — NOW it is \(Self.clock.string(from: Date())). Say the task again, with a time to come, ISO 8601.", full: false, first: false)
            }
            return
        }
        if let address = line["goto"] as? String,
           let url = URL(string: address),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard let work else {
                observe(note: "No page is in front to go anywhere — the tabs are listed for you with their ids (TABS); say it again with a tab.", full: false, first: false)
                return
            }
            // Going to an address is an act on the page the person is
            // shown — it changes what they see — so it waits for their
            // Allow like any act, Auto aside and an Always over it.
            if bot.auto || bot.alwaysPage {
                work.go(to: url)
                observe(note: "You went to \(address).", full: false, first: false)
            } else {
                bot.pending = Bot.Pending(
                    act: Bot.Act(verb: "goto", target: address, text: ""),
                    tab: work.id
                )
            }
            return
        }
        if let target = line["wait"] as? String {
            guard let work else {
                observe(note: "No page is in front to wait on — the tabs are listed for you with their ids (TABS); say it again with a tab.", full: false, first: false)
                return
            }
            Agent.poll(work, until: Date().addingTimeInterval(15), ["op": "present", "target": target]) { [self] said in
                guard self.bot != nil else { return }
                let came = said["ok"] as? Bool == true
                self.observe(note: "You waited for \(target) and it \(came ? "came" : "never came").", full: false, first: false)
            }
            return
        }
        if line["full"] as? Bool == true {
            observe(note: nil, full: true, first: false)
            return
        }
        // A tool of the person's called — an act beyond the page, so it
        // waits for the person's Allow like any act (Auto lets it go; no
        // one at the keys allows nothing).
        if let tool = line["tool"] as? [String: Any],
           let name = tool["name"] as? String, !name.isEmpty {
            let arguments = tool["arguments"] as? [String: Any] ?? [:]
            let held = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            if bot.unattended {
                observe(note: "No one is at the keys to allow a tool of the person's — this task works its page only. Answer with what you have.", full: false, first: false)
            } else if bot.auto {
                useTool(name, arguments: held)
            } else {
                bot.pending = Bot.Pending(act: Bot.Act(verb: "tool", target: name, text: held), tab: work?.id)
            }
            return
        }
        if let skill = line["skill"] as? String, !skill.isEmpty {
            readSkill(skill)
            return
        }
        // Beyond the page: a command run on this Mac, words to the
        // clipboard, a thought kept for talks to come — none of them touch
        // the page, and all three are shown to the person and wait for
        // their Allow like any act (Auto lets them go; no one at the keys
        // allows nothing beyond the page at all). Where the person has been
        // is a read, but a read of the person's own going-about, and so it
        // is shown for their Allow too.
        if let command = line["run"] as? String, !command.isEmpty {
            if bot.unattended {
                observe(note: "No one is at the keys to allow a command on this Mac — this task works its page only. Answer with what you have.", full: false, first: false)
            } else if bot.auto { runShell(command) }
            else { bot.pending = Bot.Pending(act: Bot.Act(verb: "run", target: "", text: command), tab: work?.id) }
            return
        }
        if let words = line["copy"] as? String, !words.isEmpty {
            if bot.unattended {
                observe(note: "No one is at the keys to allow words on the clipboard — this task works its page only. Answer with what you have.", full: false, first: false)
            } else if bot.auto { copyOut(words) }
            else { bot.pending = Bot.Pending(act: Bot.Act(verb: "copy", target: "", text: words), tab: work?.id) }
            return
        }
        if let thought = line["note"] as? String, !thought.isEmpty {
            if bot.unattended {
                observe(note: "No one is at the keys to allow a thought kept about the person — this task works its page only. Answer with what you have.", full: false, first: false)
            } else if bot.auto { keepNote(thought) }
            else { bot.pending = Bot.Pending(act: Bot.Act(verb: "note", target: "", text: thought), tab: work?.id) }
            return
        }
        if let count = (line["history"] as? Int) ?? (line["history"] as? Double).map(Int.init) {
            if bot.unattended {
                observe(note: "No one is at the keys to allow the person's history being read — this task works its page only. Answer with what you have.", full: false, first: false)
            } else if bot.auto { showHistory(count) }
            else { bot.pending = Bot.Pending(act: Bot.Act(verb: "history", target: "", text: String(max(1, count))), tab: work?.id) }
            return
        }
        // A tab closed at the model's asking — the one act that asks even
        // under Auto, for a tab is the person's own to close. A run with no
        // one at the keys may put its own page away, and no other.
        if let close = line["close"] as? String, !close.isEmpty {
            let target = close == "this" ? work : TabsOfBrowser.byID(close)
            guard let target else {
                observe(note: "There's no tab called \(close) — the tabs are listed for you with their ids (TABS). Say it again with one of those, or this.", full: false, first: false)
                return
            }
            if bot.unattended {
                guard target.id == bot.tab else {
                    observe(note: "No one is at the keys to allow closing the person's tabs — this task may close its own page only.", full: false, first: false)
                    return
                }
                closeTab(Bot.Pending(act: Bot.Act(verb: "close", target: "this tab", text: target.title), tab: target.id))
                return
            }
            bot.pending = Bot.Pending(
                act: Bot.Act(verb: "close", target: close == "this" ? "this tab" : close, text: target.title),
                tab: target.id
            )
            return
        }
        if let read = line["read"] as? String, !read.isEmpty {
            guard let work else {
                observe(note: "No page is in front to read from — the tabs are listed for you with their ids (TABS); say it again with a tab.", full: false, first: false)
                return
            }
            perform("read", read, "", on: work)
            return
        }
        if line["console"] != nil {
            guard let work else {
                observe(note: "No page is in front to listen to — the tabs are listed for you with their ids (TABS); say it again with a tab.", full: false, first: false)
                return
            }
            // The page's own story is a read of it, not an act on it: no
            // Allow waits on what the page merely said of itself.
            let count = line["console"] as? Int ?? 30
            Agent.ask(work, ["op": "console", "count": count]) { [weak self] said in
                guard let self, let bot = self.bot else { return }
                var act = Bot.Act(verb: "console", target: "the page", text: "")
                act.outcome = "read"
                bot.tell(Bot.Event(kind: .act, words: "", act: act))
                self.observe(
                    note: (said["error"] as? String).map { "Listening to the page didn't work: \($0)." }
                        ?? "The page said of itself, the last \(count) lines:\n\(said["text"] ?? "")",
                    full: false, first: false)
            }
            return
        }
        if let act = line["act"] as? [String: Any],
           let verb = act["verb"] as? String, !verb.isEmpty,
           let target = act["target"] as? String, !target.isEmpty {
            let text = act["text"] as? String ?? ""
            // A "tab" inside the act goes to the same place one on its own
            // goes: the act is for that tab, whatever tab the browser is on
            // now — and a tab that isn't one is said so, nothing done.
            let forTab: Tab
            if let held = act["tab"] as? String, !held.isEmpty {
                guard let found = TabsOfBrowser.byID(held) else {
                    observe(note: "There's no tab called \(held) — the tabs are listed for you with their ids (TABS). Say it again with one of those.", full: false, first: false)
                    return
                }
                forTab = found
            } else if let work {
                forTab = work
            } else {
                observe(note: "No page is in front and none was named — the tabs are listed for you with their ids (TABS). Say it again with one of those.", full: false, first: false)
                return
            }
            if verb == "read" || bot.auto || bot.alwaysPage {
                perform(verb, target, text, on: forTab)
            } else {
                bot.pending = Bot.Pending(act: Bot.Act(verb: verb, target: target, text: text), tab: forTab.id)
            }
            return
        }
        // A saying on its own carries on; anything else, said so.
        if line["say"] != nil {
            observe(note: nil, full: false, first: false)
            return
        }
        observe(note: "That reply had nothing to do — say, act, read, ui, goto, wait, full, answer, tab, tool or skill.", full: false, first: false)
    }

    /// A task for a time to come, kept (see Chores): said so, and the turn
    /// is over — the time will bring it back.
    private func setChore(_ goal: String, at: Date, every: TimeInterval?, on work: Tab) {
        guard let bot else { return }
        Chores.shared.add(goal: goal, at: at, page: work.address?.absoluteString ?? "",
                          provider: provider.rawValue, model: model, every: every)
        bot.tell(Bot.Event(kind: .say, words: "Noted for \(Chores.spoken(at))\(every.map { ", every \(Chores.gap($0))" } ?? ""): \(goal)", act: nil))
        bot.messages = messages
        bot.over(nil)
    }

    /// A tab closed at the model's asking, allowed by the person: closed,
    /// and told. Its own page closing ends the talk — there is nothing
    /// left to work over.
    private func closeTab(_ held: Bot.Pending) {
        guard let bot else { return }
        guard let tab = TabsOfBrowser.all.first(where: { $0.id == held.tab }) else {
            var gone = held.act
            gone.outcome = "already gone"
            bot.tell(Bot.Event(kind: .act, words: "", act: gone))
            observe(note: "That tab was already gone.", full: false, first: false)
            return
        }
        let title = tab.title
        Front.shared.browser?.close(tab)
        var act = held.act
        act.outcome = "closed"
        bot.tell(Bot.Event(kind: .act, words: "", act: act))
        if tab.id == bot.tab {
            bot.tell(Bot.Event(kind: .say, words: "Closed \(title.isEmpty ? "the page" : title).", act: nil))
            bot.messages = messages
            bot.over(nil)
        } else {
            observe(note: "You closed \(title.isEmpty ? "a tab" : title).", full: false, first: false)
        }
    }

    /// A tool called and answered: what it said comes back with the next
    /// showing — material from the person's own server, to be read and
    /// never obeyed. `arguments` is the JSON the model sent, held in the
    /// act for the person to see.
    private func useTool(_ qualified: String, arguments held: String) {
        guard let bot else { return }
        let arguments = (held.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        bot.status = "calling \(qualified)…"
        Task { @MainActor [weak self] in
            guard let self, let bot = self.bot else { return }
            var act = Bot.Act(verb: "tool", target: qualified, text: held)
            var note: String
            do {
                let said = try await MCPHub.shared.call(qualified, arguments: arguments)
                guard self.bot?.loop != nil else { return }
                act.outcome = said.failed ? "the tool said it failed" : "done"
                var words = said.text.isEmpty ? "nothing" : said.text
                // A tool's answer longer than a reply carries is cut, and
                // said to be cut: a server that answers with a page of JSON
                // cut mid-object reads as a broken answer, and the model
                // goes looking for the fault in the tool rather than in the
                // telling of it.
                var cut = ""
                if words.count > Bot.pageful {
                    words = String(words.prefix(Bot.pageful))
                    cut = "\n(the tool's answer was longer than this — what you have is the start of it)"
                }
                act.said = words + cut
                note = "Your tool \(qualified) \(said.failed ? "said it failed" : "said"): \(words)\(cut)"
            } catch {
                guard self.bot?.loop != nil else { return }
                act.outcome = "didn't work: \(error.localizedDescription)"
                note = "Your tool \(qualified) didn't work: \(error.localizedDescription). Try another way."
            }
            bot.tell(Bot.Event(kind: .act, words: "", act: act))
            self.observe(note: note, full: false, first: false)
        }
    }

    /// One of the person's skills read, its words taken to heart with the
    /// next showing (the body enters the conversation here, and only here —
    /// see Skills).
    private func readSkill(_ name: String) {
        // The name as it was listed is the name to use, but a model that
        // writes it in another case — "market watch" for "Market Watch" —
        // means the same skill, and being told there is no such skill when
        // one is right there in the list it was given wastes the turn. An
        // exact name wins; a name that differs only in case is taken too.
        let kept = Skills.listed()
        let met = kept.first(where: { $0.name == name })
            ?? kept.first(where: { $0.name.lowercased() == name.lowercased() })
        guard let met, let body = Skills.body(met.id) else {
            observe(note: "There's no skill called \(name) — the ones the person keeps are listed for you. Try another way.", full: false, first: false)
            return
        }
        var words = body
        var cut = ""
        if words.count > Bot.pageful {
            words = String(words.prefix(Bot.pageful))
            cut = "\n(this skill is longer than this — what you have is the start of it)"
        }
        observe(note: "The skill \(met.name), the person's own words:\n\n\(words)\(cut)", full: false, first: false)
    }

    /// A command run on this Mac (see Bot.shell): what it printed goes
    /// back with the next showing, told plainly — the command, and what
    /// came of it, so the model can't claim a thing it wasn't shown.
    private func runShell(_ command: String) {
        guard let bot else { return }
        bot.status = "running it…"
        Task { @MainActor [weak self] in
            guard let self, let bot = self.bot else { return }
            let shells = self.shells
            let run = await withCheckedContinuation { carry in
                DispatchQueue.global(qos: .userInitiated).async {
                    carry.resume(returning: Bot.shell(command, kept: shells.keep))
                }
            }
            // Stopped while it ran: the command was stopped with the turn,
            // and nothing of what it printed is told (see Bot.stop).
            guard self.bot?.loop != nil else { return }
            var act = Bot.Act(verb: "run", target: "", text: command)
            var note: String
            var printed = "$ \(command)\n\(run.said.isEmpty ? "nothing" : run.said)"
            if printed.count > Bot.pageful { printed = String(printed.prefix(Bot.pageful)) + "…" }
            act.said = printed
            if run.timedOut {
                act.outcome = "stopped at a minute"
                note = "Your command was stopped at a minute — what it had printed:\n\(printed)"
            } else if run.code != 0 {
                act.outcome = "ran, and finished with \(run.code)"
                note = "Your command ran and finished with \(run.code) — what it printed:\n\(printed)"
            } else {
                act.outcome = "ran"
                note = "Your command ran — what it printed:\n\(printed)"
            }
            bot.tell(Bot.Event(kind: .act, words: "", act: act))
            self.observe(note: note, full: false, first: false)
        }
    }

    /// Words put on the person's clipboard — the plainest way a summary
    /// is shared out of the browser.
    private func copyOut(_ words: String) {
        guard let bot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words, forType: .string)
        var act = Bot.Act(verb: "copy", target: "", text: words)
        act.outcome = "copied"
        bot.tell(Bot.Event(kind: .act, words: "", act: act))
        observe(note: "You copied it — the words are on the person's clipboard.", full: false, first: false)
    }

    /// A thought kept for every talk to come (see Bot.notes): kept, and
    /// told so.
    private func keepNote(_ words: String) {
        guard let bot else { return }
        Bot.keep(words)
        var act = Bot.Act(verb: "note", target: "", text: words)
        act.outcome = "kept"
        bot.tell(Bot.Event(kind: .act, words: "", act: act))
        observe(note: "You kept it — it's told to you in every talk from the start, whatever page you're on.", full: false, first: false)
    }

    /// Where the person has been, as the model reads it: the history the
    /// address field draws on (see History), most recent first, a hundred
    /// pages at most. Only read — the model never goes there without the
    /// person seeing an act for it. The space on screen's own, since each
    /// profile keeps its history (see Profiles.history).
    private func showHistory(_ count: Int) {
        let wanted = min(max(count, 1), 100)
        let pages = Profiles.history(Spaces.profile(of: Spaces.current)).everything().prefix(wanted)
        var block = pages
            .map { "· \($0.address) · \($0.title.isEmpty ? "no title" : $0.title) (\($0.count) time\($0.count == 1 ? "" : "s"), last \(Bot.day.string(from: $0.last)))" }
            .joined(separator: "\n")
        if block.count > Bot.pageful { block = String(block.prefix(Bot.pageful)) + "…" }
        observe(note: "Where the person has been, the last \(pages.count) pages, most recent first:\n\(block)", full: false, first: false)
    }

    /// An act done on the page, and told: what came of it goes back with the
    /// next showing.
    private func perform(_ verb: String, _ target: String, _ text: String, on work: Tab) {
        // Reading isn't an act on the page: it's the page asked for one
        // thing closely (see Agent.page).
        var op: [String: Any] = verb == "read"
            ? ["op": "read", "target": target]
            : ["op": "act", "verb": verb, "target": target]
        if !text.isEmpty { op["text"] = text }
        Agent.ask(work, op) { [weak self] said in
            guard let self, let bot = self.bot else { return }
            var act = Bot.Act(verb: verb, target: target, text: text)
            if verb == "read" {
                if let error = said["error"] as? String {
                    act.outcome = "didn't work: \(error)"
                    bot.tell(Bot.Event(kind: .act, words: "", act: act))
                    self.observe(note: "Reading \(target) didn't work: \(error).", full: false, first: false)
                    return
                }
                if let rows = said["rows"] as? [[String]] {
                    let count = said["count"] as? Int ?? rows.count
                    let held = said["more"] as? Int ?? 0
                    // The table's own names come with it: a row of cells
                    // with no header over them is a row of cells to guess
                    // at, and the header is the page's own words for them.
                    let head = said["header"] as? [String] ?? []
                    var lines: [String] = []
                    if !head.isEmpty { lines.append(head.joined(separator: " | ")) }
                    var spent = lines.first?.count ?? 0
                    for row in rows {
                        let line = row.joined(separator: " | ")
                        if spent + line.count + 1 > Bot.readful, !lines.isEmpty { break }
                        lines.append(line)
                        spent += line.count + 1
                    }
                    let shown = lines.count - (head.isEmpty ? 0 : 1)
                    let left = count - shown + held
                    act.outcome = "read"
                    bot.tell(Bot.Event(kind: .act, words: "", act: act))
                    self.observe(note: "You read \(target): a table of \(count) rows"
                        + (held > 0 ? " (\(held) not shown)" : "")
                        + (head.isEmpty ? "" : ", header \(head.joined(separator: ", "))")
                        + ". " + lines.joined(separator: "; ")
                        + (left > 0 ? " (\(left) rows not shown)" : ""),
                        full: false, first: false)
                    return
                }
                if let items = said["items"] as? [String] {
                    let count = said["count"] as? Int ?? items.count
                    let held = said["more"] as? Int ?? 0
                    var lines: [String] = []
                    var spent = 0
                    for item in items {
                        if spent + item.count + 1 > Bot.readful, !lines.isEmpty { break }
                        lines.append(item)
                        spent += item.count + 1
                    }
                    let left = count - lines.count + held
                    act.outcome = "read"
                    bot.tell(Bot.Event(kind: .act, words: "", act: act))
                    self.observe(note: "You read \(target): a list of \(count) items"
                        + (held > 0 ? " (\(held) not shown)" : "")
                        + ". " + lines.joined(separator: " · ")
                        + (left > 0 ? " (\(left) items not shown)" : ""),
                        full: false, first: false)
                    return
                }
                let value = (said["value"] ?? said["text"]).flatMap { $0 as? String } ?? "nothing"
                act.outcome = "read"
                bot.tell(Bot.Event(kind: .act, words: "", act: act))
                self.observe(note: "You read \(target): \(String(value.prefix(1500)))", full: false, first: false)
                return
            }
            if let error = said["error"] as? String {
                act.outcome = "didn't work: \(error)"
            } else {
                act.outcome = "done"
            }
            bot.tell(Bot.Event(kind: .act, words: "", act: act))
            self.observe(note: "Your \(verb) on \(target) came out \(act.outcome ?? "").", full: false, first: false)
        }
    }

    private func failed(_ words: String) {
        bot?.over(words)
    }
}

// MARK: - the tabs it may work on

/// Every tab the browser holds, as one line for a model: the id of each,
/// its address, its title — what the bot over every tab is shown with every
/// page, and what a "tab" in its replies is taken by (see Bot.Mode).
@MainActor
enum TabsOfBrowser {
    /// Every tab of the browser the bot is open on — the one whose window
    /// is in front when there are more than one — but never the bench's
    /// own pages (those belong to the scripts and agent CLIs that opened
    /// them, and their content is not the person's to have worked over)
    /// and never a chat tab, which is no page to be worked. (A test run's
    /// pages are the bench's own, and are the bot's to work: the tests
    /// would have nothing else. See Agent.seek for the same exemption.)
    static var all: [Tab] {
        Front.shared.browser?.tabs.filter { (Store.testing || !$0.bench) && !$0.chat } ?? []
    }

    /// The page the browser is on now, whose snapshot rides with the tabs —
    /// never a chat tab: when the person is talking, the page of the moment
    /// is none.
    static var active: Tab? { Front.shared.browser?.active.flatMap { $0.chat ? nil : $0 } }

    /// One tab by its id, the short way it's listed (tab-a1b2c3… — the
    /// last of the uuid), or the one the browser is on now when the id says
    /// only "this".
    static func byID(_ id: String) -> Tab? {
        if id == "this" { return active }
        return all.first { "tab-\($0.id.uuidString.suffix(6))" == id }
    }

    /// The tabs, as one line for a model: "tab-a1b2c3 · https://… · A title",
    /// the one the browser is on now marked.
    static func line() -> String {
        let shown = Front.shared.browser?.activeID
        return all.map { tab in
            let mark = tab.id == shown ? " (the page you're shown)" : ""
            return "tab-\(tab.id.uuidString.suffix(6)) · \(tab.address?.absoluteString ?? "") · \(tab.title)\(mark)"
        }
        .joined(separator: "\n")
    }
}

// MARK: - opening it

extension Browser {
    /// Where the bot works: this page, or every tab. The switch is kept, so
    /// a bot asked for again comes back where it was left (see BotPanel) —
    /// and a bot already open follows it right away: the switch is drawn
    /// again the moment it's turned (a plain setting wouldn't be), and the
    /// talk goes on under the other mode.
    var botEverywhere: Bool {
        get { Store.settings.bool(forKey: "bot.every") }
        set {
            Store.settings.set(newValue, forKey: "bot.every")
            objectWillChange.send()
            botting?.setMode(newValue ? .every : .page)
        }
    }

    /// The panel asked for. A talk this page was having — held while its
    /// panel was away — is taken up again, so it goes on where it left
    /// off (a scheduled task starts from nothing each time it comes
    /// round: takeUp false, see Chores). A task come due names the page
    /// it works (over:), for its page is not the one in front.
    func openBot(over given: Tab? = nil, takeUp held: Bool = true) {
        guard let tab = given ?? active, !tab.isBlank else { return }
        guard prefs.bot, let provider = prefs.aiProvider else {
            settingsPage = .ai
            tuning = true
            announce(prefs.bot ? "Choose where the bot's AI runs" : "Turn on the bot in Settings › AI")
            return
        }
        // A web page, nothing else: not a file, not a setting.
        guard let scheme = tab.pageAddress?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            announce("The bot works on web pages")
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
        // The local apps name no model of their own: the one chosen in
        // Settings, and the stand-in needs none at all.
        let model = prefs.aiModel(for: provider)
        guard !model.isEmpty || provider.isLocal else {
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
        // Already open over every tab, or on this one: the same talk goes on.
        if let open = botting, open.provider == provider,
           open.mode == (botEverywhere ? .every : .page), open.tab == tab.id { return }
        // The talk the open panel was having, set down for its own page:
        // a panel over another page takes its place, and that page's talk
        // waits for it.
        if let open = botting { setDown(open) }
        botting?.stop()
        // The tools and skills the person keeps are offered to the bot as
        // it comes in: the servers connected in the background, so their
        // tools are there to list by the time a task is asked (see
        // AIDescribed).
        MCPHub.shared.wake()
        // The talk this page was having, set down when its panel went:
        // taken up again — the words the panel showed, and the words the
        // model was told, with the AI it was talking to.
        var talk: Bot.Held?
        if held { talk = botEverywhere ? heldEvery : heldTalks[tab.id] }
        let bot = Bot(tab: tab, provider: talk?.provider ?? provider, model: talk?.model ?? model,
                      mode: botEverywhere ? .every : .page)
        bot.thinking = prefs.botThinking
        bot.steps = prefs.botSteps
        if let talk { bot.takeUp(talk) }
        botting = bot
    }

    func closeBot(hold: Bool = true) {
        if hold, let bot = botting { setDown(bot) }
        botting?.stop()
        botting = nil
    }

    /// The talk, set down for the page it was on: the same page takes it
    /// up again when a panel comes back over it (see openBot, closeBot).
    /// A talk that said nothing holds nothing.
    private func setDown(_ bot: Bot) {
        guard !bot.events.isEmpty else { return }
        if bot.mode == .every { heldEvery = bot.hold() } else { heldTalks[bot.tab] = bot.hold() }
    }

    /// The bot's talk, cleared: the panel emptied, the model's share of
    /// it gone, the held copy dropped — the next ask starts from
    /// nothing, on this panel or the next one over the same page — and
    /// what was kept of the person let go with it.
    func clearBot() {
        guard let bot = botting else { return }
        bot.clear()
        Bot.forget()
        if bot.mode == .every { heldEvery = nil } else { heldTalks[bot.tab] = nil }
    }
}
