import SwiftUI
import A2UISwiftUI

// The bot's panel: the talk, the cards it draws, and — between the two —
// the asking. What you asked is at the top in your words; what it said and
// did follows, every act shown as it came out; a card waits under the talk
// until you tap something in it. An act that touches the page stands in the
// middle as a card of its own: what, where, and Allow or Refuse. Turn on
// Auto and those cards stop coming (the switch is right there). The first
// time a provider off this Mac would be sent something, the notice comes
// instead, and nothing goes until you read it and say Continue.

struct BotPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bot: Bot
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text("Bot")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if bot.working {
                    Text(bot.status ?? "working…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                Door(icon: "trash", help: "Clear this talk, and what's kept") { browser.clearBot() }
                Door(icon: "xmark", help: "Close   esc") { browser.closeBot() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Where it works: this page, or every tab — the switch is small,
            // and what it changes is the talk it carries on with.
            HStack(spacing: 6) {
                Text("Works on")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                Segmented(options: [(false, "This Page"), (true, "All Tabs")], selection: $browser.botEverywhere)
                    .disabled(bot.busy)
                if bot.mode == .every {
                    Text("one talk, every tab")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // The notice in place of the talk: read it before anything
            // goes — the card itself, never buried inside the talk it
            // stands in for (it once was, and a person saw nothing at all).
            if let notice = bot.notice {
                noticeCard(notice)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else {
                scrolling
                if let pending = bot.pending {
                    actCard(pending)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                TextField("", text: $bot.draft, prompt: Text("Tell the bot what to do…").foregroundStyle(Palette.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .onSubmit { bot.submit() }
                    .disabled(bot.notice != nil || bot.busy)
                if !bot.busy, bot.notice == nil {
                    Text("Auto")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                    Switch(on: $bot.auto)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Text("AI — may be wrong · \(bot.place)")
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
        .onAppear { typing = true }
    }

    private var scrolling: some View {
        ScrollViewReader { scroller in
            ScrollView(showsIndicators: false) {
                conversation
                    .padding(.horizontal, 16)
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
        .frame(maxHeight: 420)
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let trouble = bot.trouble {
                Text(trouble).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
            if bot.addressed, bot.notice == nil {
                Caution("This page has text written for an AI to follow. The bot may be steered by it.")
            }
            ForEach(bot.events) { event in
                EventView(event: event).id(event.id)
            }
            // The reply as it comes: a saying on the panel, grown piece
            // by piece while the model is still saying it.
            if let draft = bot.drafting, !draft.words.isEmpty {
                Text(verbatim: draft.words)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(draft.id)
            }
            if !bot.surfaces.isEmpty, bot.notice == nil {
                cards
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cards it has drawn, one under another: native controls, and a
    /// tap in them goes back to the model as an event.
    private var cards: some View {
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

    /// An act that waits on you: nothing has touched the page yet.
    private func actCard(_ pending: Bot.Pending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(pending.act.verb)  \(pending.act.target)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            if !pending.act.text.isEmpty {
                // Whole, never folded to a couple of lines: a command to
                // run, a thought to keep, a task's goal — the person
                // allows what they can read all of.
                Text(verbatim: pending.act.text)
                    .font(.system(size: 12))
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
            Text("The bot's AI: \(bot.provider.name)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(verbatim: notice)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Pill("Continue", filled: true) { bot.agree() }
                Pill("Cancel") { browser.closeBot() }
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private struct EventView: View {
        let event: Bot.Event

        var body: some View {
            switch event.kind {
            case .ask:
                Text(verbatim: event.words)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
            case .say:
                Text(verbatim: event.words)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            case .act:
                if let act = event.act {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(act.verb) \(act.target)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(act.outcome == "refused" ? Palette.muted : Palette.faint)
                            .lineLimit(2)
                        if let outcome = act.outcome {
                            Text(outcome)
                                .font(.system(size: 11.5, weight: act.outcome == "done" ? .medium : .regular))
                                .foregroundStyle(outcome == "done" ? Palette.ink : Palette.muted)
                        }
                    }
                }
            case .answer:
                // As written, and never as markdown: no link to follow, no
                // picture to fetch.
                Text(verbatim: event.words)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
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
}
