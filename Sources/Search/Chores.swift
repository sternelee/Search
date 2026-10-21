// The tasks the bot is set for a time to come (see Bot): asked for over a
// page — "tomorrow at eight, grab me a ticket" — the model sums the goal up
// in its own words, notes the time and the page (a "later" line), and when
// the time comes the page is opened again and the bot let loose on it,
// Auto on. The panel is there if the person is, to watch it work or to
// stop it; no one is needed at the keys.
//
// Kept as one line of JSON in settings (see MCPHub for the same trick) and
// listed in Settings › AI, where they can be taken off. A time that passes
// while Search isn't running is missed, not run — a ticket grabbed hours
// late is no ticket grabbed — and says so there. Only the bot's own acts
// on that page run, held to the same rules as any other turn.

import SwiftUI

@MainActor
final class Chores: ObservableObject {
    /// One task for a time to come: the goal in the bot's own words, the
    /// page it was set on, and what came of it when its time came.
    struct Chore: Codable, Identifiable, Equatable {
        enum State: String, Codable { case waiting, running, done, failed, human, missed }
        var id = UUID()
        var goal: String
        var at: Date
        var page: String
        var provider: String
        var model: String
        var state = State.waiting
        /// For a task that comes round again ("every ten minutes"): the gap
        /// between rounds, in seconds. A task with none comes once.
        var every: TimeInterval?
        /// What came of it: the answer it ended with, or the trouble.
        var words: String?
        /// When the person set it.
        var made = Date()
    }

    static let shared = Chores()

    @Published private(set) var tasks: [Chore] = []
    private static let list = "chores.list"
    private weak var browser: Browser?
    private var clock: Timer?

    init() {
        if let kept = Store.settings.string(forKey: Self.list),
           let data = kept.data(using: .utf8),
           let held = try? JSONDecoder().decode([Chore].self, from: data) {
            tasks = held
        }
        // A time that passed while Search wasn't running is missed, not
        // run — the task says so, and can be set again. One that comes
        // round again rolls on to its next round instead: the news is as
        // good ten minutes late as twenty, and the rounds that were
        // skipped while Search was closed aren't run all at once.
        for place in tasks.indices where tasks[place].state == .waiting && tasks[place].at <= Date() {
            if let every = tasks[place].every, every >= Self.roundLeast {
                while tasks[place].at <= Date() { tasks[place].at = tasks[place].at.addingTimeInterval(every) }
            } else {
                tasks[place].state = .missed
                tasks[place].words = "its time came while Search wasn't running"
            }
        }
        keep()
    }

    /// The browser in on it from here (App, as the window appears): the
    /// clock starts, and what comes due goes to the bot while Search runs.
    func wake(_ browser: Browser) {
        self.browser = browser
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Half a minute of looking: what's waiting and due goes to the bot,
    /// one at a time — one already running stays at it, and the bot busy
    /// with the person's own work waits for the next look.
    func tick() {
        guard let browser, !tasks.contains(where: { $0.state == .running }) else { return }
        guard !(browser.botting?.busy ?? false),
              let place = tasks.firstIndex(where: { $0.state == .waiting && $0.at <= Date() }) else { return }
        tasks[place].state = .running
        keep()
        browser.runChore(tasks[place])
    }

    /// The least gap a task that comes round again can have: the clock
    /// looks every half minute, so less than a minute apart would be
    /// rounds run back to back.
    static let roundLeast: TimeInterval = 60

    /// A task set (Bot's own later line, or a test run's say-so).
    @discardableResult func add(goal: String, at: Date, page: String, provider: String, model: String, every: TimeInterval? = nil) -> Chore {
        let task = Chore(goal: goal, at: at, page: page, provider: provider, model: model, every: every)
        tasks.append(task)
        keep()
        return task
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        keep()
    }

    /// What came of a run: the answer it ended with, or the trouble
    /// (Browser.runChore, when the bot's turn is over). A task that comes
    /// round again is set for its next round instead — done or not, what
    /// came of this round kept as its words — until the person takes it
    /// off; a round that went wrong tries again at its next time.
    func finished(_ id: UUID, state: Chore.State, words: String?) {
        guard let place = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let every = tasks[place].every, every >= Self.roundLeast {
            tasks[place].at = Date().addingTimeInterval(every)
            tasks[place].state = .waiting
            tasks[place].words = words
        } else {
            tasks[place].state = state
            tasks[place].words = words
        }
        keep()
    }

    private func keep() {
        if let data = try? JSONEncoder().encode(tasks) {
            Store.settings.set(String(data: data, encoding: .utf8), forKey: Self.list)
        }
    }

    /// A time the model gives, read: ISO 8601 (the person's own timezone
    /// given with it, or Z), or a plain local "2026-10-15 08:00".
    static func read(_ when: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: when) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: when) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = .current
        plain.dateFormat = "yyyy-MM-dd HH:mm"
        return plain.date(from: when)
    }

    /// A time as the person reads it: the bot's saying, and the list.
    static func spoken(_ at: Date) -> String {
        let read = DateFormatter()
        read.dateStyle = .medium
        read.timeStyle = .short
        return read.string(from: at)
    }

    /// A gap between rounds, as the person reads it: "10 min", "1 hour
    /// 30 min", "1 day".
    static func gap(_ every: TimeInterval) -> String {
        let seconds = max(Int(Self.roundLeast), Int(every))
        func many(_ n: Int, _ one: String, _ rest: String) -> String { n == 1 ? one : "\(n) \(rest)" }
        var parts: [String] = []
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { parts.append(many(days, "1 day", "days")) }
        if hours > 0 { parts.append(many(hours, "1 hour", "hours")) }
        if minutes > 0 || parts.isEmpty { parts.append(many(minutes, "1 min", "min")) }
        return parts.joined(separator: " ")
    }

    /// For the bench: every task, in words.
    func listed() -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        return tasks.map { [
            "id": $0.id.uuidString, "goal": $0.goal, "at": iso.string(from: $0.at),
            "every": $0.every.map { Int($0) } ?? 0,
            "page": $0.page, "state": $0.state.rawValue, "words": $0.words ?? "",
        ] as [String: Any] }
    }
}

// MARK: - when the time comes

extension Browser {
    /// A chore come due: its page opened again, the bot let loose on it
    /// with Auto on — its acts go ahead, no one at the keys to allow them.
    /// The page opens behind whatever the person is doing and takes no
    /// focus from it: the panel is there if they are, to watch it work or
    /// to stop it. Beyond the page nothing goes — no commands, no tools,
    /// no history — for there is no one there to allow them.
    func runChore(_ chore: Chores.Chore) {
        announce("A task come due: \(chore.goal)")
        guard let url = URL(string: chore.page),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            Chores.shared.finished(chore.id, state: .failed, words: "its page is no address the bot can work")
            return
        }
        let tab = open(url, foreground: false)
        // Opened behind and never selected, the view would lay out at nothing
        // (a page 0 by 0): no click could land on it. It lives off-screen in
        // the bench's room until the person picks its tab.
        Bench.shared.house(tab)
        // The page has to come in before the bot can look at it: the bot
        // works over a page, not a blank.
        Task { @MainActor [weak tab] in
            let end = Date().addingTimeInterval(20)
            while let held = tab, held.loading, Date() < end {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let tab, !tab.isBlank, tab.loading == false else {
                Chores.shared.finished(chore.id, state: .failed, words: "its page never came in")
                return
            }
            // Each round stands on its own: no talk taken up from the
            // page's last one, which would grow round over round.
            openBot(over: tab, takeUp: false)
            guard let bot = botting, bot.tab == tab.id else {
                Chores.shared.finished(chore.id, state: .failed, words: "the bot couldn't open over its page")
                return
            }
            bot.auto = true
            var draft = "The task the person set for this time: \(chore.goal). No one may be watching — don't draw a card, it waits for a tap that may never come, and nothing beyond the page goes (no commands, no clipboard, no tools, no history): there is no one there to allow it. Work the page, and when it's done, answer with what you have; when what's left is only a person's to do — a password, a code from another place, a payment — say {\"human\": \"what's needed of them\"} and stop."
            if let every = chore.every {
                draft += " This task comes round every \(Chores.gap(every)); this round's answer is kept for the person, and the next round is already set — answer with what this one round brought, and don't try to do the next round's work."
            }
            // Every turn's end told: what came of it goes to the task —
            // an answer, a trouble, what only a person can do, or a card
            // waiting for a tap no one may ever give (a tap or a new ask
            // carries it on).
            bot.onOver = { trouble in
                if let trouble {
                    Chores.shared.finished(chore.id, state: .failed, words: trouble)
                } else if let human = bot.events.last(where: { $0.kind == .human })?.words {
                    Chores.shared.finished(chore.id, state: .human, words: human)
                } else if let answer = bot.events.last(where: { $0.kind == .answer })?.words {
                    Chores.shared.finished(chore.id, state: .done, words: answer)
                } else if let worry = bot.events.last(where: { $0.kind == .trouble })?.words {
                    Chores.shared.finished(chore.id, state: .failed, words: worry)
                } else if !bot.surfaces.isEmpty {
                    Chores.shared.finished(chore.id, state: .done, words: "it ended with a card, waiting for a tap")
                } else {
                    Chores.shared.finished(chore.id, state: .failed, words: "it ended without an answer")
                }
            }
            bot.draft = draft
            bot.submit()
            // The ask is in — and from here, no one is at the keys: submit
            // itself would say otherwise (the person's own hand at them).
            bot.unattended = true
        }
    }
}
