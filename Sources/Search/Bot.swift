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
        let id = UUID()
        let kind: Kind
        let words: String
        var act: Act?
    }

    /// An act on the page: what was done, where, and how it came out.
    struct Act: Identifiable, Equatable {
        let id = UUID()
        let verb: String
        let target: String
        let text: String
        var outcome: String?
    }

    /// An act waiting on you: nothing has touched the page yet.
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let act: Act
    }

    let id = UUID()
    let tab: Tab.ID
    let provider: AIProvider
    let model: String
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
    /// The cards it has drawn, in the order they came — each answered by
    /// the ask that follows it, and gone.
    @Published private(set) var surfaces: [SurfaceViewModel] = []

    /// The loop working one ask (fileprivate: the loop is its other half).
    fileprivate var loop: Loop?
    /// The talk so far, kept between asks while the panel is open.
    fileprivate var messages: [AIMessage] = []
    private var waiting: String?
    private var cards: [String: SurfaceViewModel] = [:]

    init(tab: Tab, provider: AIProvider, model: String) {
        self.tab = tab.id
        self.page = tab
        self.provider = provider
        self.model = model
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            self.addressed = (await AIPage.read(tab))?.addressed ?? false
        }
    }

    var busy: Bool { working || pending != nil }

    /// Where it ran, for the foot of the panel.
    var place: String {
        provider == .thisMac ? "on this Mac · \(model)"
            : provider.isLocal ? "on this Mac · \(provider.name) · \(model)" : "sent to \(provider.name) · \(model)"
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

    /// Stop everything, quietly: the panel closing, a new ask coming.
    func stop() {
        loop?.halt()
        loop = nil
        working = false
        pending = nil
        status = nil
    }

    /// The turn is over — an answer, or nothing more to try.
    fileprivate func over(_ failed: String?) {
        working = false
        loop = nil
        pending = nil
        status = nil
        if let failed { trouble = failed }
    }

    fileprivate func tell(_ event: Event) {
        events.append(event)
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
        (checked, disabled…), and a number (@12). You act on things by those numbers.

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
        bot.pending = nil
        if allowed {
            perform(held.act.verb, held.act.target, held.act.text)
        } else {
            var refused = held.act
            refused.outcome = "refused"
            bot.tell(Bot.Event(kind: .act, words: "", act: refused))
            observe(note: "The person refused your \(held.act.verb) on \(held.act.target).", full: false, first: false)
        }
    }

    /// The page shown to the model: what it holds, numbered, and what came
    /// of the last thing done. The first showing carries the question.
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
            // Where it is, what it's called: what a person reads before the
            // page itself, and what a model needs to know an address by.
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
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: Bot.system, messages: messages)
            : AIClient.shared.stream(provider, model: model, system: Bot.system, messages: messages, key: key)
        var whole = ""
        task = Task { @MainActor [weak self] in
            do {
                for try await piece in stream {
                    guard let self else { return }
                    whole += piece
                    // A model talked into going on and on is stopped.
                    if whole.count > Bot.longest { break }
                }
                guard let self else { return }
                self.carry(whole)
            } catch {
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
            observe(note: "Your last reply wasn't JSON with say, act, read, ui, goto, wait, full or answer — one object, alone or wrapped in words. Try again.", full: false, first: false)
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
        let known: Set<String> = ["say", "act", "read", "ui", "goto", "wait", "full", "answer"]
        for line in text.split(separator: "\n").map(String.init) {
            if let one = object(line), !known.isDisjoint(with: one.keys) { return one }
        }
        if let open = text.firstIndex(of: "{"), let shut = text.lastIndex(of: "}"), open < shut,
           let held = object(String(text[open...shut])), !known.isDisjoint(with: held.keys) {
            return held
        }
        return nil
    }

    /// What the line asked for, in the order the person meets it: said,
    /// drawn, answered; gone, waited for, acted on.
    private func route(_ line: [String: Any]) {
        guard let bot, let page else { return }
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
        if let address = line["goto"] as? String,
           let url = URL(string: address),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            page.go(to: url)
            observe(note: "You went to \(address).", full: false, first: false)
            return
        }
        if let target = line["wait"] as? String {
            Agent.poll(page, until: Date().addingTimeInterval(15), ["op": "present", "target": target]) { [weak self] said in
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
        if let read = line["read"] as? String, !read.isEmpty {
            perform("read", read, "")
            return
        }
        if let act = line["act"] as? [String: Any],
           let verb = act["verb"] as? String, !verb.isEmpty,
           let target = act["target"] as? String, !target.isEmpty {
            let text = act["text"] as? String ?? ""
            if verb == "read" || bot.auto {
                perform(verb, target, text)
            } else {
                bot.pending = Bot.Pending(act: Bot.Act(verb: verb, target: target, text: text))
            }
            return
        }
        // A saying on its own carries on; anything else, said so.
        if line["say"] != nil {
            observe(note: nil, full: false, first: false)
            return
        }
        observe(note: "That reply had nothing to do — say, act, read, ui, goto, wait, full or answer.", full: false, first: false)
    }

    /// An act done on the page, and told: what came of it goes back with the
    /// next showing.
    private func perform(_ verb: String, _ target: String, _ text: String) {
        guard let page else { return }
        // Reading isn't an act on the page: it's the page asked for one
        // thing closely (see Agent.page).
        var op: [String: Any] = verb == "read"
            ? ["op": "read", "target": target]
            : ["op": "act", "verb": verb, "target": target]
        if !text.isEmpty { op["text"] = text }
        Agent.ask(page, op) { [weak self] said in
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

// MARK: - opening it

extension Browser {
    func openBot() {
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
        // Already open on this page: the same talk goes on.
        if let open = botting, open.tab == tab.id, open.provider == provider { return }
        botting?.stop()
        botting = Bot(tab: tab, provider: provider, model: model)
    }

    func closeBot() {
        botting?.stop()
        botting = nil
    }
}
