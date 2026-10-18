import WebKit

// The hands of an AI agent, learned from ego (lite) — the browser at
// lite.ego.app, built so a model can drive it. There, an agent is given a
// task space of pages it may open and close, sees each page as a picture of
// what it holds — a link, a box to type in, a button, each with a name and a
// number — and acts on what it sees by that name or number, never by where
// it happens to sit on the screen.
//
// The same shape is given here to the bench's tabs, which already live
// apart from yours: at the end of the row, marked with a flask, never
// selected for you, never in the session or the history, gone when the
// script says so. An agent — a script of yours, a model through `agent run`,
// anything that can speak a line of JSON to the bench's socket — asks for
//
//   pages      the bench's tabs, each with a label of its own (p1, p2 …)
//   open       a new one, labelled
//   snapshot   what a page holds: `button "Sign in" @12`, `textbox "Email" @3`
//   act        click @12 · fill @3 me@here.com · press @3 Enter · select @7 October
//   read       the words at a ref, its value, where a link goes
//   wait       until something is there, or the page has loaded, or an address
//   close      one of its own, gone (by label or id, like every verb here)
//   run        a task in plain words, carried out by the model the AI add-on
//              is set to (or a provider named in the request), one act at a
//              time, each answered with the next snapshot
//
// Nothing here touches a tab that is not the bench's. The switch is the
// bench's own — Settings › General › Let a script drive Search — and every
// safety it stands for holds for these verbs too.
//
// This file: the Swift side of the verbs. The page's side — the walk that
// draws the snapshot, the resolving of a target to the element it means,
// the events an act is made of — is one script, held below, that runs in
// the page as its own JavaScript and keeps its numbers (the refs) on the
// window, where they last until the page goes elsewhere.

@MainActor
enum Agent {

    // MARK: - the verbs

    /// One request from the bench's socket: `do: "agent"`, `action:` one of
    /// the verbs above. `pick` resolves the request's tab the way the bench
    /// does — its id's first characters, or a label this surface gave it.
    static func handle(
        _ request: [String: Any], browser: Browser, pick picking: @escaping () -> Tab?, answer: @escaping ([String: Any]) -> Void
    ) {
        // The labels of pages since gone — closed by the bench's own close,
        // by the socket stopping, by the app ending a run — don't outlive
        // the pages they named.
        labels = labels.filter { entry in browser.tabs.contains { $0.id == entry.key } }
        // A tab by the label this surface gave it, or the way the bench
        // names one — the first characters of its id.
        let pick = { seek(request, in: browser, pick: picking) }
        switch request["action"] as? String {
        case "pages":
            answer(["pages": pages(in: browser)])

        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "open needs a url"]); return
            }
            let tab = browser.benchOpen(url)
            Bench.shared.house(tab)
            let label = (request["as"] as? String).map { trim($0) } ?? ""
            labels[tab.id] = label.isEmpty ? nextLabel(in: browser) : label
            answer(describe(tab, in: browser))

        case "label":
            guard let tab = pick() else { answer(["error": "no such tab"]); return }
            guard let name = (request["as"] as? String).map({ trim($0) }), !name.isEmpty else {
                answer(["error": "label needs a name"]); return
            }
            labels[tab.id] = name
            answer(describe(tab, in: browser))

        case "snapshot":
            guard let tab = pick() else { answer(["error": "no such tab"]); return }
            Bench.shared.house(tab)
            ask(tab, ["op": "snapshot", "full": request["full"] as? Bool == true]) { page in
                guard page["error"] == nil else { answer(page); return }
                var out = describe(tab, in: browser)
                out["snapshot"] = page["tree"] ?? ""
                out["refs"] = page["count"] ?? 0
                answer(out)
            }

        case "act":
            guard let tab = pick() else { answer(["error": "no such tab"]); return }
            guard let verb = request["verb"] as? String, let target = request["target"] as? String else {
                answer(["error": "act needs a verb and a target"]); return
            }
            // Where the page goes is the browser's to say, not the page's.
            if verb == "goto" {
                guard let url = Address.url(from: target) else { answer(["error": "goto needs an address"]); return }
                tab.go(to: url)
                answer(describe(tab, in: browser))
                return
            }
            Bench.shared.house(tab)
            ask(tab, ["op": "act", "verb": verb, "target": target, "text": request["text"] as? String ?? ""]) { page in
                guard page["error"] == nil else { answer(page); return }
                var out: [String: Any] = ["ok": true, "tab": Bench.short(tab)]
                for (key, value) in page where key != "ok" { out[key] = value }
                answer(out)
            }

        case "read":
            guard let tab = pick() else { answer(["error": "no such tab"]); return }
            guard let target = request["target"] as? String else { answer(["error": "read needs a target"]); return }
            Bench.shared.house(tab)
            ask(tab, ["op": "read", "target": target]) { page in answer(page) }

        case "wait":
            guard let tab = pick() else { answer(["error": "no such tab"]); return }
            let seconds = min(request["seconds"] as? Double ?? 10, 60)
            let until = Date().addingTimeInterval(seconds)
            // What is waited for: the page loaded (default), an element there
            // (`target`), words on the page (`text`), or an address (`url`).
            if let text = request["text"] as? String {
                Bench.shared.house(tab)
                poll(tab, until: until, ["op": "contains", "text": text], answer)
            } else if let target = request["target"] as? String {
                Bench.shared.house(tab)
                poll(tab, until: until, ["op": "present", "target": target], answer)
            } else if let wanted = request["url"] as? String {
                poll(until: until, check: { tab.address?.absoluteString.hasPrefix(wanted) == true }) { done in
                    var out = describe(tab, in: browser)
                    out["ok"] = done
                    if !done { out["timeout"] = true }
                    answer(out)
                }
            } else {
                poll(until: until, check: { !tab.loading && tab.address != nil }) { done in
                    var out = describe(tab, in: browser)
                    out["ok"] = done
                    if !done { out["timeout"] = true }
                    answer(out)
                }
            }

        case "close":
            guard let tab = pick() else { answer(["error": "no such tab"]); return }
            browser.close(tab)
            // The label went with the page it named.
            labels[tab.id] = nil
            answer(["closed": 1])

        case "run":
            run(request, browser: browser, tab: pick(), answer: answer)

        default:
            answer(["error": "agent needs an action: pages, open, label, snapshot, act, read, wait, close or run"])
        }
    }

    // MARK: - pages and their labels

    /// The label a tab was given here, if it still lives.
    private static var labels: [UUID: String] = [:]

    /// A label is short and plain: letters, digits, dash, at most twelve.
    private static func trim(_ name: String) -> String {
        String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(12))
    }

    /// The tab a request means: a label this surface gave it, else the
    /// bench's own way — the first characters of its id.
    private static func seek(_ request: [String: Any], in browser: Browser, pick: () -> Tab?) -> Tab? {
        guard let wanted = (request["id"] as? String)?.lowercased(), !wanted.isEmpty else { return nil }
        if let hit = browser.tabs.first(where: { labels[$0.id] == wanted && (Store.testing || $0.bench) }) { return hit }
        return pick()
    }

    private static func label(of tab: Tab) -> String? {
        guard let name = labels[tab.id] else { return nil }
        return name.isEmpty ? nil : name
    }

    /// p1, p2, p3 … — the first not held by a living tab.
    private static func nextLabel(in browser: Browser) -> String {
        let taken = Set(browser.tabs.compactMap { labels[$0.id] })
        var n = 1
        while taken.contains("p\(n)") { n += 1 }
        return "p\(n)"
    }

    /// The bench's tabs, as an agent sees them.
    private static func pages(in browser: Browser) -> [[String: Any]] {
        browser.tabs.filter { labels[$0.id] != nil }.map { tab in
            [
                "id": Bench.short(tab), "label": label(of: tab) ?? "",
                "url": tab.address?.absoluteString ?? "", "title": tab.title,
                "loading": tab.loading, "shy": tab.shy,
            ] as [String: Any]
        }
    }

    private static func describe(_ tab: Tab, in browser: Browser) -> [String: Any] {
        [
            "id": Bench.short(tab), "label": label(of: tab) ?? "",
            "url": tab.address?.absoluteString ?? "", "title": tab.title, "loading": tab.loading,
        ] as [String: Any]
    }

    // MARK: - asking the page

    /// One op for the page's side of this surface (see `page`). The answer
    /// is the script's, or `error` in its words. The bot asks the page the
    /// same way, on the page you're looking at (see Bot.swift).
    static func ask(_ tab: Tab, _ op: [String: Any], then: @escaping ([String: Any]) -> Void) {
        tab.web.evaluateJavaScript(page(op)) { value, error in
            MainActor.assumeIsolated {
                if let error { then(["error": error.localizedDescription]); return }
                if let said = value as? [String: Any] {
                    if let failure = said["__error"] as? String { then(["error": failure]); return }
                    then(said)
                } else { then(["error": "the page said nothing"]) }
            }
        }
    }

    /// Until the page says yes, or the time is up.
    static func poll(
        _ tab: Tab, until limit: Date, _ op: [String: Any], _ answer: @escaping ([String: Any]) -> Void
    ) {
        ask(tab, op) { said in
            if said["present"] as? Bool == true { answer(["ok": true, "tab": Bench.short(tab)]); return }
            guard Date() < limit else {
                var out: [String: Any] = ["ok": false, "timeout": true, "tab": Bench.short(tab)]
                if let error = said["error"] { out["error"] = error }
                answer(out); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                poll(tab, until: limit, op, answer)
            }
        }
    }

    /// Until a condition of the browser's own, or the time is up.
    private static func poll(until limit: Date, check: @escaping () -> Bool, _ then: @escaping (Bool) -> Void) {
        if check() { then(true); return }
        guard Date() < limit else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            poll(until: limit, check: check, then)
        }
    }

    // MARK: - a task in plain words

    /// What the model is told it is and has. One line back, always: an act,
    /// or the answer. Plain text, so every provider answers it — the apps on
    /// this Mac included — and no tool-calling wire format is needed.
    private static let system = """
        You are an agent driving a web browser. You see one page as a list of what it holds, \
        each thing with a kind, a name and a number (@n). Reply with exactly ONE line and nothing else:

        ACT VERB TARGET [TEXT]   to act on the page
        ANSWER TEXT              when the task is done, saying what was found or done

        Verbs: click, fill, press, select, check, uncheck, hover, scroll, read, clear — \
        TARGET a number from the list (@12), text=Words on the thing, css=a selector, \
        or loc=role:button[name='Sign in']. fill and select take the TEXT that follows; \
        press takes a key (Enter, Tab, Escape, ArrowDown). read puts what it found in your \
        next view. goto takes an address. wait TARGET pauses until it is there.

        Take one act at a time. Prefer a number from the list you were just shown. \
        If the list is stale — a number no longer there — say ACT snapshot and you will \
        be shown the page again.
        """

    /// The loop of `agent run`: a task in words, a tab to do it in, a model
    /// to carry it out. Each of the model's acts is done, and the next
    /// snapshot is its answer; when it answers in words, the task is done.
    private static func run(
        _ request: [String: Any], browser: Browser, tab picked: Tab?, answer: @escaping ([String: Any]) -> Void
    ) {
        guard let task = request["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            answer(["error": "run needs a task"]); return
        }
        // Who carries it out: the provider named, or the one the AI add-on is
        // set to. The add-on off, or held back from this build, and there is
        // no one to ask — the page's side of this surface still answers to a
        // script of your own.
        let prefs = browser.prefs
        let provider = (request["provider"] as? String).flatMap(AIProvider.init(rawValue:)) ?? prefs.aiProvider
        guard let provider else {
            answer(["error": "no model to carry this out — Settings › AI, or provider in the request"]); return
        }
        if !Store.testing {
            guard AI.shipped, prefs.ai else {
                answer(["error": "the AI add-on is off — turn it on in Settings › AI, or drive the page yourself with snapshot and act"]); return
            }
        }
        let model = request["model"] as? String ?? provider.defaultModel
        let key = AIKeys.key(for: provider) ?? ""
        let steps = min(max(request["steps"] as? Int ?? 12, 1), 40)

        // A tab of the bench's: the one asked for, or a fresh blank page.
        let tab: Tab
        if let picked { tab = picked } else {
            tab = browser.benchOpen(URL(string: "about:blank")!)
            Bench.shared.house(tab)
            labels[tab.id] = nextLabel(in: browser)
        }

        Run(provider: provider, model: model, key: key, steps: steps, tab: tab, task: task, answer: answer).start()
    }

    /// The model's whole answer, gathered from its stream.
    private static func model(
        _ provider: AIProvider, model: String, key: String, messages: [AIMessage],
        then: @escaping (Result<String, Error>) -> Void
    ) {
        Task { @MainActor in
            var said = ""
            do {
                let stream = AIClient.shared.stream(
                    provider, model: model, system: system, messages: messages, key: key
                )
                for try await piece in stream { said += piece }
                then(.success(said))
            } catch {
                then(.failure(error))
            }
        }
    }

    /// One `agent run` in flight: what has been said and done so far, and
    /// the bench's answer when it is over.
    @MainActor
    private final class Run {
        let provider: AIProvider
        let model: String
        let key: String
        let steps: Int
        let tab: Tab
        let task: String
        let answer: ([String: Any]) -> Void
        var messages: [AIMessage] = []
        var step = 0

        init(
            provider: AIProvider, model: String, key: String, steps: Int, tab: Tab, task: String,
            answer: @escaping ([String: Any]) -> Void
        ) {
            self.provider = provider
            self.model = model
            self.key = key
            self.steps = steps
            self.tab = tab
            self.task = task
            self.answer = answer
        }

        func start() { observe() }

        /// The page again, for the model to see.
        func observe() {
            Bench.shared.house(tab)
            Agent.ask(tab, ["op": "snapshot", "full": false]) { page in
                let tree = (page["tree"] as? String ?? "").prefix(6000)
                var view = "THE PAGE HOLDS:\n\(tree)"
                if tree.isEmpty, let failure = page["error"] as? String { view = "The page said: \(failure)" }
                self.messages.append(AIMessage(
                    role: .user,
                    text: "TASK: \(self.task)\n\nPAGE \(self.tab.address?.absoluteString ?? "") — \(self.tab.title)\n\(view)"
                ))
                self.think()
            }
        }

        func think() {
            step += 1
            guard step <= steps else {
                finish(note: "ran out of steps (\(steps))")
                return
            }
            Agent.model(provider, model: model, key: key, messages: messages) { result in self.carry(result) }
        }

        func carry(_ result: Result<String, Error>) {
            switch result {
            case .failure(let error):
                answer(["error": error.localizedDescription, "steps": step - 1, "tab": Bench.short(tab)])
            case .success(let said):
                guard let act = Agent.parse(said) else {
                    answer([
                        "error": "the model said no act and no answer", "said": String(said.prefix(400)),
                        "steps": step - 1, "tab": Bench.short(tab),
                    ])
                    return
                }
                messages.append(AIMessage(role: .assistant, text: act.line))
                if let words = act.answer {
                    var out: [String: Any] = [
                        "answer": words, "steps": step, "tab": Bench.short(tab),
                        "url": tab.address?.absoluteString ?? "", "title": tab.title,
                    ]
                    if let label = Agent.label(of: tab) { out["label"] = label }
                    answer(out)
                    return
                }
                // One act, then the page again.
                switch act.verb {
                case "goto":
                    guard let url = Address.url(from: act.target) else {
                        tell("goto needs an address, not \(act.target)")
                        return
                    }
                    tab.go(to: url)
                    let limit = Date().addingTimeInterval(15)
                    Agent.poll(until: limit, check: { !self.tab.loading && self.tab.address != nil }) { _ in
                        self.observe()
                    }
                case "wait":
                    let until = Date().addingTimeInterval(5)
                    Agent.poll(tab, until: until, ["op": "present", "target": act.target]) { _ in self.observe() }
                case "snapshot", "read", "click", "fill", "press", "select", "check", "uncheck", "hover", "scroll", "clear", "focus":
                    Bench.shared.house(tab)
                    // Reading the page is its own ask of the page, not an act on it.
                    let ask: [String: Any] = act.verb == "read"
                        ? ["op": "read", "target": act.target]
                        : ["op": "act", "verb": act.verb, "target": act.target, "text": act.text]
                    Agent.ask(tab, ask) { done in
                        var reply = ""
                        if let failure = done["error"] as? String {
                            reply = "the page refused: \(failure)"
                        } else if act.verb == "read" {
                            reply = "read: \(done["text"] ?? "") value \(done["value"] ?? "") href \(done["href"] ?? "")"
                        } else {
                            reply = "done"
                        }
                        self.messages.append(AIMessage(role: .user, text: reply))
                        self.observe()
                    }
                default:
                    tell("there is no verb \(act.verb)")
                }
            }
        }

        /// Words back to the model, then the page again.
        func tell(_ words: String) {
            messages.append(AIMessage(role: .user, text: words))
            observe()
        }

        func finish(note: String) {
            answer([
                "answer": "", "note": note, "steps": step - 1, "tab": Bench.short(tab),
                "url": tab.address?.absoluteString ?? "", "title": tab.title,
            ])
        }
    }

    /// The one line the model was asked for: `ACT VERB TARGET [TEXT…]` or
    /// `ANSWER TEXT`. Anything else is nothing.
    private static func parse(_ said: String) -> (line: String, verb: String, target: String, text: String, answer: String?)? {
        for raw in said.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(separator: " ", maxSplits: 3).map(String.init)
            if words.isEmpty { continue }
            let head = words[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if head == "answer" {
                return (line, "", "", "", words.count > 1 ? words[1...].joined(separator: " ") : "")
            }
            if head == "act" || head == "action" {
                guard words.count >= 3 else { continue }
                return (line, words[1].lowercased(), words[2], words.count > 3 ? words[3] : "", nil)
            }
        }
        return nil
    }

    // MARK: - the page's side

    /// The script every op runs as, in the page. It keeps its refs — the
    /// numbers a snapshot gave out — on the window, where they last as long
    /// as the page does; a number from a page since gone elsewhere is stale,
    /// and says so. One op goes in as JSON, one object comes back: what the
    /// op found, or `__error` in words a person can read.
    ///
    /// What it draws of a page is what a person would say is there — a link,
    /// a box to type in, a button, each with its name (from the page's own
    /// names first: aria-label, a label for the box, the words on it) and a
    /// number — and only what can be seen: nothing hidden, nothing scrolled
    /// out of view, unless the whole page was asked for.
    private static func page(_ op: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: op))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function () {
          var req = \(json);
          var W = window.__searchAgent;
          if (!W) W = window.__searchAgent = { next: 1, els: {} };
          var cut = 80, LIMIT = 1500;
          function trim(s) { return (s === null || s === undefined ? '' : s + '').replace(/\\s+/g, ' ').trim() }
          function short(s) { s = trim(s); return s.length > cut ? s.slice(0, cut - 1) + '…' : s }
          function visible(el) {
            if (!el || el.nodeType !== 1) return false;
            if (el.hasAttribute && (el.hasAttribute('hidden') || el.getAttribute('aria-hidden') === 'true')) return false;
            var r = el.getBoundingClientRect();
            if (r.width <= 0 && r.height <= 0) return false;
            var s = document.defaultView.getComputedStyle(el);
            return s.display !== 'none' && s.visibility !== 'hidden';
          }
          function roleOf(el) {
            var a = el.getAttribute && el.getAttribute('role');
            if (a && a !== 'generic' && a !== 'presentation' && a !== 'none') return a.toLowerCase();
            var t = el.tagName, i = (el.type || '').toLowerCase();
            if (t === 'A') return el.href ? 'link' : '';
            if (t === 'BUTTON' || t === 'SUMMARY') return 'button';
            if (t === 'SELECT') return 'combobox';
            if (t === 'TEXTAREA') return 'textbox';
            if (t === 'IMG' || t === 'SVG') return 'img';
            if (t === 'IFRAME' || t === 'FRAME') return 'iframe';
            if (t === 'VIDEO') return 'video';
            if (t === 'AUDIO') return 'audio';
            if (t === 'TABLE') return 'table';
            if (t === 'TR') return 'row';
            if (t === 'TH' || t === 'TD') return 'cell';
            if (t === 'UL' || t === 'OL') return 'list';
            if (t === 'LI') return 'listitem';
            if (t === 'DIALOG') return 'dialog';
            if (/^H[1-6]$/.test(t)) return 'heading';
            if (t === 'INPUT') {
              if (['button', 'submit', 'reset', 'image', 'file'].indexOf(i) >= 0) return 'button';
              if (i === 'checkbox') return 'checkbox';
              if (i === 'radio') return 'radio';
              if (i === 'range') return 'slider';
              if (i === 'number') return 'spinbutton';
              return 'textbox';
            }
            if (el.isContentEditable) return 'textbox';
            return '';
          }
          function nameOf(el) {
            var n = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'));
            if (n) return short(n);
            var by = el.getAttribute && el.getAttribute('aria-labelledby');
            if (by) {
              var words = [];
              by.split(/\\s+/).forEach(function (id) {
                var one = document.getElementById(id);
                if (one) words.push(one.innerText || one.textContent || '');
              });
              if (words.length) return short(words.join(' '));
            }
            if (/^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName)) {
              var id = el.id;
              if (id) {
                var l = null;
                try { l = document.querySelector('label[for="' + (id.replace(/"/g, '\\"')) + '"]') } catch (e) {}
                if (l) return short(l.innerText || l.textContent || '');
              }
              var anc = el.closest && el.closest('label');
              if (anc) return short(anc.innerText || anc.textContent || '');
            }
            var t = short(el.innerText || '');
            if (t) return t;
            if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].indexOf((el.type || '').toLowerCase()) >= 0) {
              if (el.value) return short(el.value);
            }
            return short(el.placeholder || el.alt || el.value || '');
          }
          function statesOf(el, role) {
            var s = [];
            if (/checkbox|radio|switch|menuitemcheckbox|menuitemradio/.test(role)) {
              s.push((el.checked || el.getAttribute('aria-checked') === 'true') ? 'checked' : 'unchecked');
            }
            if (el.disabled) s.push('disabled');
            if (el.tagName === 'SELECT' && el.options.length > 0) {
              var picked = el.options[el.selectedIndex];
              s.push('selected:' + short(picked ? (picked.label || picked.value) : ''));
            }
            var open = el.getAttribute && el.getAttribute('aria-expanded');
            if (open) s.push(open === 'true' ? 'expanded' : 'collapsed');
            return s;
          }
          function snapshot(full) {
            var lines = [], n = 0, seen = new Map();
            var vw = window.innerWidth || 1280, vh = window.innerHeight || 800;
            function give(el) {
              if (!seen.has(el)) { var r = '@' + (W.next++); W.els[r] = el; seen.set(el, r) }
              return seen.get(el);
            }
            function pad(d) { var s = ''; for (var i = 0; i < d; i++) s += '  '; return s }
            function place(el) {
              var r = el.getBoundingClientRect();
              return r.bottom > -80 && r.top < vh + 80 && r.right > -80 && r.left < vw + 80;
            }
            var leaf = { link: 1, button: 1, textbox: 1, combobox: 1, checkbox: 1, radio: 1, img: 1,
              heading: 1, video: 1, audio: 1, slider: 1, spinbutton: 1, switch: 1, progress: 1 };
            function visit(el, depth) {
              if (n >= LIMIT) return;
              var tag = el.tagName;
              if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|LINK|META|BASE|BR|WBR|HEAD)$/.test(tag)) return;
              if (!visible(el)) return;
              if (!full && !place(el)) return;
              var role = roleOf(el);
              if (role === 'iframe' || role === 'frame') {
                var what = short(el.getAttribute('title') || el.src || el.name || 'frame');
                lines.push(pad(depth) + 'iframe ' + JSON.stringify(what) + ' ' + give(el)); n++;
                try {
                  var doc = el.contentDocument;
                  if (doc && doc.body) visit(doc.body, depth + 1);
                } catch (e) {}
                return;
              }
              if (role && !leaf[role]) {
                var st = statesOf(el, role);
                lines.push(pad(depth) + role + (st.length ? ' [' + st.join(' ') + ']' : '') + ' ' + give(el)); n++;
                visitChildren(el, depth + 1);
                return;
              }
              if (role) {
                var st2 = statesOf(el, role);
                lines.push(pad(depth) + role + ' ' + JSON.stringify(nameOf(el))
                  + (st2.length ? ' [' + st2.join(' ') + ']' : '') + ' ' + give(el)); n++;
                return;
              }
              var kids = 0;
              for (var c = el.firstChild; c; c = c.nextSibling) if (c.nodeType === 1) kids++;
              if (kids === 0) {
                var t = short(el.innerText !== undefined ? el.innerText : (el.textContent || ''));
                if (!t && el.value) t = short(el.value);
                if (t) { lines.push(pad(depth) + 'text ' + JSON.stringify(t) + ' ' + give(el)); n++ }
                return;
              }
              visitChildren(el, depth);
            }
            function visitChildren(el, depth) {
              for (var c = el.firstChild; c; c = c.nextSibling) {
                if (n >= LIMIT) return;
                if (c.nodeType === 3) {
                  var f = short(c.textContent);
                  if (f) { lines.push(pad(depth) + 'text ' + JSON.stringify(f) + ' ' + give(el)); n++ }
                } else if (c.nodeType === 1) visit(c, depth);
              }
            }
            if (document.body) visit(document.body, 0);
            return { tree: lines.join('\\n'), count: n };
          }
          function resolve(target) {
            target = trim(target);
            var m;
            if ((m = target.match(/^@(\\d+)$/))) {
              var el = W.els['@' + m[1]];
              if (!el || !el.isConnected) throw 'no @' + m[1] + ' here — take another snapshot';
              return el;
            }
            if ((m = target.match(/^loc=role:([a-zA-Z]+)(?:\\[name(\\*)?=["'](.+?)["']\\])?$/))) {
              var want = m[1].toLowerCase(), part = m[2] === '*', like = m[3] || '';
              var found = null, all = document.querySelectorAll('*');
              for (var i = 0; i < all.length; i++) {
                var e = all[i];
                if (!visible(e)) continue;
                if (roleOf(e) !== want) continue;
                if (like) {
                  var nm = nameOf(e).toLowerCase();
                  if (!nm) continue;
                  if (part ? nm.indexOf(like.toLowerCase()) < 0 : nm !== like.toLowerCase()) continue;
                }
                if (found) throw 'more than one ' + want + (like ? ' named ' + JSON.stringify(like) : '') + ' — be more particular';
                found = e;
              }
              if (!found) throw 'no ' + want + (like ? ' named ' + JSON.stringify(like) : '') + ' on the page';
              return found;
            }
            if (target.indexOf('text=') === 0) {
              var rest = target.slice(5), exact = false;
              if (rest.length > 1 && rest[0] === '"' && rest[rest.length - 1] === '"') { exact = true; rest = rest.slice(1, -1) }
              var sought = exact ? rest : trim(rest).toLowerCase();
              var hit = null;
              var cands = document.querySelectorAll('a, button, input, select, textarea, summary, [role=button], [role=link], [role=tab], [role=menuitem], label, [contenteditable]');
              for (var j = 0; j < cands.length; j++) {
                var e2 = cands[j];
                if (!visible(e2)) continue;
                var t2 = trim(e2.innerText || '') || trim(e2.value || '') || trim(e2.getAttribute('aria-label') || '') || trim(e2.placeholder || '');
                if (!t2) continue;
                if (exact ? t2 === rest : t2.toLowerCase().indexOf(sought) >= 0) {
                  if (hit) throw 'more than one thing says ' + JSON.stringify(rest) + ' — be more particular';
                  hit = e2;
                }
              }
              if (!hit) {
                var any = document.querySelectorAll('body *');
                for (var k = 0; k < any.length; k++) {
                  var e3 = any[k];
                  if (!visible(e3)) continue;
                  var own = '';
                  for (var c2 = e3.firstChild; c2; c2 = c2.nextSibling) if (c2.nodeType === 3) own += c2.textContent;
                  own = trim(own);
                  if (own && (exact ? own === rest : own.toLowerCase().indexOf(sought) >= 0)) {
                    if (hit) throw 'more than one thing says ' + JSON.stringify(rest) + ' — be more particular';
                    hit = e3;
                  }
                }
              }
              if (!hit) throw 'nothing on the page says ' + JSON.stringify(rest);
              // A label stands for its field: fill and check land on the input.
              if (hit.tagName === 'LABEL') {
                var forId = hit.getAttribute('for');
                var ctl = forId ? document.getElementById(forId) : hit.querySelector('input, select, textarea');
                if (ctl) hit = ctl;
              }
              return hit;
            }
            if (target.indexOf('xpath=') === 0) {
              var x = document.evaluate(target.slice(6), document, null, 9, null).singleNodeValue;
              if (!x) throw 'nothing matches ' + target;
              return x;
            }
            var css = target.indexOf('css=') === 0 ? target.slice(4) : target;
            var one = null;
            try { one = document.querySelector(css) } catch (e4) { throw 'not a selector: ' + target }
            if (!one) throw 'nothing matches ' + target;
            return one;
          }
          function scrollMid(el) {
            try { el.scrollIntoView({ block: 'center', inline: 'center' }) } catch (e) { try { el.scrollIntoView() } catch (e2) {} }
          }
          function point(el) {
            var r = el.getBoundingClientRect();
            return [Math.round(r.left + r.width / 2), Math.round(r.top + r.height / 2)];
          }
          function mouse(el, type) {
            var at = point(el);
            var o = { bubbles: true, cancelable: true, view: window, clientX: at[0], clientY: at[1] };
            var ev;
            try { ev = new PointerEvent(type === 'click' ? 'click' : type, o) } catch (e) { ev = new MouseEvent(type, o) }
            el.dispatchEvent(ev);
            return ev;
          }
          var KEYS = { enter: ['Enter', 'Enter', 13], tab: ['Tab', 'Tab', 9], escape: ['Escape', 'Escape', 27],
            esc: ['Escape', 'Escape', 27], return: ['Enter', 'Enter', 13], backspace: ['Backspace', 'Backspace', 8],
            delete: ['Delete', 'Delete', 46], space: [' ', 'Space', 32], arrowdown: ['ArrowDown', 'ArrowDown', 40],
            down: ['ArrowDown', 'ArrowDown', 40], arrowup: ['ArrowUp', 'ArrowUp', 38], up: ['ArrowUp', 'ArrowUp', 38],
            arrowleft: ['ArrowLeft', 'ArrowLeft', 37], left: ['ArrowLeft', 'ArrowLeft', 37],
            arrowright: ['ArrowRight', 'ArrowRight', 39], right: ['ArrowRight', 'ArrowRight', 39],
            home: ['Home', 'Home', 36], end: ['End', 'End', 35], pageup: ['PageUp', 'PageUp', 33],
            pagedown: ['PageDown', 'PageDown', 34] };
          function key(el, type, spec) {
            var ev = new KeyboardEvent(type, { bubbles: true, cancelable: true, view: window,
              key: spec[0], code: spec[1], keyCode: spec[2], which: spec[2] });
            el.dispatchEvent(ev);
            return ev;
          }
          function settled(el) {
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          function act(verb, target, text) {
            var el = resolve(target);
            if (!el.focus) throw 'not something the page can act on';
            scrollMid(el);
            if (verb === 'click') {
              mouse(el, 'mouseover'); mouse(el, 'mousemove');
              mouse(el, 'pointerdown'); mouse(el, 'mousedown');
              mouse(el, 'pointerup'); mouse(el, 'mouseup');
              el.click();
              return { at: point(el) };
            }
            if (verb === 'hover') { mouse(el, 'mouseover'); mouse(el, 'mousemove'); return { at: point(el) } }
            if (verb === 'scroll') return { at: point(el) };
            if (verb === 'fill' || verb === 'clear') {
              var t = verb === 'clear' ? '' : (text || '');
              try { el.focus({ preventScroll: true }) } catch (e) { el.focus() }
              if (el.isContentEditable) { el.textContent = t; settled(el) }
              else if (/^(INPUT|TEXTAREA)$/.test(el.tagName)) {
                var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
                Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, t);
                settled(el);
              } else throw 'fill needs somewhere words go — this is a ' + el.tagName.toLowerCase();
              return { value: el.value !== undefined ? el.value : trim(el.textContent) };
            }
            if (verb === 'press') {
              var spec = KEYS[trim(text).toLowerCase()];
              if (!spec) throw 'no key called ' + JSON.stringify(text) + ' — Enter, Tab, Escape, ArrowDown and their kin';
              try { el.focus({ preventScroll: true }) } catch (e2) { el.focus() }
              var down = key(el, 'keydown', spec);
              key(el, 'keypress', spec);
              key(el, 'keyup', spec);
              if (spec[0] === 'Enter' && el.tagName === 'INPUT' && el.form && !down.defaultPrevented) {
                try { el.form.requestSubmit() } catch (e3) {}
                return { at: point(el), submitted: true };
              }
              return { at: point(el) };
            }
            if (verb === 'select') {
              if (el.tagName !== 'SELECT') throw 'select needs a <select>, this is a ' + (roleOf(el) || el.tagName.toLowerCase());
              var want = trim(text), pick = null;
              for (var i = 0; i < el.options.length; i++) {
                var o = el.options[i];
                if (o.value === want || o.label === want || String(i) === want
                  || o.label.toLowerCase() === want.toLowerCase()) { pick = o; break }
              }
              if (!pick) throw 'no option ' + JSON.stringify(want);
              el.value = pick.value;
              settled(el);
              return { value: el.value, label: short(pick.label || pick.value) };
            }
            if (verb === 'check' || verb === 'uncheck') {
              var on = verb === 'check';
              if (el.type !== 'checkbox' && el.type !== 'radio' && roleOf(el).indexOf('check') < 0 && roleOf(el).indexOf('radio') < 0) {
                throw 'not a checkbox or radio';
              }
              if ((el.checked || false) !== on) el.click();
              return { checked: el.checked || el.getAttribute('aria-checked') === 'true' };
            }
            if (verb === 'focus') { try { el.focus({ preventScroll: true }) } catch (e4) { el.focus() } return {} }
            throw 'no verb ' + JSON.stringify(verb);
          }
          function read(target) {
            var el = resolve(target);
            var out = {
              tag: (el.tagName || '').toLowerCase(), role: roleOf(el),
              text: (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 4000),
              value: el.value !== undefined ? el.value : '', checked: !!el.checked,
              disabled: !!el.disabled, href: el.href || '',
            };
            return out;
          }
          try {
            if (req.op === 'snapshot') return snapshot(req.full === true);
            if (req.op === 'act') { var done = act(req.verb, req.target, req.text || ''); done.ok = 1; return done }
            if (req.op === 'read') { var got = read(req.target); got.ok = 1; return got }
            if (req.op === 'present') return { present: (function () { try { return visible(resolve(req.target)) } catch (e) { return false } })() };
            if (req.op === 'contains') {
              var body = document.body ? (document.body.innerText || '') : '';
              return { present: body.indexOf(req.text || '') >= 0 };
            }
            return { __error: 'no op ' + req.op };
          } catch (err) {
            return { __error: (err && err.message) ? err.message : String(err) };
          }
        })()
        """
    }
}
