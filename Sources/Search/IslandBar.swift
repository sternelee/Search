import SwiftUI

// The island's bar: what the agents are doing, floating over the top of
// every tab — a notch, above the strip, a thing to be glanced at rather
// than gone to. An agent in the terminal you're watching isn't in it:
// the bar would say what the screen in front of you says better. An
// agent that has stopped to ask is answered right here — allowed,
// denied, or left to ask in its own terminal — without leaving the tab
// you're on. Clicking anything else about one goes to it: the window,
// the tab, the pane.

/// One notch over everything, every tab's: the sessions not already
/// watched (the front window's own tab, the pane that holds the keys),
/// each with what it's doing and, when it has stopped to ask, the
/// answer to give it.
struct IslandBar: View {
    @ObservedObject private var island = Island.shared
    // The front window, and the tab that holds it: the bar hides a
    // session the moment its terminal is gone to, and comes back the
    // moment the keys leave it — so it's the front that's watched, not
    // a window id.
    @ObservedObject private var front = Front.shared

    /// What the bar holds: everything but the terminal being watched,
    /// in the order it was said. A session with nowhere to be jumped to
    /// (outside Search's terminals) reads the same as any other — it
    /// just doesn't go anywhere when clicked.
    private var shown: [Island.Session] {
        let watched = Island.watched
        return island.sessions.filter { $0.tty != watched }
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { row, session in
                    if row > 0 { Divider().overlay(Palette.hairline) }
                    one(session)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
            .padding(.horizontal, 14)
            .transition(.opacity)
            // The whole notch rides in and out: a bar that pops up over
            // the page one session at a time is a bar that can't be
            // trusted to hold still while it's read.
            .animation(Motion.settle, value: island.sessions.count)
            .animation(Motion.settle, value: island.holds.count)
        }
    }

    /// One agent, one row: what it is, what it's doing, and — when it
    /// has stopped to ask — the say-so it's waiting on. Clicking the
    /// row goes there; the buttons answer without the trip.
    private func one(_ session: Island.Session) -> some View {
        HStack(spacing: 8) {
            // The agent and what it's doing, as a person would say it:
            // the tool it's on, or the thing it stopped to say, or
            // what it said last. One line of it — the bar is a notch,
            // not a page.
            (Text(Island.name(session.source)).foregroundColor(Palette.ink)
                + Text(partName(session.part)).foregroundColor(Palette.muted)
                + Text(detail(session)).foregroundColor(Palette.ink))
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            // The asking one's answer: given here, the agent goes on
            // without anyone going to it. A session asking in its own
            // terminal (answered "ask there") has no buttons — its own
            // asking is the asking now.
            if session.part == .asking, let hold = hold(session) {
                answerButton("Allow", Palette.safe, filled: true) { island.answer(hold, .allow) }
                answerButton("Deny", Palette.unsafe, filled: false) { island.answer(hold, .deny) }
                answerButton("Ask there", Palette.muted, filled: false) { island.answer(hold, .ownTerminal) }
            }
            // The done one is put away by hand: it was kept to be read,
            // and a click is having read it.
            else if session.part == .done {
                Button {
                    island.putAway(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Palette.muted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { island.visit(session) }
    }

    /// The hold a session's asking stands on, if it's still held: the
    /// asking part with no hold behind it is one that fell back to its
    /// own terminal's asking, and there's nothing to answer here.
    private func hold(_ session: Island.Session) -> Island.Hold? {
        return island.holds.first { $0.event.source + "/" + $0.event.session == session.id }
    }

    /// What a part is called, the little word after the name.
    private func partName(_ part: Island.Session.Part) -> String {
        switch part {
        case .asking: return " wants "
        case .waiting: return " is waiting — "
        case .working: return " is running "
        case .done: return " finished — "
        }
    }

    /// What the part's doing says, the one line of it. An asking one
    /// says the thing it wants to do; a working one, the tool it's on;
    /// a waiting or done one, the words it stopped to say.
    private func detail(_ session: Island.Session) -> String {
        switch session.part {
        case .asking, .working:
            if let tool = session.tool { return tool + (session.words.map { " \($0)" } ?? "") }
            return session.words ?? ""
        case .waiting, .done:
            return session.words ?? ""
        }
    }

    /// An answer, as a capsule the size of a word: filled for the go
    /// ahead (the one that gets the agent running again), outlined for
    /// the stop, quiet for the hand-back.
    private func answerButton(
        _ title: String, _ tint: Color, filled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(filled ? Palette.ground : tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(filled ? tint : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(tint, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
