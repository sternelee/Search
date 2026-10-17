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

@MainActor
final class Bot: ObservableObject, Identifiable {
    /// One thing in the record of a conversation: a question asked, a
    /// saying, an act taken or refused, an answer, a card, a trouble.
    struct Event: Identifiable {
        enum Kind { case ask, say, act, answer, card, trouble }
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
    @Published var draft = ""
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
        self.mode = mode
        self.provider = provider
        self.model = model
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            self.addressed = (await AIPage.read(tab))?.addressed ?? false
        }
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
        guard let page else { return }
        // A live turn let go for a new ask: whoever was listening on its
        // end (a scheduled run, see Chores) is told it was taken back.
        if loop != nil { onOver?("the person took the panel back") }
        // A card is answered by the ask that starts this turn: it has
        // served, and goes. (The model can end one sooner with a delete.)
        cards.removeAll()
        surfaces.removeAll()
        working = true
        trouble = nil
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

    /// Allowed, and asked not to be asked again: from here every act in
    /// this conversation goes ahead on its own (see auto).
    func always() {
        auto = true
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
        events.removeAll()
        messages.removeAll()
        surfaces.removeAll()
        cards.removeAll()
        waiting = nil
        trouble = nil
        notice = nil
        auto = false
    }

    /// Stop everything, quietly: the panel closing, a new ask coming.
    func stop() {
        // A turn still working was closed on: whoever listened on its end
        // (a scheduled run, see Chores) is told it came to nothing.
        if working { onOver?("the bot was closed on it") }
        loop?.halt()
        loop = nil
        working = false
        pending = nil
        status = nil
        drafting = nil
    }

    /// The turn is over — an answer, or nothing more to try.
    fileprivate func over(_ failed: String?) {
        working = false
        loop = nil
        pending = nil
        status = nil
        drafting = nil
        if let failed { trouble = failed }
        onOver?(failed)
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
    static let pageful = 6000
    /// Longer than any one reply needs.
    static let longest = 8000

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
        {"read": "target"}  — read one thing closely (its text, value or address)
        {"ui": [ … ]}  — draw a card: a form, a choice, a picture of what you found.\
        A card ends your turn: the person answers it with a tap, and the card goes
        {"goto": "https://…"}  — go to an address
        {"wait": "target"}  — wait for something to be on the page
        {"full": true}  — you were shown only what's in view; ask for the whole page
        {"answer": "…"}  — the task is done (or can't be done); the person reads this
        {"later": {"goal": "…", "at": "…", "every": 600}}  — note a task for a time to come, the goal your own\nsumming up of what's to be done, at as ISO 8601 (like 2026-10-15T08:00:00+08:00).\nEach page comes with NOW, the time it is — turn "tomorrow at eight" into a time\nto come, in the person's own timezone given with it. For a task that comes round\nagain ("every ten minutes"), give every as the gap in seconds (a minute at least)\nand at as the first time to come — at can be left out, and the first time is one\ngap from now. When the time comes, this page is opened again and you work it,\nAuto on, no one watching; a task with every comes round again until the person\ntakes it off.

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

        What you know is the page you were shown and what the person said:\
        never invent what a page holds, and never say a thing was done that you\
        weren't told came out well. If the person refuses an act, find another\
        way or answer with what you have. Few steps, plain words.
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
    private var steps = Bot.steps
    private var messages: [AIMessage]
    private var question: String
    private var task: Task<Void, Never>?
    /// The page's patience: a snapshot asked for and never answered is let
    /// go of, said so (see `observe`).
    private var patience: DispatchWorkItem?

    init(bot: Bot, page: Tab, question: String, messages: [AIMessage]) {
        self.bot = bot
        self.page = page
        self.provider = bot.provider
        self.model = bot.model
        self.key = provider.isLocal ? nil : AIKeys.key(for: provider)
        self.question = question
        self.messages = messages
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
    }

    /// A held act let go, or not. Nothing has touched the page until now.
    func resume(_ allowed: Bool) {
        guard let bot, let held = bot.pending else { return }
        // A held act goes to the tab it was held on — the one the line came
        // for — or, when it came for none, the one the panel was open on:
        // whatever tab the browser is on now.
        let workTab = (held.tab.flatMap { id in TabsOfBrowser.all.first { $0.id == id } })
            ?? bot.page
        guard let workTab else { return }
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
        if allowed {
            perform(held.act.verb, held.act.target, held.act.text, on: workTab)
        } else {
            var refused = held.act
            refused.outcome = "refused"
            bot.tell(Bot.Event(kind: .act, words: "", act: refused))
            observe(note: "The person refused your \(held.act.verb) on \(held.act.target).", full: false, first: false)
        }
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
        guard let bot, let page else { return }
        bot.status = "looking at the page…"
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
        Agent.ask(page, ["op": "snapshot", "full": full]) { [weak self] said in
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
            seen += "PAGE \(page.address?.absoluteString ?? "")\nTITLE \(page.title)\n\n"
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
            bot.tell(Bot.Event(kind: .trouble, words: "The task ran out of steps — say more of what you want and it can carry on.", act: nil))
            bot.over(nil)
            return
        }
        steps -= 1
        bot.status = "asking \(provider.name)…"
        // Tools and skills of the person's, when there are any, ride along
        // with the same words every time (see AIDescribed).
        let system = Bot.system + AIDescribed.forTheBot()
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: system, messages: messages)
            : AIClient.shared.stream(provider, model: model, system: system, messages: messages, key: key)
        var whole = ""
        // The reply coming in, shown as it comes: plain words as they're
        // said, and the words a JSON line holds while it's still arriving.
        // The saying the panel holds is begun here and grown piece by
        // piece (see Bot.grow).
        let draft = bot.beginDraft()
        task = Task { @MainActor [weak self] in
            do {
                for try await piece in stream {
                    guard let self else { return }
                    whole += piece
                    // The words said as they come: plain words plainly, and
                    // the say or answer inside a JSON line while the line is
                    // still arriving — the rest of the line waits for the
                    // whole of it (see Loop.wordsComing). Not every piece holds
                    // a piece: a line can be thinking, or empty.
                    let head = whole.drop(while: { " \n\t\r".contains($0) })
                    var grown = head.first == "{" ? (Loop.wordsComing(in: whole) ?? "") : String(head)
                    if !piece.isEmpty, !grown.isEmpty {
                        if grown.count > Bot.pageful { grown = String(grown.prefix(Bot.pageful)) + "…" }
                        bot.grow(draft, grown)
                    }
                    // A model talked into going on and on is stopped.
                    if whole.count > Bot.longest { break }
                }
                guard let self else { return }
                bot.finishDraft()
                self.carry(whole)
            } catch {
                self?.bot?.finishDraft()
                self?.failed(error.localizedDescription)
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
            observe(note: "Your last reply wasn't JSON with say, act, read, ui, goto, wait, full, answer, tool or skill — one object, alone or wrapped in words. Try again.", full: false, first: false)
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
        let known: Set<String> = ["say", "act", "read", "ui", "goto", "wait", "full", "answer", "later", "tab", "tool", "skill"]
        for line in text.split(separator: "\n").map(String.init) {
            if let one = object(line), !known.isDisjoint(with: one.keys) { return one }
        }
        if let open = text.firstIndex(of: "{"), let shut = text.lastIndex(of: "}"), open < shut,
           let held = object(String(text[open...shut])), !known.isDisjoint(with: held.keys) {
            return held
        }
        return nil
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
        guard let bot, let page else { return }
        // A line for one tab of many (see Tabs): taken out, and what it held
        // — a verb, an address, a target — goes to what follows, on that tab.
        var line = line
        let onTab: Tab
        if let held = line.removeValue(forKey: "tab") as? String {
            guard let found = TabsOfBrowser.byID(held) else {
                observe(note: "There's no tab called \(held) — the tabs are listed for you with their ids (TABS). Say it again with one of those.", full: false, first: false)
                return
            }
            onTab = found
        } else {
            onTab = page
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
                Chores.shared.add(goal: goal, at: at, page: work.address?.absoluteString ?? "",
                                  provider: provider.rawValue, model: model, every: every)
                bot.tell(Bot.Event(kind: .say, words: "Noted for \(Chores.spoken(at))\(every.map { ", every \(Chores.gap($0))" } ?? ""): \(goal)", act: nil))
                bot.messages = messages
                bot.over(nil)
            } else {
                observe(note: "That time couldn't be read, or it has already come — NOW it is \(Self.clock.string(from: Date())). Say the task again, with a time to come, ISO 8601.", full: false, first: false)
            }
            return
        }
        if let address = line["goto"] as? String,
           let url = URL(string: address),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            work.go(to: url)
            observe(note: "You went to \(address).", full: false, first: false)
            return
        }
        if let target = line["wait"] as? String {
            Agent.poll(work, until: Date().addingTimeInterval(15), ["op": "present", "target": target]) { [weak self] said in
                guard let self, let bot = self.bot else { return }
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
        // waits for the person's Allow like any act (Auto lets it go).
        if let tool = line["tool"] as? [String: Any],
           let name = tool["name"] as? String, !name.isEmpty {
            let arguments = tool["arguments"] as? [String: Any] ?? [:]
            let held = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            if bot.auto {
                useTool(name, arguments: held)
            } else {
                bot.pending = Bot.Pending(act: Bot.Act(verb: "tool", target: name, text: held), tab: work.id)
            }
            return
        }
        if let skill = line["skill"] as? String, !skill.isEmpty {
            readSkill(skill)
            return
        }
        if let read = line["read"] as? String, !read.isEmpty {
            perform("read", read, "", on: work)
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
            } else {
                forTab = work
            }
            if verb == "read" || bot.auto {
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
                act.outcome = said.failed ? "the tool said it failed" : "done"
                var words = said.text.isEmpty ? "nothing" : said.text
                if words.count > Bot.pageful { words = String(words.prefix(Bot.pageful)) + "…" }
                note = "Your tool \(qualified) \(said.failed ? "said it failed" : "said"): \(words)"
            } catch {
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
        guard let id = Skills.listed().first(where: { $0.name == name })?.id,
              let body = Skills.body(id) else {
            observe(note: "There's no skill called \(name) — the ones the person keeps are listed for you. Try another way.", full: false, first: false)
            return
        }
        var words = body
        if words.count > Bot.pageful { words = String(words.prefix(Bot.pageful)) + "…" }
        observe(note: "The skill \(name), the person's own words:\n\n\(words)", full: false, first: false)
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
    /// is in front when there are more than one.
    static var all: [Tab] { Front.shared.browser?.tabs ?? [] }

    /// The page the browser is on now, whose snapshot rides with the tabs.
    static var active: Tab? { Front.shared.browser?.active }

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
    /// round: takeUp false, see Chores).
    func openBot(takeUp held: Bool = true) {
        guard let tab = active, !tab.isBlank else { return }
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
    /// it gone, and the held copy dropped — the next ask starts from
    /// nothing, on this panel or the next one over the same page.
    func clearBot() {
        guard let bot = botting else { return }
        bot.clear()
        if bot.mode == .every { heldEvery = nil } else { heldTalks[bot.tab] = nil }
    }
}
