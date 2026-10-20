import SwiftUI
import AppKit
import A2UISwiftUI

// The Agent Chat tab: a tab that is a talk, not a page. Made from the
// File menu and nowhere else, it holds one conversation with the model
// that reaches every tab in the row — the same bot, the same rules (see
// Bot.swift): every act waits for the person's Allow, everything beyond
// the page asks, a close always asks, Auto is the person's own switch.
// The page it shows the model is whichever is in front; when the person
// is on this tab, none is, and every act names its own.
//
// The tab is closed like any tab and goes with its talk; it is not kept
// for the next time the browser opens, goes nowhere, pins to nothing and
// is no page to split, to script or to work from outside.

// MARK: - the stage

/// What a chat tab shows in place of a page: the talk, and — under it,
// where a page would keep its find bar — the asking.
struct ChatStage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bot: Bot
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text("Agent Chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("every tab")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                Spacer(minLength: 0)
                if bot.working {
                    Text(bot.status ?? "working…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let notice = bot.notice {
                noticeCard(notice)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            } else {
                talk
                if let pending = bot.pending {
                    actCard(pending)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                TextField("", text: $bot.draft, prompt: Text("Ask the agent — it works every tab you have open…").foregroundStyle(Palette.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .onSubmit { bot.submit() }
                    .disabled(bot.notice != nil || bot.busy)
                if bot.busy {
                    // The stop: the turn as it stands, quiet (see Bot.stop)
                    // — a working answer cut where it is, an act still
                    // waiting refused without a word.
                    Button(action: { bot.stop() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.ground)
                            .frame(width: 24, height: 24)
                            .background(Palette.ink, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else if bot.notice == nil {
                    // The send: what Return does, for the pointer. Nothing
                    // written, nothing to press.
                    let canSend = !bot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(action: { bot.submit() }) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(canSend ? Palette.ground : Palette.faint)
                            .frame(width: 24, height: 24)
                            .background(canSend ? Palette.ink : Palette.wash, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                    Text("Auto")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                    Switch(on: $bot.auto)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Text("AI — may be wrong · \(bot.place)")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.ground)
        .onAppear { typing = true }
    }

    // MARK: - the talk

    private var talk: some View {
        ScrollViewReader { scroller in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let trouble = bot.trouble {
                        Text(trouble).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    }
                    ForEach(bot.events) { event in
                        chatEventView(event).id(event.id)
                    }
                    // The reply as it comes: a saying on the tab, grown piece
                    // by piece while the model is still saying it.
                    if let draft = bot.drafting, !draft.words.isEmpty {
                        // Drawn as it comes, the markdown in it read as it
                        // stands so far (see MarkdownText — the blocks
                        // whole ones are made of arrive when it's done).
                        MarkdownText(open: openLink, text: draft.words, size: 13.5)
                            .id(draft.id)
                    }
                    if !bot.surfaces.isEmpty, bot.notice == nil {
                        VStack(spacing: 10) {
                            ForEach(bot.surfaces, id: \.surface.id) { card in
                                A2UISurfaceView(viewModel: card, scrolls: false) { action in
                                    Task { @MainActor in bot.tapped(action) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Palette.wash.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .onChange(of: bot.events.last?.id) { _, _ in
                if let last = bot.events.last { scroller.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: bot.drafting?.words) { _, _ in
                if let last = bot.drafting { scroller.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: bot.pending) { _, _ in
                if let last = bot.events.last { scroller.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: - the asking

    /// An act that waits on you: nothing has touched anything yet. The
    /// same card the panel holds, on the width of a tab.
    private func actCard(_ pending: Bot.Pending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(pending.act.verb)  \(pending.act.target)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            if !pending.act.text.isEmpty {
                // Whole, never folded: a command to run, a thought to keep,
                // a task's goal — the person allows what they can read all of.
                Text(verbatim: pending.act.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Pill("Allow", filled: true) { bot.resolve(true) }
                Pill("Always") { bot.always() }
                Pill("Refuse") { bot.resolve(false) }
                if bot.working {
                    Spacer(minLength: 0)
                    Text(bot.status ?? "working…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
            }
        }
        .padding(12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func noticeCard(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The chat's AI: \(bot.provider.name)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(verbatim: notice)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Pill("Continue", filled: true) { bot.agree() }
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - opening it

extension Browser {
    /// The Agent Chat tab, from the File menu and nowhere else: a talk
    /// that reaches every tab, with the bot's own rules. The same guards
    /// as the bot over a page — the bot on, a provider chosen, a key kept
    /// — said plainly in the announcements when they aren't met.
    @discardableResult
    func openChat() -> Tab? {
        guard prefs.bot, let provider = prefs.aiProvider else {
            settingsPage = .ai
            tuning = true
            announce(prefs.bot ? "Choose where the chat's AI runs" : "Turn on the AI in Settings › AI")
            return nil
        }
        if provider == .thisMac, AIEngine.shared.state != .ready {
            settingsPage = .ai
            tuning = true
            announce("The model isn't on this Mac yet")
            return nil
        }
        let model = prefs.aiModel(for: provider)
        guard !model.isEmpty || provider.isLocal else {
            settingsPage = .ai
            tuning = true
            announce("Choose a model for \(provider.name)")
            return nil
        }
        guard provider.isLocal || AIKeys.hint(for: provider) != nil else {
            settingsPage = .ai
            tuning = true
            announce("No key for \(provider.name) yet")
            return nil
        }
        let tab = Tab(chat: true)
        placeChat(tab)
        // The tools and skills the person keeps are offered as the talk
        // comes in, their servers connected in the background (see
        // AIDescribed).
        MCPHub.shared.wake()
        let bot = Bot(chat: tab, provider: provider, model: model)
        chatBots[tab.id] = bot
        return tab
    }

    /// The chat tab in front, if the front tab is one — what a test drives
    /// (see Bench's chat verbs).
    var frontChat: Bot? {
        guard let active, active.chat else { return nil }
        return chatBots[active.id]
    }
}

// MARK: - one event on the tab

/// How one event of the talk is said on the chat tab: the same words the
/// panel would show (see BotEventView — rendered here, not shared with the
/// panel, because a SwiftUI view made in another file vanishes from a
/// ForEach under -Osize: the release build's optimizer drops the whole
/// view, and a talk that happened shows nothing at all).
private struct ChatEventView: View {
    let event: Bot.Event
    /// A link's tap, opened the browser's way (the stage's own open —
    /// see openLink below).
    let openLink: (URL) -> Void

    var body: some View {
        switch event.kind {
        case .ask:
            Text(verbatim: event.words)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
        case .say:
            // The model's sayings speak markdown: headings, lists, code
            // blocks, bold, links — drawn the way they were written.
            MarkdownText(open: openLink, text: event.words, size: 13, color: Palette.ink)
        case .act:
            if let act = event.act {
                let outcome = act.outcome
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(act.verb) \(act.target)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(outcome == "refused" ? Palette.muted : Palette.faint)
                        .lineLimit(2)
                    if let outcome {
                        Text(outcome)
                            .font(.system(size: 11.5, weight: outcome == "done" ? .medium : .regular))
                            .foregroundStyle(outcome == "done" ? Palette.ink : Palette.muted)
                    }
                }
            }
        case .answer:
            // The answer on a card of its own, the markdown in it read:
            // headings, lists, code blocks, bold, links drawn as written
            // (see MarkdownText).
            MarkdownText(open: openLink, text: event.words, size: 13, color: Palette.ink)
                .padding(10)
                .background(Palette.wash.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .card:
            EmptyView()
        case .trouble:
            Text(verbatim: event.words)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ChatStage {
    /// One event of the talk, drawn the tab's way (see ChatEventView).
    fileprivate func chatEventView(_ event: Bot.Event) -> some View {
        ChatEventView(event: event, openLink: openLink)
    }

    /// A link tapped in the talk: opened the browser's way, the same
    /// as a link on any page — never by the model's words alone.
    fileprivate func openLink(_ url: URL) {
        browser.open(url, foreground: true)
    }
}
