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
// It is a deck of cards rather than a list of rows: the newest news is
// the card facing you, at the front of the pile, and the ones behind it
// are lifted above it and tipped back into the screen — a real
// projection, one vanishing point, so a glance says there is a pile
// here and how deep it is. Hovering straightens the whole thing into a
// list where every card is read square on. One agent is one card, said
// over as the agent says more of itself — a run's tools are one line of
// work, not one line each — so a long run never fills the notch with
// its own noise. Each card is named by who it is and where it works —
// the folder, as a person would say it — and the bar itself is dragged
// to where it's wanted (along the top, and down from it) and stretched
// as wide as it's read. Every card is closed by hand — put away until
// it says something worth hearing again — holding all three of those
// (IslandPlace, and Island.putAway).

/// Where the bar sits and how wide it is, kept as fractions and edges
/// a drag can say: the math of it, here so it can be held to (and
/// tested) without a window in the way.
enum IslandPlace {
    /// The narrowest the bar is dragged down to, and the widest it's
    /// stretched to. The room it's in overrules the widest, never the
    /// narrowest — a bar narrower than this isn't one anybody reads.
    static let leastWidth: CGFloat = 220
    static let mostWidth: CGFloat = 720

    /// The deepest the pile is drawn: the front card and the couple
    /// behind it that show. Enough to say there is more without
    /// becoming a list to read from across the room.
    static let stack = 3
    /// How much of a card shows when it is behind the front one: enough
    /// for the name and the tool it's on, not the words it said.
    static let peek: CGFloat = 22
    /// The tallest the open bar grows to before it scrolls: the room
    /// it's in overrules this, always.
    static let openMost: CGFloat = 420
    /// The air between cards once the pile is straightened. Piled,
    /// they're tucked one behind the next with none — a deck is cards
    /// against each other, not a list with gaps in it.
    static let gap: CGFloat = 6
    /// How much smaller each card behind the front one is drawn: a
    /// pile leans away, and a thing further off is a thing smaller.
    /// Never enough to make a card nothing — the pile is three deep.
    static let shrink: CGFloat = 0.055
    /// How much dimmer each one behind is: depth said in light as well
    /// as in size, which is what makes a pile read as a pile from
    /// across the room.
    static let dim: Double = 0.16
    /// How far back each card behind the front one tips, in degrees,
    /// about its own bottom edge — the lean that turns a row of cards
    /// into a pile of them. The front one never tips: it is the news,
    /// and news is read square on.
    static let lean: Double = 15
    /// How hard that lean is projected: what SwiftUI is told the eye's
    /// distance is, larger being nearer and the recede harder. Kept
    /// mild, so a card two deep is still read as a card rather than as
    /// a sliver of one.
    static let perspective: CGFloat = 0.55
    /// The breath inside a card, above and below what it says.
    static let pad: CGFloat = 8
    /// How tall a card's own line stands — who it is and what it's
    /// doing. Pinned rather than left to the font, because the pile's
    /// height is arithmetic on a card (below), and arithmetic needs a
    /// card that is the height it says it is.
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
    /// the view, so the pile's arithmetic and the cards themselves are
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

    /// How tall the straightened bar stands, before the room has its
    /// say: every card whole with the air between them.
    static func stood(_ cards: [CGFloat]) -> CGFloat {
        cards.reduce(0, +) + gap * CGFloat(max(0, cards.count - 1))
    }

    /// How tall the straightened bar stands: every card whole, the air
    /// between them, and no taller than the room's own say — past that
    /// it scrolls, a straightened bar being a list, and a list may be
    /// long but it may not be the window.
    static func opened(_ cards: [CGFloat], room: CGFloat) -> CGFloat {
        min(stood(cards), open(room))
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

    // MARK: The pile

    /// How many cards the pile draws while it's piled: the front one and
    /// the couple behind it that show. A person watching is watching the
    /// front of the pile; the rest is there to be reached for, not read
    /// from across the room.
    static func showing(_ all: Int) -> Int { min(max(all, 0), IslandPlace.stack) }

    /// How tall the pile stands closed, given how tall each card is:
    /// the tallest of the ones on show, and a sliver (IslandPlace.peek)
    /// of each one behind it. The tallest, not the front one: the cards
    /// behind are only slivers, but a sliver of a card that says more
    /// than the front one says is still drawn above it, and the bar has
    /// to hold what it draws.
    static func closed(_ cards: [CGFloat]) -> CGFloat {
        let deep = showing(cards.count)
        let tall = cards.prefix(deep).max() ?? 0
        return tall + CGFloat(deep - 1) * peek
    }

    /// What one card of the pile is drawn as, level 0 being the front —
    /// the newest news, drawn square on and whole. The rest of it is
    /// the pile's own rule, here rather than in the view so the shape
    /// can be held to without a window in the way.
    struct Deck {
        /// How much smaller it's drawn than the card in front of it.
        var scale: CGFloat
        /// How far it tips back about its own bottom edge, in degrees.
        var lean: Double
        /// How much of itself it keeps, in light.
        var light: Double
    }

    /// The pile's rule: what a card at a level is drawn as. Each one
    /// behind the front is a little smaller, a little dimmer and a
    /// little further back than the one before it — a deck read as a
    /// deck rather than a row of cards pretending to be far away. The
    /// floors are only there so a pile grown past what it's meant to be
    /// stays visible instead of vanishing.
    static func deck(_ level: Int) -> Deck {
        let behind = CGFloat(max(0, level))
        return Deck(
            scale: max(0.6, 1 - shrink * behind),
            lean: lean * Double(behind),
            light: max(0.35, 1 - dim * Double(behind))
        )
    }

    /// Where each card's top edge sits, closed: a peek apart, the
    /// newest at the front of the pile — which is the bottom of it,
    /// the pile receding up and back behind it. Index 0 is the newest.
    static func piled(_ cards: [CGFloat]) -> [CGFloat] {
        cards.indices.map { peek * CGFloat(cards.count - 1 - $0) }
    }

    /// Where each card's top edge sits, straightened: a whole card and
    /// the air between apart, oldest first — so the newest is still the
    /// last of them and straightening the pile moves no card past
    /// another. The order the pile is read in is the order the list is
    /// read in; only the depth goes.
    static func laid(_ cards: [CGFloat]) -> [CGFloat] {
        var out = [CGFloat](repeating: 0, count: cards.count)
        var down: CGFloat = 0
        for place in stride(from: cards.count - 1, through: 0, by: -1) {
            out[place] = down
            down += cards[place] + gap
        }
        return out
    }

    /// The tallest the straightened bar is allowed to stand: the whole
    /// of the room's height bar a breath over it, and never more than
    /// the bar itself is willing to grow to — past that it scrolls, a
    /// straightened bar being a list, and a list may be long but it may
    /// not be the window.
    static func open(_ room: CGFloat) -> CGFloat {
        max(IslandPlace.peek, min(IslandPlace.openMost, room - 80))
    }
}

/// One notch over everything, every tab's: the sessions not already
/// watched (the front window's own tab, the pane that holds the keys),
/// each as a card — the newest at the front of the pile — with what
/// it's doing and, when it has stopped to ask, the answer to give it.
/// The pile straightens where it stands under a cursor and closes when
/// the cursor leaves it.
struct IslandBar: View {
    /// The room the bar sits in: the window, given by the one who knows
    /// it (the overlay's GeometryReader, in App) — its width for the
    /// place along the top and the width of the bar, its height for how
    /// far down the bar can be dragged and how tall it may open.
    let room: CGSize

    /// Whether the pile is straightened, for a caller that knows better
    /// than a cursor does: a bar drawn with no pointer in it at all —
    /// the tests that hold the shape of the pile, the front card and a
    /// slice of the rest against every card whole. Nil, the ordinary
    /// case, is the cursor's to say.
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

    /// Whether a cursor is on the pile: straightened while it is, piled
    /// while it isn't. Kept here rather than in the cards, since the
    /// whole pile moves as one thing — reaching for the card at the
    /// back must not close it on the way in.
    @State private var cursor = false

    /// Whether the pile stands straightened: what a cursor says, unless
    /// the one who drew the bar said otherwise (see `opened`).
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

    /// What's drawn: the top of the pile while it's piled, all of it
    /// while it's straightened.
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

    /// How tall the bar stands: the pile's own arithmetic while it's
    /// piled — the front card whole and a slice of each one behind it —
    /// and the cards' own heights while it's straightened, up to the
    /// room's own say. That number is what a drag down is kept inside
    /// of, and what decides whether the open pile has anything to
    /// scroll: a bar no taller than its cards swallows no clicks meant
    /// for the page.
    private var barHeight: CGFloat {
        over ? IslandPlace.opened(heights, room: room.height) : IslandPlace.closed(heights)
    }

    /// How tall the pile's own drawing is, whether that's the depth of
    /// the pile or the whole length of the straightened list. Taller
    /// than the bar only when the list is longer than the room allows —
    /// which is the case the bar scrolls in.
    private var pileHeight: CGFloat {
        over ? IslandPlace.stood(heights) : IslandPlace.closed(heights)
    }

    /// Where each card's top edge sits: a slice apart and receding up
    /// into the screen while the pile is piled, a whole card and the
    /// air between apart once it's straightened. The two are the same
    /// order — the newest last in the list and nearest in the pile — so
    /// straightening moves no card past another.
    private var tops: [CGFloat] {
        over ? IslandPlace.laid(heights) : IslandPlace.piled(heights)
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
                // A pile rather than a list: the newest card is the one
                // facing you, at the front of it, and each one behind is
                // lifted a slice higher and tipped back into the screen.
                // The cards are placed by hand (IslandPlace.piled, .laid)
                // because a pile's cards overlap — the ones behind are
                // mostly covered, and a place in the pile is a depth
                // rather than a row — so they're drawn one on top of the
                // next in a ZStack instead of laid out in a line.
                ZStack(alignment: .topLeading) {
                    // Deepest first, so the front card is drawn last and
                    // over the rest: in a pile the newest news is the
                    // one nothing is covering.
                    ForEach(Array(shown.enumerated()).reversed(), id: \.element.id) { place, session in
                        card(session, level: place)
                            .offset(y: tops[place])
                            // A card arriving comes from in front of the
                            // pile, which is where the newest news comes
                            // from; one leaving goes back into it. The
                            // cards that stay are pushed a place further
                            // back by the offsets above, and those move.
                            .transition(
                                .opacity.combined(with: .scale(scale: 1.06, anchor: .bottom))
                            )
                    }
                }
                .frame(width: width, height: pileHeight, alignment: .topLeading)
            }
            .scrollDisabled(!over)
            .scrollIndicators(.hidden)
            .frame(width: width, height: barHeight, alignment: .top)
            // A cursor on the pile straightens it, a cursor off it piles
            // it again: the whole bar is the target, so coming off the
            // front card doesn't close it on the way to something else,
            // and going to it from anywhere on the page straightens it on
            // arrival.
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
            // The pile says where a card is, so a card that changes
            // place — a new one on top, the rest pushed back — is
            // followed there rather than jumping: the news is a
            // sequence, and a sequence is read by seeing it move.
            .animation(Motion.settle, value: shown.map(\.id))
        }
    }

    /// One agent, one card: who it is and where it works, what it's
    /// doing, and — when it has stopped to ask — the say-so it's waiting
    /// on. Clicking the card goes there; the buttons answer without the
    /// trip; the close puts it away.
    ///
    /// `level` is how deep in the pile it is, 0 being the front. A card
    /// behind the front one is drawn the way IslandPlace.deck says a
    /// card that deep is drawn — smaller, dimmer, tipped back about its
    /// own bottom edge — and shows only its own first slice, the rest
    /// being behind the card in front of it. Once the pile is
    /// straightened every card is level 0 and whole, which is what
    /// opening it is for.
    private func card(_ session: Island.Session, level: Int) -> some View {
        let deck = IslandPlace.deck(over ? 0 : level)
        let buried = !over && level > 0
        return VStack(alignment: .leading, spacing: IslandPlace.gap) {
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
                    // The height the pile's arithmetic counts on (see
                    // IslandPlace.line), said here so the two agree.
                    .frame(height: IslandPlace.line, alignment: .leading)

                Spacer(minLength: 4)

                // The asking one's answer: given here, the agent goes on
                // without anyone going to it. A session asking in its own
                // terminal (answered "ask there") has no buttons — its
                // own asking is the asking now. Only on the front card:
                // a card buried in the pile has no room for a button,
                // and the cursor that would reach one straightens the
                // pile first.
                if !buried, session.part == .asking, let hold = hold(session) {
                    answerButton("Allow", Palette.safe, filled: true) { island.answer(hold, .allow) }
                    answerButton("Deny", Palette.unsafe, filled: false) { island.answer(hold, .deny) }
                    answerButton("Ask there", Palette.muted, filled: false) { island.answer(hold, .ownTerminal) }
                }
                // Any one of them, put away by hand: read and done with
                // for a done one, kept out of the bar until it says
                // something worth hearing again for the rest — and an ask
                // it was holding open goes back to its own terminal to ask
                // there, the one place it can still be answered.
                if !buried { closeButton(session) }
            }
            // What it said, under the line above rather than beside it:
            // the words get the card's whole width and are cut by it. A
            // reply is the point of a card, and half a reply beside a
            // tool's name is no reply at all. Not on a card buried in
            // the pile — a slice is a name and a tool, not a paragraph.
            if !buried, let words = IslandPlace.under(session) {
                Text(words)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Two lines of it, and the same two lines the pile
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
        // The pile's depth, said three ways at once, because one of them
        // alone reads as a bug rather than as distance: a card behind is
        // smaller, and dimmer, and tipped back about its own bottom edge
        // so it leans away into the screen. The slice is cut first — a
        // buried card shows its own first line and no more — and the
        // size and the lean are applied to that slice, so a card's place
        // in the pile is the slice it shows and not the card it hides.
        // Straightened, every one of these is the identity, which is
        // what a deck with its depth taken away is: a list.
        .frame(height: buried ? IslandPlace.peek : nil, alignment: .top)
        .clipped()
        .scaleEffect(deck.scale, anchor: .top)
        .rotation3DEffect(
            .degrees(deck.lean), axis: (x: 1, y: 0, z: 0),
            anchor: .bottom, perspective: IslandPlace.perspective
        )
        .brightness(deck.light - 1)
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
