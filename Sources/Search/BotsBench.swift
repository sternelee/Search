import SwiftUI

/// Session-addressed test API. Unlike the old panel verbs, nothing here
/// implicitly chooses whichever conversation is currently in front.
@MainActor
enum BotsBench {
    static func state(_ session: BotSession) -> [String: Any] {
        let bot = session.runtime
        return [
            "id": session.id.uuidString, "bot": session.profileID.uuidString,
            "title": session.title, "state": bot.runState.rawValue,
            "archived": session.archived, "ephemeral": session.ephemeral,
            "busy": bot.busy, "working": bot.working, "auto": bot.auto,
            "run": bot.runID?.uuidString ?? "",
            "draft": bot.draft, "stream": bot.drafting?.words ?? "",
            "trouble": bot.trouble ?? "", "status": bot.status ?? "",
            "pending": bot.pending.map {
                ["id": $0.id.uuidString, "verb": $0.act.verb, "text": $0.act.text, "target": $0.act.target]
            } ?? [:],
            "events": bot.events.map {
                ["id": $0.id.uuidString, "kind": $0.kind.rawValue, "words": $0.words,
                 "outcome": $0.act?.outcome ?? "", "said": $0.act?.said ?? ""]
            },
        ]
    }

    static func handle(_ request: [String: Any], browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "probe only"]); return }
        let bots = Bots.shared
        bots.configure(browser.prefs, browser: browser)
        let id = (request["id"] as? String).flatMap(UUID.init(uuidString:))
        switch request["action"] as? String {
        case "profiles":
            answer(["profiles": bots.profiles.map { ["id": $0.id.uuidString, "name": $0.name, "deleted": $0.deleted] as [String: Any] }])
        case "profile":
            var profile = id.flatMap(bots.profile) ?? BotProfile()
            if let name = request["name"] as? String { profile.name = name }
            if let role = request["role"] as? String { profile.role = role }
            if let provider = request["provider"] as? String { profile.provider = AIProvider(rawValue: provider) }
            if let model = request["model"] as? String { profile.model = model }
            if let commands = request["commands"] as? Bool { profile.permissions.commands = commands }
            if let clipboard = request["clipboard"] as? Bool { profile.permissions.clipboard = clipboard }
            if let read = request["browser"] as? Bool { profile.permissions.browser = read }
            if let tools = request["tools"] as? [String] { profile.permissions.tools = Set(tools) }
            if let skills = request["skills"] as? [String] { profile.permissions.skills = Set(skills) }
            answer(bots.put(profile) ? ["id": profile.id.uuidString] : ["error": bots.error ?? "invalid profile"])
        case "new":
            guard let profile = (request["bot"] as? String).flatMap(UUID.init(uuidString:)) ?? bots.defaultID else {
                answer(["error": "no profile"]); return
            }
            let selected = request["pages"] as? [String] ?? []
            let pages = browser.tabs.filter { tab in
                selected.contains(tab.id.uuidString) || selected.contains(Bench.short(tab))
            }
            guard let session = bots.create(profileID: profile, browser: browser, tabs: pages,
                                             title: request["title"] as? String ?? "New conversation") else {
                answer(["error": bots.error ?? "cannot create conversation"]); return
            }
            answer(state(session))
        case "list":
            answer(["sessions": bots.sessions.map(state), "panes": browser.botWorkspace.panes.map(\.uuidString),
                    "showing": browser.botsShowing, "full": browser.botsFull,
                    "width": Double(browser.prefs.botWidth),
                    "room": panel(browser)])
        case "toggle":
            // The sidebar's door pressed, as it is: up if it was down, away
            // if it was up, conversations running either way.
            browser.toggleBots()
            answer(["showing": browser.botsShowing, "full": browser.botsFull])
        case "full":
            // The conversation's own header button: the panel across the
            // whole stage instead of beside the page, and back again.
            guard let on = request["on"] as? Bool else { answer(["error": "on required"]); return }
            browser.botsFull = on
            answer(["showing": browser.botsShowing, "full": browser.botsFull, "room": panel(browser)])
        case "width":
            // The panel's edge pulled, as the drag puts it there: a width,
            // held to the same least and most the gesture holds it to.
            guard let wanted = request["width"] as? Double else { answer(["error": "width required"]); return }
            browser.prefs.botWidth = min(Metrics.botPanelMax, max(Metrics.botPanelMin, CGFloat(wanted)))
            answer(["width": Double(browser.prefs.botWidth), "room": panel(browser)])
        case "hide":
            // The panel put away, by its own × or by Escape: the page takes
            // the room back and the conversations go on running.
            browser.hideBots()
            answer(["showing": browser.botsShowing, "panes": browser.botWorkspace.panes.map(\.uuidString)])
        case "page":
            // The page's own room in the window: laid out beside the panel,
            // not drawn under it.
            let box = browser.botPageRoom
            answer(["page": [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)],
                    "room": panel(browser)])
        case "picture":
            guard let path = request["path"] as? String else { answer(["error": "path required"]); return }
            // Beside the page, as the panel is drawn in the window, unless
            // the test asks for the workspace's own window: the panel's
            // narrow room is where a scroller lay over the conversation.
            let embedded = request["embedded"] as? Bool ?? true
            browser.openBots()
            let width = request["width"] as? Double ?? 420
            let height = request["height"] as? Double ?? 780
            let host = NSHostingView(rootView: BotsWorkspace(browser: browser, embedded: embedded)
                .frame(width: width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    answer(["error": "nothing drawn"]); return
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                // What a picture cannot show: overlay scrollers only draw
                // while they are used, so a sideways scroller over the
                // conversation's foot — the thing that lay across the line
                // that says the AI may be wrong — is counted in the view
                // tree instead.
                var sideways = 0
                func walk(_ view: NSView) {
                    if let scroll = view as? NSScrollView,
                       scroll.hasHorizontalScroller,
                       let document = scroll.documentView,
                       document.frame.width > scroll.contentView.bounds.width + 1 {
                        sideways += 1
                    }
                    for sub in view.subviews { walk(sub) }
                }
                walk(host)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    answer(["error": "no PNG"]); return
                }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path, "sideways": sideways])
                }
                catch { answer(["error": error.localizedDescription]) }
            }
        default:
            guard let id, let session = bots.session(id) else { answer(["error": "session id required"]); return }
            let bot = session.runtime
            switch request["action"] as? String {
            case "state": break
            case "ask":
                guard !session.archived else { answer(["error": "archived"]); return }
                bot.draft = request["text"] as? String ?? ""
                bot.submit()
            case "stop": bot.stop()
            case "agree": bot.agree()
            case "allow", "refuse":
                guard let run = request["run"] as? String, run == bot.runID?.uuidString,
                      let pending = (request["pending"] as? String).flatMap(UUID.init(uuidString:)),
                      pending == bot.pending?.id else { answer(["error": "stale approval"]); return }
                bot.resolve(request["action"] as? String == "allow", pendingID: pending)
            case "auto": bot.auto = request["on"] as? Bool ?? false
            case "show": browser.show(session)
            case "hide": browser.closeBotPane(id)
            case "archive": bots.archive(session, request["on"] as? Bool ?? true)
            case "clear": bot.clear()
            case "delete": bots.delete(session); answer(["deleted": id.uuidString]); return
            default: answer(["error": "unknown action"]); return
            }
            bots.save(session)
            answer(state(session))
        }
    }

    /// Where the Bots panel sits in the window, and how wide it is: the
    /// split the picture and the tests read.
    private static func panel(_ browser: Browser) -> [Double] {
        guard browser.botsShowing else { return [] }
        let box = browser.botRoom
        return [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)]
    }
}
