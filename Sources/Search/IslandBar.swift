import SwiftUI

// The island's bar: what the agents are doing, floating over the top of
// every tab — a notch, above the strip, a thing to be glanced at rather
// than gone to. An agent in the terminal you're watching isn't in it:
// the bar would say what the screen in front of you says better. An
// agent that has stopped to ask is answered right here — allowed,
// denied, or left to ask in its own terminal — without leaving the tab
// you're on. Clicking anything else about one goes to it: the window,
// the tab, the pane.
//
// It is a stack of cards rather than a list of rows: the newest news on
// top, the older ones peeking out beneath it, and the whole stack
// opening where it stands when a cursor comes to it. One agent is one
// card, said over as the agent says more of itself — a run's tools are
// one line of work, not one line each — so a long run never fills the
// notch with its own noise. Each card is named by who it is and where
// it works — the folder, as a person would say it — and the bar itself
// is dragged to where it's wanted (along the top, and down from it) and
// stretched as wide as it's read. Every card is closed by hand — put
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

    /// How many cards the bar holds while it's closed: the newest one
    /// whole, and the couple under it that peek. Enough to say there is
    /// more without becoming a list to read from across the room.
    static let stack = 3
    /// How much of a card shows when it is only peeking: enough for the
    /// name and the tool it's on, not the words it said.
    static let peek: CGFloat = 22
    /// The tallest the open bar grows to before it scrolls: the room
    /// it's in overrules this, always.
    static let openMost: CGFloat = 420
    /// The air between cards once the stack is open. Closed, they're
    /// tucked one under the next with none — a stack is cards against
    /// each other, not a list with gaps in it.
    static let gap: CGFloat = 6
    /// The breath inside a card, above and below what it says.
    static let pad: CGFloat = 8
    /// The height of a card's own line — who it is and what it's doing.
    /// Pinned rather than left to the font, because the stack's height
    /// is arithmetic on a card (below), and arithmetic needs a card
    /// that is the height it says it is.
    static let line: CGFloat = 16
    /// The height of what a card says under that line: two lines of it,
    /// pinned for the same reason. A card says either its line alone or
    /// its line and this.
    static let words: CGFloat = 28

    /// How tall a card stands: its breath, its own line, and the two
    /// lines of what it said when it has anything to say under it.
    static func card(_ hasWords: Bool) -> CGFloat {
        pad * 2 + line + (hasWords ? gap + words : 0)
    }

    /// How tall a card stands, for the session it's drawn from: the rule
    /// of what a card says under its own line lives here rather than in
    /// the view, so the stack's arithmetic and the cards themselves are
    /// the same answer — the bar is exactly as tall as what it holds,
    /// and the drawing can't drift from the sum without a test failing.
    static func card(_ session: Island.Session) -> CGFloat {
        card(under(session) != nil)
    }

    /// What a card says under its own line: the words an agent said,
    /// where the line above isn't already saying them. A working one
    /// with a tool up there has room below for what it said of itself;
    /// a waiting or done one is saying its words in that very line, and
    /// saying them twice on one card is a card that looks broken.
    static func under(_ session: Island.Session) -> String? {
        guard let words = session.words, !words.isEmpty else { return nil }
        switch session.part {
        case .asking, .working: return session.tool == nil ? nil : words
        case .waiting, .done: return nil
        }
    }

    /// How tall the open stack stands: every card whole, the air
    /// between them, and no taller than the room's own say — past that
    /// it scrolls, an open bar being a list, and a list may be long but
    /// it may not be the window.
    static func opened(_ cards: [CGFloat], room: CGFloat) -> CGFloat {
        let whole = cards.reduce(0, +) + gap * CGFloat(max(0, cards.count - 1))
        return min(whole, open(room))
    }

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

    // MARK: The stack

    /// How many cards the bar holds while it's closed: the newest, and
    /// the couple under it that peek. A person watching is watching the
    /// top of the stack; the rest is there to be reached for, not read
    /// from across the room.
    static func showing(_ all: Int) -> Int { min(max(all, 0), IslandPlace.stack) }

    /// How tall the stack stands closed, given how tall one card is:
    /// the newest whole, and a sliver (IslandPlace.peek) of each one under
    /// it. A card is the unit because the peeking ones are held to the
    /// sliver — the top one is the only one saying all of itself.
    static func closed(_ card: CGFloat, all: Int) -> CGFloat {
        card + CGFloat(showing(all) - 1) * IslandPlace.peek
    }

    /// The tallest the open stack is allowed to stand: the whole of the
    /// room's height bar a breath over it, and never more than the bar
    /// itself is willing to grow to — past that it scrolls, an open bar
    /// being a list, and a list may be long but it may not be the
    /// window.
    static func open(_ room: CGFloat) -> CGFloat {
        max(IslandPlace.peek, min(IslandPlace.openMost, room - 80))
    }
}

/// One notch over everything, every tab's: the sessions not already
/// watched (the front window's own tab, the pane that holds the keys),
/// each as a card — the newest on top — with what it's doing and, when
/// it has stopped to ask, the answer to give it. The stack opens where
/// it stands under a cursor and closes when the cursor leaves it.
struct IslandBar: View {
    /// The room the bar sits in: the window, given by the one who knows
    /// it (the overlay's GeometryReader, in App) — its width for the
    /// place along the top and the width of the bar, its height for how
    /// far down the bar can be dragged and how tall it may open.
    let room: CGSize

    /// Whether the stack is open, for a caller that knows better than a
    /// cursor does: a bar drawn with no pointer in it at all — the
    /// tests that hold the shape of the stack, one card and a sliver of
    /// the rest against every card whole. Nil, the ordinary case, is
    /// the cursor's to say.
    var opened: Bool? = nil

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
    @AppStorage("island.width") private var wide = 360.0
    @AppStorage("island.down") private var down = 0.0

    /// Where the drag started, taken on its first word: the left edge,
    /// the top, and the width as they stood, so the drag says where it
    /// went rather than where it's been.
    @State private var dragFrom: (left: CGFloat, top: CGFloat, width: CGFloat)?

    /// Whether a cursor is on the stack: open while it is, closed while
    /// it isn't. Kept here rather than in the cards, since the whole
    /// stack opens as one thing — reaching for the card at the bottom
    /// must not close the stack on the way down to it.
    @State private var cursor = false

    /// Whether the stack stands open: what a cursor says, unless the
    /// one who drew the bar said otherwise (see `opened`).
    private var over: Bool { opened ?? cursor }

    /// What the bar holds: everything but the terminal being watched,
    /// newest first. The island keeps that order (Island.order) — it's
    /// the order things were said in, and a card goes back to the top of
    /// it whenever its agent says anything — so a card is never in a
    /// place a person has to go looking for. A session with nowhere to
    /// be jumped to (outside Search's terminals) reads the same as any
    /// other; it just doesn't go anywhere when clicked.
    private var held: [Island.Session] {
        let watched = Island.watched
        let all = island.sessions.filter { $0.tty != watched && !island.shelved.contains($0.id) }
        // Newest first by what the island says — and anything it hasn't
        // placed yet (a session the island took in before the bar was
        // drawn) by when it last spoke, so the order is always a real
        // one and never arbitrary.
        let rank = Dictionary(island.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { one, _ in one })
        return all.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (one?, two?): return one < two
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.at > b.at
            }
        }
    }

    /// What's drawn: the top of the stack while it's closed, all of it
    /// while it's open.
    private var shown: [Island.Session] {
        over ? held : Array(held.prefix(IslandPlace.showing(held.count)))
    }

    /// How tall each card stands, top first: the card's own arithmetic
    /// (IslandPlace.card) over what each of them has to say — which is
    /// the same thing the cards themselves are pinned to, so the bar is
    /// exactly as tall as what it holds.
    private var heights: [CGFloat] {
        shown.map(IslandPlace.card)
    }

    /// How tall the bar stands: the closed stack's arithmetic while it's
    /// closed — the top card whole and a sliver of each one under it —
    /// and the cards' own heights while it's open, up to the room's own
    /// say. That number is what a drag down is kept inside of, and what
    /// decides whether the open stack has anything to scroll: a bar no
    /// taller than its cards swallows no clicks meant for the page.
    private var barHeight: CGFloat {
        guard over else {
            let top = shown.first.map(IslandPlace.card) ?? 0
            return IslandPlace.closed(top, all: held.count)
        }
        return IslandPlace.opened(heights, room: room.height)
    }

    /// The width the bar holds, and the left edge it holds it at —
    /// whatever a drag said, put back inside the room it's in.
    private var width: CGFloat { IslandPlace.width(wide, room: room.width) }
    private var left: CGFloat { IslandPlace.left(center: center, width: width, room: room.width) }
    private var top: CGFloat {
        IslandPlace.down(down, room: room.height, bar: barHeight)
    }

    var body: some View {
        if !held.isEmpty {
            ScrollView(.vertical) {
                // Newest first, and in a VStack that's the top: the card
                // at the top of the stack is the last thing heard, and
                // the ones under it go back in time. Only the first is
                // whole while the stack is closed; the rest peek.
                VStack(spacing: over ? IslandPlace.gap : 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { place, session in
                        card(session, peeking: !over && place > 0)
                    }
                }
                .frame(width: width)
            }
            .scrollDisabled(!over)
            .scrollIndicators(.hidden)
            .frame(width: width, height: barHeight, alignment: .top)
            // A cursor on the stack opens it, a cursor off it closes it:
            // the whole bar is the target, so coming off the bottom card
            // doesn't close it on the way to something else, and going to
            // it from anywhere on the page opens it on arrival.
            .onHover { inside in
                withAnimation(Motion.settle) { cursor = inside }
            }
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
            .animation(Motion.settle, value: held.count)
            .animation(Motion.settle, value: island.holds.count)
        }
    }

    /// One agent, one card: who it is and where it works, what it's
    /// doing, and — when it has stopped to ask — the say-so it's waiting
    /// on. Clicking the card goes there; the buttons answer without the
    /// trip; the close puts it away. A card that is only peeking says
    /// the first line of itself and nothing else.
    private func card(_ session: Island.Session, peeking: Bool) -> some View {
        VStack(alignment: .leading, spacing: IslandPlace.gap) {
            HStack(spacing: 8) {
                // The agent, its folder, and what it's doing, as a person
                // would say it: "Claude Code in search is running Bash" —
                // the tool it's on, or the thing it stopped to say, or
                // what it said last. One line of it — the card is a
                // notch, not a page.
                (title(session)
                    + Text(partName(session.part)).foregroundColor(Palette.muted)
                    + Text(detail(session)).foregroundColor(Palette.ink))
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The height the stack's arithmetic counts on (see
                    // IslandPlace.line), said here so the two agree.
                    .frame(height: IslandPlace.line, alignment: .leading)

                Spacer(minLength: 4)

                // The asking one's answer: given here, the agent goes on
                // without anyone going to it. A session asking in its own
                // terminal (answered "ask there") has no buttons — its
                // own asking is the asking now. Only on a card that is
                // saying all of itself: a peek has no room for a button,
                // and the cursor that would reach one opens the stack
                // first.
                if !peeking, session.part == .asking, let hold = hold(session) {
                    answerButton("Allow", Palette.safe, filled: true) { island.answer(hold, .allow) }
                    answerButton("Deny", Palette.unsafe, filled: false) { island.answer(hold, .deny) }
                    answerButton("Ask there", Palette.muted, filled: false) { island.answer(hold, .ownTerminal) }
                }
                // Any one of them, put away by hand: read and done with
                // for a done one, kept out of the bar until it says
                // something worth hearing again for the rest — and an ask
                // it was holding open goes back to its own terminal to ask
                // there, the one place it can still be answered.
                if !peeking { closeButton(session) }
            }
            // What it said, under the line above rather than beside it:
            // the words get the card's whole width and are cut by it. A
            // reply is the point of a card, and half a reply beside a
            // tool's name is no reply at all. Not while peeking — a peek
            // is a name and a tool, not a paragraph.
            if !peeking, let words = IslandPlace.under(session) {
                Text(words)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Two lines of it, and the same two lines the stack
                    // counts on (IslandPlace.words): a card is the height
                    // the arithmetic says it is, whether it had a word to
                    // wrap or not.
                    .frame(height: IslandPlace.words, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, IslandPlace.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
        .contentShape(Rectangle())
        .onTapGesture { island.visit(session) }
        // A peek is the top of the card and no more: the rest is still
        // there, under the card above it, waiting for the stack to open.
        .frame(height: peeking ? IslandPlace.peek : nil, alignment: .top)
        .clipped()
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
                        wide = went
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

    /// The close, as an × the size of a word: a click puts the card
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
