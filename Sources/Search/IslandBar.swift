import SwiftUI

// The island's bar: what the agents are doing, floating over the top of
// every tab — a notch, above the strip, a thing to be glanced at rather
// than gone to. An agent in the terminal you're watching isn't in it:
// the bar would say what the screen in front of you says better. An
// agent that has stopped to ask is answered right here — allowed,
// denied, or left to ask in its own terminal — without leaving the tab
// you're on. Clicking anything else about one goes to it: the window,
// the tab, the pane. Each one is named by who it is and where it works
// — the folder, as a person would say it — and the bar itself is
// dragged to where it's wanted (along the top, and down from it) and
// stretched as wide as it's read. Every row is closed by hand — put
// away until it says something worth hearing again — holding all three
// of those (IslandPlace, and Island.putAway).

/// Where the bar sits and how wide it is, kept as fractions and edges
/// a drag can say: the math of it, here so it can be held to (and
/// tested) without a window in the way.
enum IslandPlace {
    /// The narrowest the bar is dragged down to, and the widest it's
    /// stretched to. The room it's in overrules the widest, never the
    /// narrowest — a bar narrower than this isn't one anybody reads.
    static let leastWidth: CGFloat = 220
    static let mostWidth: CGFloat = 720

    /// The width to hold, whatever the drag said: kept between the
    /// narrowest and the widest, with the room's own say the last word
    /// on how wide that is (a breath each side, fourteen, off the
    /// room's edges).
    static func width(_ said: CGFloat, room: CGFloat) -> CGFloat {
        let most = max(leastWidth, min(mostWidth, room - 28))
        return min(max(said, leastWidth), most)
    }

    /// The bar's left edge for a center said as a share of the room,
    /// kept a breath in from each edge. A room with no room to spare
    /// (narrower than the bar and both breaths) puts the bar wherever
    /// it fits best, the middle, there being nowhere else.
    static func left(center: CGFloat, width: CGFloat, room: CGFloat) -> CGFloat {
        guard room > width + 28 else { return (room - width) / 2 }
        return min(max(center * room - width / 2, 14), room - width - 14)
    }

    /// The center, as the share of the room it is — the drag's say-so
    /// put back the way it's kept, so a bar dragged to a place rides
    /// out a window resized under it.
    static func center(left: CGFloat, width: CGFloat, room: CGFloat) -> CGFloat {
        guard room > 0 else { return 0.5 }
        return (left + width / 2) / room
    }

    /// How far down the bar is dragged, whatever the drag said: never
    /// above the notch it starts at (the tabs' strip is its place, and
    /// up from there is theirs), and never so far down it leaves the
    /// window — a breath (fourteen) of the room kept under it, so the
    /// bar stays a notch and never becomes a page.
    static func down(_ said: CGFloat, room: CGFloat, bar: CGFloat) -> CGFloat {
        min(max(said, 0), max(0, room - bar - 14))
    }
}

/// The bar's own height, said by the bar itself — measured with a
/// GeometryReader behind it, the bar being the one thing that knows
/// how many rows it's holding.
private struct BarHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One notch over everything, every tab's: the sessions not already
/// watched (the front window's own tab, the pane that holds the keys),
/// each with what it's doing and, when it has stopped to ask, the
/// answer to give it.
struct IslandBar: View {
    /// The room the bar sits in: the window, given by the one who knows
    /// it (the overlay's GeometryReader, in App) — its width for the
    /// place along the top and the width of the bar, its height for how
    /// far down the bar can be dragged.
    let room: CGSize

    @ObservedObject private var island = Island.shared
    // The front window, and the tab that holds it: the bar hides a
    // session the moment its terminal is gone to, and comes back the
    // moment the keys leave it — so it's the front that's watched, not
    // a window id.
    @ObservedObject private var front = Front.shared

    // Where the bar sits and how wide it is, kept from run to run: a
    // share of the window for the place along the top (so a resized
    // window keeps the bar in it), points for the width and for how
    // far down it was dragged. A drag says all three, and says them
    // through IslandPlace, which keeps them inside the window.
    @AppStorage("island.center") private var center = 0.5
    @AppStorage("island.width") private var held = 360.0
    @AppStorage("island.down") private var down = 0.0

    /// Where the drag started, taken on its first word: the left edge,
    /// the top, and the width as they stood, so the drag says where it
    /// went rather than where it's been.
    @State private var dragFrom: (left: CGFloat, top: CGFloat, width: CGFloat)?

    /// How tall the bar is right now — said by the rows it's holding,
    /// so a drag down can be kept from carrying the bar out of the
    /// window no matter how many rows it grew to on the way.
    @State private var barHeight: CGFloat = 0

    /// What the bar holds: everything but the terminal being watched,
    /// in the order it was said. A session with nowhere to be jumped to
    /// (outside Search's terminals) reads the same as any other — it
    /// just doesn't go anywhere when clicked.
    private var shown: [Island.Session] {
        let watched = Island.watched
        return island.sessions.filter { $0.tty != watched && !island.shelved.contains($0.id) }
    }

    /// The width the bar holds, and the left edge it holds it at —
    /// whatever a drag said, put back inside the room it's in.
    private var width: CGFloat { IslandPlace.width(held, room: room.width) }
    private var left: CGFloat { IslandPlace.left(center: center, width: width, room: room.width) }
    private var top: CGFloat {
        IslandPlace.down(down, room: room.height, bar: barHeight)
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { row, session in
                    if row > 0 { Divider().overlay(Palette.hairline) }
                    one(session)
                }
            }
            .frame(width: width, alignment: .leading)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
            // How tall the bar is, said by the bar: the drag down is
            // clamped against it, and against the room, in IslandPlace.
            .background(
                GeometryReader { room in
                    Color.clear.preference(key: BarHeight.self, value: room.size.height)
                }
            )
            // The two edges, held and stretched: a strip a cursor can
            // find at either end, dragging the near one and leaving the
            // far one where it was, the way a window's edges do.
            .overlay(alignment: .leading) { edge(.leading) }
            .overlay(alignment: .trailing) { edge(.trailing) }
            .padding(.leading, left)
            .padding(.top, top)
            // The whole bar, dragged to a place. A click still goes to
            // the agent (the tap below) and a button still answers —
            // a drag needs to move first, and what hasn't moved isn't
            // one.
            .gesture(move)
            .transition(.opacity)
            // The whole notch rides in and out: a bar that pops up over
            // the page one session at a time is a bar that can't be
            // trusted to hold still while it's read. Its own place and
            // width are not this — a drag says where it is now, not
            // where it settles.
            .animation(Motion.settle, value: island.sessions.count)
            .animation(Motion.settle, value: island.holds.count)
            .onPreferenceChange(BarHeight.self) { barHeight = $0 }
        }
    }

    /// One agent, one row: who it is and where it works, what it's
    /// doing, and — when it has stopped to ask — the say-so it's
    /// waiting on. Clicking the row goes there; the buttons answer
    /// without the trip; the close puts it away.
    private func one(_ session: Island.Session) -> some View {
        HStack(spacing: 8) {
            // The agent, its folder, and what it's doing, as a person
            // would say it: "Claude Code in search is running Bash" —
            // the tool it's on, or the thing it stopped to say, or
            // what it said last. One line of it — the bar is a notch,
            // not a page.
            (title(session)
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
            // Any one of them, put away by hand: read and done with
            // for a done one, kept out of the bar until it says
            // something worth hearing again for the rest — and an ask
            // it was holding open goes back to its own terminal to ask
            // there, the one place it can still be answered.
            closeButton(session)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { island.visit(session) }
    }

    /// One agent's title: who it is, and where it works — "Pi · search",
    /// the folder the last piece of the path the agent said it works
    /// in, the way a person would say it. An agent that said no folder
    /// is just itself; one at the top of the disk, whose folder is the
    /// whole disk, is too.
    private func title(_ session: Island.Session) -> Text {
        let name = Text(Island.name(session.source)).foregroundColor(Palette.ink)
        guard let folder = session.cwd.map({ URL(fileURLWithPath: $0).lastPathComponent }),
              !folder.isEmpty, folder != "/"
        else { return name }
        return name
            + Text(" · ").foregroundColor(Palette.muted)
            + Text(folder).foregroundColor(Palette.ink)
    }

    /// The whole bar, dragged to a place: the drag says where its left
    /// edge went and how far down it went, and the say-so is kept as
    /// the center and the top it is — put back through IslandPlace on
    /// the way in, so the bar can never be dragged out of the window
    /// it's over, whatever happens to the window later.
    private var move: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                if dragFrom == nil { dragFrom = (left, top, width) }
                guard let from = dragFrom else { return }
                let went = min(
                    max(from.left + drag.translation.width, 14),
                    max(14, room.width - from.width - 14)
                )
                center = IslandPlace.center(left: went, width: from.width, room: room.width)
                down = IslandPlace.down(
                    from.top + drag.translation.height, room: room.height, bar: barHeight
                )
            }
            .onEnded { _ in dragFrom = nil }
    }

    /// One edge of the bar, held and stretched. Dragging the left edge
    /// stretches the bar from its right end, the right edge from its
    /// left — the far end stays put, the way a window's does — and
    /// neither says anything the room can't hold.
    private func edge(_ side: Edge) -> some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { over in
                if over { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { drag in
                        if dragFrom == nil { dragFrom = (left, top, width) }
                        guard let from = dragFrom else { return }
                        let said = side == .leading
                            ? from.width - drag.translation.width
                            : from.width + drag.translation.width
                        let went = IslandPlace.width(said, room: room.width)
                        let put = side == .leading ? from.left + (from.width - went) : from.left
                        held = went
                        center = IslandPlace.center(left: put, width: went, room: room.width)
                    }
                    .onEnded { _ in dragFrom = nil }
            )
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

    /// The close, as an × the size of a word: a click puts the row
    /// away, whatever it's doing — Island.putAway keeps the rest.
    private func closeButton(_ session: Island.Session) -> some View {
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
