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
    /// Its own row of name and status, for a tab that has only this in it. A
    /// conversation in the Bots panel already says what it is and how its run
    /// stands in the panel's own header, and two headers in one narrow room
    /// spend the room on saying it twice.
    var showsHeader = true
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
            }
            if let notice = bot.notice {
                noticeCard(notice)
                    .frame(maxWidth: browser.prefs.chatWide ? .infinity : 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            } else {
                talk
                if let pending = bot.pending {
                    actCard(pending)
                        .frame(maxWidth: browser.prefs.chatWide ? .infinity : 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("", text: $bot.draft, prompt: Text(bot.context == nil
                        ? "Ask the agent — it works every tab you have open…"
                        : "Message this Bot…").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .focused($typing)
                        .onSubmit { bot.submit() }
                        .disabled(bot.notice != nil || bot.occupied)
                    if bot.occupied {
                        StopButton { bot.stop() }
                    } else if bot.notice == nil {
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
                .padding(.vertical, 12)
                Text("AI — may be wrong · \(bot.place)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
            }
            .frame(maxWidth: browser.prefs.chatWide ? .infinity : 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.ground)
        .onAppear { if bot.profile == nil { typing = true } }
    }

    /// What the tab holding this is, what it can read, and how wide it is read
    /// — the narrow header a conversation filling a tab keeps for itself.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            Text(bot.profile == nil ? "Agent Chat" : "Conversation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(bot.context == nil ? "every tab" : "\(bot.context?.selected.count ?? 0) pages attached")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
            Spacer(minLength: 0)
            if bot.working {
                Text(bot.status ?? "working…")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
            // The talk's width: the column it is read in, or the whole
            // tab — asked for at the top right and remembered (see
            // Preferences.chatWide).
            Door(icon: browser.prefs.chatWide ? "arrow.down.right.and.arrow.up.left"
                                               : "arrow.up.left.and.arrow.down.right",
                 on: browser.prefs.chatWide,
                 help: browser.prefs.chatWide ? "Centre the talk" : "Fill the tab") {
                browser.prefs.chatWide.toggle()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
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
                    // The model's thinking as it comes: shown muted while
                    // it's thought, over the saying when one follows, and
                    // kept in the record as a thought when it's done (see
                    // Bot.musing).
                    if let muse = bot.musing, !muse.words.isEmpty {
                        Text(verbatim: muse.words)
                            .font(.system(size: 12))
                            .italic()
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(muse.id)
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
                // The column it is read in, or the whole tab when the
                // header's switch asks for it (see Preferences.chatWide).
                .frame(maxWidth: browser.prefs.chatWide ? .infinity : 720, alignment: .leading)
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
            .onChange(of: bot.musing?.words) { _, _ in
                if let last = bot.musing { scroller.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: bot.pending) { _, _ in
                if let last = bot.events.last { scroller.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: - the asking

    /// An act that waits on you: nothing has touched anything yet.
    private func actCard(_ pending: Bot.Pending) -> some View {
        ApprovalCard(pending: pending,
                     status: bot.working ? bot.status ?? "working…" : nil,
                     resolve: { bot.resolve($0, pendingID: pending.id) },
                     always: { bot.always(pendingID: pending.id) })
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
    func openLegacyChat() -> Tab? {
        guard Store.testing else { return nil }
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
        bot.thinking = prefs.botThinking
        bot.steps = prefs.botSteps
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
        case .think:
            // A thought the model had on its way to its say: kept in the
            // record, muted — the saying it was on its way to is the thing
            // that's answered to.
            Text(verbatim: event.words)
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .act:
            if let act = event.act {
                let outcome = act.outcome
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(act.target.isEmpty ? act.verb : "\(act.verb) \(act.target)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(outcome == "refused" ? Palette.muted : Palette.faint)
                            .lineLimit(2)
                        if let outcome {
                            Text(outcome)
                                .font(.system(size: 11.5, weight: outcome == "done" ? .medium : .regular))
                                .foregroundStyle(outcome == "done" ? Palette.ink : Palette.muted)
                        }
                    }
                    // What the act said — a tool's reply, a command's print —
                    // so what the model was shown is read here too.
                    if let said = act.said, !said.isEmpty {
                        Text(verbatim: said)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
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
        case .human:
            // What's left is only a person's to do: the answer's own shape,
            // with an edge drawn around it, so what's needed of the person
            // stands out from the answers.
            MarkdownText(open: openLink, text: event.words, size: 13, color: Palette.ink)
                .padding(10)
                .background(Palette.wash.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1))
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

/// An act that waits on you, as one card: what it is, what it is aimed at
/// exactly as the Bot gave it, the whole of what it will do — never folded
/// to a couple of lines, since a person allows what they can read all of —
/// and the three answers. A tab, the page's panel and a Bot's conversation
/// all draw this one, so an asking looks the same wherever it is read.
struct ApprovalCard: View {
    let pending: Bot.Pending
    /// Where the run stands while it waits, when it is still working.
    let status: String?
    let resolve: (Bool) -> Void
    let always: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(pending.act.verb)  \(pending.act.target)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            if !pending.act.text.isEmpty {
                Text(verbatim: pending.act.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Pill("Allow", filled: true) { resolve(true) }
                Pill("Always") { always() }
                Pill("Refuse") { resolve(false) }
                if let status {
                    Spacer(minLength: 0)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
