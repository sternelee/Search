import AppKit
import Combine

// One terminal tab holding several terminals: the arrangement itself, as
// arithmetic and nothing else. A split right and a split down of what that
// made, a divider dragged, a pane closed and the layout closing over the
// gap — all of it is decided here, on a tree of panes, before any view
// knows anything about it.
//
// The shape is a binary tree, as it is in tmux and in MetalTerm: a pane,
// or a split with an axis and the share its first side takes. Splitting a
// pane turns the leaf into a split holding it and a new pane beside it;
// closing a pane splices the other side into the split's own place, so a
// room of three never keeps a split of one. What the tree is stored as is
// an arena — an array of nodes, children by index — because collapsing a
// split is then one node being copied over another, and comparing two
// arrangements is comparing two arrays.
//
// Nothing here touches a view, a screen or a shell. Which view sits in
// which pane, who holds the keyboard, and what a divider looks like are
// the container's, written below it in this file; the geometry is here,
// and geometry is what a test can pin without a window.

/// Which way a split divides the room. The words are ambiguous everywhere
/// they are used, so they are pinned here once: `horizontal` is panes side
/// by side, sharing the width — what ⌘D makes, a left pane and a right one
/// with a divider running down between them. `vertical` is panes one above
/// the other, sharing the height — what ⇧⌘D makes, with a divider across.
enum TerminalAxis {
    case horizontal
    case vertical
}

/// A direction across the arrangement, as the four arrow keys name them.
/// Coordinates here are the terminal's own — y grows down, the way rows
/// do — so up is the smaller y and down the larger, whichever way the
/// view showing this tree is flipped.
enum TerminalDirection {
    case left, right, up, down

    /// The axis of the splits whose dividers a step in this direction
    /// crosses.
    var axis: TerminalAxis {
        self == .left || self == .right ? .horizontal : .vertical
    }
}

/// The arrangement of panes in one terminal tab.
struct TerminalTree: Equatable {
    /// One node of the tree. A leaf is a pane, named by the id the
    /// container knows its terminal by; a split is an axis, two children
    /// by index into `nodes`, and the share of the room the first child
    /// takes — a half when it was made, whatever it was dragged to since.
    enum Node: Equatable {
        case pane(Int)
        case split(axis: TerminalAxis, first: Int, second: Int, fraction: Double)
    }

    private(set) var nodes: [Node]
    private(set) var root: Int
    /// The id the next pane made is given. Ids only grow, so a pane that
    /// closes is never confused with one made after it.
    private(set) var next: Int

    /// An arrangement of one pane, which is what a terminal tab is before
    /// anyone splits it.
    init(pane: Int = 0) {
        nodes = [.pane(pane)]
        root = 0
        next = pane + 1
    }

    /// Every pane in the arrangement, in the order the room shows them:
    /// left to right, then top to bottom.
    var panes: [Int] { leaves(under: root) }
    var count: Int { panes.count }

    /// The share the first side of a split takes, for whoever needs to
    /// move it a little rather than set it outright.
    func fraction(of split: Int) -> Double? {
        guard case .split(_, _, _, let fraction) = nodes[split] else { return nil }
        return fraction
    }

    // MARK: - changing the arrangement

    /// Splits a pane in two along an axis: the pane keeps its side of the
    /// room — the left or the top, unless `before` — and a new pane takes
    /// the other, half each. The pane made is returned, and it is the
    /// caller's to give the keyboard to; nil when the pane is not one this
    /// arrangement holds any more.
    ///
    /// Splitting the pane that made is how the tree grows depth rather
    /// than width: split right, then split what appeared on the right
    /// down, and the room is an L — the arrangement does not flatten
    /// itself into a grid, because the user never asked for one.
    @discardableResult
    mutating func split(_ pane: Int, across axis: TerminalAxis, before: Bool = false) -> Int? {
        guard let at = liveSlot(of: pane) else { return nil }
        let fresh = next
        next += 1
        // The leaf's slot in the arena becomes the split — the parent's
        // index into it stays right — and the pane itself moves to a fresh
        // node, because its old slot is spoken for.
        nodes.append(.pane(fresh))
        let freshNode = nodes.count - 1
        nodes.append(.pane(pane))
        let movedNode = nodes.count - 1
        nodes[at] = .split(
            axis: axis,
            first: before ? freshNode : movedNode,
            second: before ? movedNode : freshNode,
            fraction: 0.5
        )
        return fresh
    }

    /// Closes a pane, and the split that held it with it: the other side
    /// is spliced into the split's own place, taking its room. Returns the
    /// pane that takes the room over — the first leaf of what survived —
    /// or nil when there was nothing but this pane and the caller should
    /// be closing the tab instead.
    @discardableResult
    mutating func remove(_ pane: Int) -> Int? {
        guard let at = liveSlot(of: pane), let holder = parent(of: at) else { return nil }
        guard case .split(_, let first, let second, _) = nodes[holder] else { return nil }
        let kept = at == first ? second : first
        // Read the survivor before the slot it is copied from is emptied.
        let survivor = firstPane(under: kept)
        nodes[holder] = nodes[kept]
        // The slot that was copied from is emptied with a pane that is
        // gone, so that nothing searching the arena can find anything in
        // it: the live tree is reached from the root, but a search by pane
        // walks the array, and a leftover copy would shadow the real one.
        nodes[kept] = .pane(-1)
        return survivor
    }

    /// The share a split can take of this much room, held where neither
    /// side falls under the least a pane can be: a divider cannot be
    /// dragged past a pane it would leave too small to be a terminal.
    /// Nil when the room cannot honour either minimum — a split this
    /// small cannot be made, only inherited from a window that shrank,
    /// and the layout shows what it can.
    private func clamped(_ fraction: Double, axis: TerminalAxis, shared: CGFloat, minimum: CGSize) -> Double? {
        let least = axis == .horizontal ? minimum.width : minimum.height
        guard shared >= least * 2 else { return nil }
        let low = Double(least / shared)
        return min(max(fraction, low), 1 - low)
    }

    /// Sets the share the first side of a split takes, clamped so neither
    /// side falls under the minimum (see `clamped`). `room` is the whole
    /// length the split divides; the gutter between the sides is taken off
    /// before the share of either is counted.
    mutating func setFraction(_ fraction: Double, of split: Int, room: CGFloat, gutter: CGFloat, minimum: CGSize) {
        guard case .split(let axis, let first, let second, _) = nodes[split],
              let share = clamped(fraction, axis: axis, shared: room - gutter, minimum: minimum) else { return }
        nodes[split] = .split(axis: axis, first: first, second: second, fraction: share)
    }

    /// Every split takes the even share of its leaves: halves for two
    /// panes, thirds where one side of a split holds two and the other
    /// one. That is the rule tmux means by "even", and it is what keeps a
    /// third pane from being squeezed by a halving that no longer
    /// describes the tree.
    mutating func equalize() {
        equalize(under: root)
    }

    // MARK: - where everything is

    /// The arrangement laid out in a room: panes by id, the gutter each
    /// split leaves between its sides, and the room each split divides —
    /// which is what a drag or a nudge of that split's divider works
    /// against.
    struct Placement {
        var panes: [Int: CGRect] = [:]
        var dividers: [(node: Int, axis: TerminalAxis, frame: CGRect)] = []
        var rooms: [Int: CGRect] = [:]
    }

    /// Where everything is in the given room. A fraction set in a larger
    /// room is clamped to the minimums of this one rather than refused:
    /// the tree keeps what was dragged, and the room decides how much of
    /// it can be shown.
    func placement(in rect: CGRect, gutter: CGFloat, minimum: CGSize) -> Placement {
        var made = Placement()
        place(root, in: rect, into: &made, gutter: gutter, minimum: minimum)
        return made
    }

    /// The pane next to this one in a direction: the nearest whose edge is
    /// in that direction and whose span crosses this pane's own. The
    /// crossing is what makes it the pane under the arrow rather than
    /// merely the nearest one anywhere — an L has no pane below its tall
    /// side, only beside it. The walk follows reading order — left to
    /// right, then top to bottom — rather than the dictionary, so that a
    /// tie in distance is the pane on the earlier row: an arrow right from
    /// the tall side of an L lands on the pane above, not on whichever the
    /// dictionary offered first.
    func neighbour(of pane: Int, toward direction: TerminalDirection, in placed: Placement) -> Int? {
        guard let mine = placed.panes[pane] else { return nil }
        var best: (id: Int, gap: CGFloat)?
        for other in panes where other != pane {
            guard let rect = placed.panes[other],
                  let gap = gap(of: rect, awayFrom: mine, toward: direction) else { continue }
            if best == nil || gap < best!.gap { best = (other, gap) }
        }
        return best?.id
    }

    /// The split whose divider is the one to move when this pane is nudged
    /// in a direction: the nearest divider of that axis whose length
    /// crosses the pane. In a nested arrangement that is the ancestor
    /// whose edge the pane sits against, not any deeper split — the bottom
    /// pane of an L is nudged left by the divider that spans the whole
    /// height, not the one that only divides the right side.
    func divider(of pane: Int, toward direction: TerminalDirection, in placed: Placement) -> Int? {
        guard let mine = placed.panes[pane] else { return nil }
        var best: (node: Int, gap: CGFloat)?
        for line in placed.dividers where line.axis == direction.axis {
            let strip = line.frame
            guard let gap = gap(of: strip, awayFrom: mine, toward: direction) else { continue }
            if best == nil || gap < best!.gap { best = (line.node, gap) }
        }
        return best?.node
    }

    // MARK: - the arithmetic

    /// Whether a rect — a pane, or a divider's gutter strip, which along
    /// its own axis is a line — lies wholly in a direction of another, and
    /// how far: nil when it does not, or when their spans along the other
    /// axis do not cross, which is the difference between "next to" and
    /// merely "nearby".
    private func gap(of other: CGRect, awayFrom mine: CGRect, toward direction: TerminalDirection) -> CGFloat? {
        let slop: CGFloat = 0.5
        switch direction {
        case .right:
            guard other.minX >= mine.maxX - slop, crosses(other.verticalSpan, mine.verticalSpan) else { return nil }
            return other.minX - mine.maxX
        case .left:
            guard other.maxX <= mine.minX + slop, crosses(other.verticalSpan, mine.verticalSpan) else { return nil }
            return mine.minX - other.maxX
        case .down:
            guard other.minY >= mine.maxY - slop, crosses(other.horizontalSpan, mine.horizontalSpan) else { return nil }
            return other.minY - mine.maxY
        case .up:
            guard other.maxY <= mine.minY + slop, crosses(other.horizontalSpan, mine.horizontalSpan) else { return nil }
            return mine.minY - other.maxY
        }
    }

    /// Whether two spans share more than an edge.
    private func crosses(_ one: (min: CGFloat, max: CGFloat), _ two: (min: CGFloat, max: CGFloat)) -> Bool {
        min(one.max, two.max) - max(one.min, two.min) > 0.5
    }

    /// Places a node in a rect: a pane takes the rect whole, a split
    /// divides it and places its sides.
    private func place(_ node: Int, in rect: CGRect, into made: inout Placement, gutter: CGFloat, minimum: CGSize) {
        switch nodes[node] {
        case .pane(let pane):
            made.panes[pane] = rect
        case .split(let axis, let first, let second, let fraction):
            made.rooms[node] = rect
            let whole = axis == .horizontal ? rect.width : rect.height
            let shared = max(0, whole - gutter)
            // The share as this much room allows, which can be tighter
            // than the room it was set in (see `clamped` for a room that
            // cannot honour it at all).
            let share = clamped(fraction, axis: axis, shared: shared, minimum: minimum) ?? 0.5
            let ahead = CGFloat(share) * shared
            var firstRect = rect, secondRect = rect, strip = rect
            if axis == .horizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: ahead, height: rect.height)
                secondRect = CGRect(x: rect.minX + ahead + gutter, y: rect.minY,
                                    width: rect.maxX - rect.minX - ahead - gutter, height: rect.height)
                strip = CGRect(x: rect.minX + ahead, y: rect.minY, width: gutter, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ahead)
                secondRect = CGRect(x: rect.minX, y: rect.minY + ahead + gutter,
                                    width: rect.width, height: rect.maxY - rect.minY - ahead - gutter)
                strip = CGRect(x: rect.minX, y: rect.minY + ahead, width: rect.width, height: gutter)
            }
            made.dividers.append((node, axis, strip))
            place(first, in: firstRect, into: &made, gutter: gutter, minimum: minimum)
            place(second, in: secondRect, into: &made, gutter: gutter, minimum: minimum)
        }
    }

    /// The panes under a node, first side first.
    private func leaves(under node: Int) -> [Int] {
        switch nodes[node] {
        case .pane(let pane): return [pane]
        case .split(_, let first, let second, _): return leaves(under: first) + leaves(under: second)
        }
    }

    /// Evens one split once its sides are even themselves, so the leaves
    /// under it count rather than the splits.
    private mutating func equalize(under node: Int) {
        guard case .split(let axis, let first, let second, _) = nodes[node] else { return }
        equalize(under: first)
        equalize(under: second)
        let ahead = leaves(under: first).count
        let behind = leaves(under: second).count
        guard ahead + behind > 0 else { return }
        nodes[node] = .split(axis: axis, first: first, second: second,
                             fraction: Double(ahead) / Double(ahead + behind))
    }

    /// The first pane under a node, which is the pane that takes a room
    /// over when its neighbour closes.
    private func firstPane(under node: Int) -> Int {
        leaves(under: node)[0]
    }

    /// The split that holds a node, walked from the root so that nothing
    /// emptied out of the arena is ever mistaken for the living parent.
    private func parent(of node: Int) -> Int? {
        parent(of: node, under: root)
    }

    private func parent(of node: Int, under start: Int) -> Int? {
        guard case .split(_, let first, let second, _) = nodes[start] else { return nil }
        if first == node || second == node { return start }
        return parent(of: node, under: first) ?? parent(of: node, under: second)
    }

    /// The slot the pane lives in, found among the living nodes only.
    private func liveSlot(of pane: Int) -> Int? {
        nodes.firstIndex { node in
            if case .pane(let id) = node { return id == pane && pane != -1 }
            return false
        }.flatMap { slot in parent(of: slot) != nil || slot == root ? slot : nil }
    }
}

/// The spans a rect has along each axis, as the crossing tests read them.
private extension CGRect {
    var horizontalSpan: (min: CGFloat, max: CGFloat) { (minX, maxX) }
    var verticalSpan: (min: CGFloat, max: CGFloat) { (minY, maxY) }
}

// MARK: - the room itself

// The tree above, given terminals and a place in a window: it makes a pane
// when the arrangement grows one, lays them all out when the room or the
// tree changes, and keeps track of which pane the keyboard is in. What the
// tab has always asked of one terminal — its title, where it is, whether
// it can be searched — it asks here of whichever pane holds the keys.
//
// The container is flipped, as the tree's coordinates are: rows run down
// from the top, and the rects the placement hands over are the frames
// as they are set, with no turning them over on the way.

/// Several terminals in the room one tab gives them: the arrangement of
/// `TerminalTree`, applied. Born as one pane — which is what a terminal
/// tab is before anyone splits it — and grown by `split(across:)`, from
/// wherever the keys are, as tmux and MetalTerm grow theirs.
@MainActor
final class TerminalSplits: NSView, ObservableObject {
    /// One pane: a terminal and the view that shows it, and the ears the
    /// tab is listening to it with. Held by pane id, the same id the tree
    /// names its leaves by.
    private struct Pane {
        let terminal: Terminal
        let view: TerminalView
        var ears: [AnyCancellable] = []
    }

    private(set) var tree = TerminalTree()
    private var panes: [Int: Pane] = [:]
    /// The pane the keyboard is in. What the tab reads — its title, its
    /// directory, what ⌘F searches — is this pane's.
    private(set) var focused = 0

    /// The gutter between panes, wide enough to catch the pointer without
    /// being wide enough to notice.
    private static let gutter: CGFloat = 7

    /// What the tab is called, and where it is: the focused pane's own
    /// answers, kept here so a tab listens to one thing however many
    /// terminals it holds.
    @Published private(set) var title = ""
    @Published private(set) var cwd: URL?

    /// A pane's notices, passed on to whoever a single terminal's would
    /// have gone to.
    var onNotice: ((Notice) -> Void)?

    /// The last pane's shell exited on its own — an `exit` typed, a
    /// command run out — and the room has nothing left to show. Closing
    /// the tab is the tab's business; this only says it is time.
    var onEmptied: (() -> Void)?

    /// How a pane's terminal is made: given the directory to start in,
    /// which is the focused pane's own when a split inherits it. The
    /// default — a shell, wrapped for its prompts — is what the app runs;
    /// a test can hand one it can watch instead.
    var onPane: ((String?) -> Terminal)?

    /// The hairline round the pane the keys are in, with more than one up
    /// (see FocusCue, where it is drawn) — and whether it is lit, which is
    /// remembered rather than asked of the alpha it happens to be showing,
    /// so a pass that lays out mid-fade does not start the fade again.
    private var cue: FocusCue?
    private var cueLit = false

    /// A divider per split in the arrangement, by the split's slot in the
    /// arena.
    private var dividers: [Int: TerminalDivider] = [:]

    /// The placement the last layout worked from, which is what a drag or
    /// a nudge of a divider works against.
    private var placed: TerminalTree.Placement?

    /// Whether a rest is being taken at the middle of a drag, so the tap
    /// that says so is felt once rather than per pixel of it.
    private var snapped = false

    /// The pane the keys are in, shown alone: the arrangement is kept —
    /// unzooming puts every pane back where it was — and the others are
    /// hidden, which stops their clocks with nothing else said (see
    /// TerminalView's frame schedule).
    private(set) var zoomed = false

    private var watching: NSObjectProtocol?
    /// The click that gives a pane the keyboard, watched rather than taken
    /// (see `clicked`) — the click stays the pane's own.
    private var monitor: Any?

    // MARK: - born

    /// Born as one pane. `onPane` is how a pane's terminal is made — given
    /// the directory it starts in — for the first pane as for every one
    /// made after; the default, when nil, is the shell the app runs.
    init(onPane birth: ((String?) -> Terminal)? = nil) {
        onPane = birth
        super.init(frame: .zero)
        wantsLayer = true
        // The gutter is the terminal's own background, not the window's:
        // a dark theme's panes are divided by a dark strip, whatever the
        // page side of the app is painted with. Re-said when the look
        // changes, as everything of the look is.
        layer?.backgroundColor = TerminalDraw.groundColor.cgColor
        watching = NotificationCenter.default.addObserver(
            forName: TerminalLook.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layer?.backgroundColor = TerminalDraw.groundColor.cgColor
            }
        }

        makePane(id: 0, in: nil)
        sayTitle()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let watching { NotificationCenter.default.removeObserver(watching) }
        MainActor.assumeIsolated {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let wanted = window != nil
        if wanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.clicked(event) }
                return event
            }
        } else if !wanted, let held = monitor {
            NSEvent.removeMonitor(held)
            monitor = nil
        }
    }

    /// A click in a pane gives it the keyboard, and is still the pane's
    /// click. Watched rather than taken: a terminal's view never asks for
    /// the keys on a click the way a page does, so with several panes up
    /// this is what a click is for — and what it was for before, when the
    /// one pane was the whole room and the stage was watching instead.
    private func clicked(_ event: NSEvent) {
        guard let window, event.window === window, !zoomed else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // What is over the room — the find field, a panel — is not a pane.
        if let hit = window.contentView?.hitTest(event.locationInWindow), hit !== self,
           !hit.isDescendant(of: self) { return }
        let layout = placed ?? placement()
        for (id, rect) in layout.panes where rect.contains(point) {
            if id != focused { focus(id) }
            return
        }
    }

    // MARK: - what the tab asks of a terminal

    /// The terminal the keys are in — the tab's shell, as one terminal
    /// used to be.
    var focusedTerminal: Terminal? { panes[focused]?.terminal }
    /// The view of the pane the keys are in, for whoever hands the
    /// keyboard back to it.
    var focusedView: TerminalView? { panes[focused]?.view }
    /// How many terminals the tab holds.
    var paneCount: Int { panes.count }

    /// The find field opens in the pane the keys are in, and walks that
    /// pane's scrollback; ⌘↑ and ⌘↓ walk its command blocks. All of it is
    /// the focused pane's, as it was the only terminal's.
    func openFind() { focusedView?.openFind() }
    func stepFind(forward: Bool) { focusedView?.stepFind(forward: forward) }
    func closeFind() { focusedView?.closeFind() }
    func jumpToPrompt(forward: Bool) { focusedView?.jumpToPrompt(forward: forward) }

    /// End every program the tab is running — the closing tab's hangup,
    /// sent to each pane as it was ever sent to the one. The panes are let
    /// go before it is, so the exits this brings about are not heard:
    /// there is no room left to close over anything.
    func close() {
        let shells = panes.values.map(\.terminal)
        panes.removeAll()
        shells.forEach { $0.stop() }
    }

    // MARK: - growing and closing

    /// Splits the pane the keys are in, along an axis: the new pane takes
    /// the other side, the directory the split is made from, and the
    /// keyboard. Refused when the pane has no room for two terminals of
    /// the smallest size there is — a split is not made to be all gutter.
    @discardableResult
    func split(across axis: TerminalAxis) -> Bool {
        // A zoomed pane has the whole room; splitting it is a way of
        // saying the room is wanted back.
        zoomed = false
        let layout = tree.placement(in: bounds, gutter: Self.gutter, minimum: least)
        guard let room = layout.panes[focused] else { return false }
        let along = axis == .horizontal ? room.width : room.height
        let need = (axis == .horizontal ? least.width : least.height) * 2 + Self.gutter
        guard along >= need else { return false }

        let from = panes[focused]?.terminal.cwd?.path
        guard let fresh = tree.split(focused, across: axis) else { return false }
        makePane(id: fresh, in: from)
        focus(fresh)
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    /// Closes the pane the keys are in. The split it was half of closes
    /// with it and the other side takes the room; the last pane is not
    /// this call's to close — that is the tab's, and whoever asks here is
    /// expected to have looked at `paneCount` first.
    func closePane() {
        closePane(focused)
    }

    /// The same close, of any pane: the one the keys are in when ⌘W or the
    /// divider's menu asks, and the one whose shell left on its own when
    /// that is what happened.
    private func closePane(_ id: Int) {
        guard panes.count > 1, let survivor = tree.remove(id) else { return }
        if let gone = panes.removeValue(forKey: id) {
            gone.terminal.stop()
            gone.view.removeFromSuperview()
        }
        zoomed = false
        focus(survivor)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// A pane's shell exited on its own — the `exit` you typed taking
    /// effect, or a command that ran out. Beside others, the pane closes
    /// and the room closes over it, with no asking (there is nothing left
    /// to end); alone, the room is empty and `onEmptied` says so.
    private func shellExited(_ id: Int) {
        guard panes[id] != nil else { return }
        if panes.count > 1 {
            closePane(id)
        } else {
            onEmptied?()
        }
    }

    /// ⌘W and the divider's menu: the pane the keys are in, closed with
    /// the asking the Mac owes a shell still running (Ask.sure, as
    /// MetalTerm asks) — a pane whose program has already exited goes
    /// without a word. Whether there was a pane to close: false is the
    /// room's own way of saying it never had sides, and the tab itself is
    /// what the key means.
    @discardableResult
    func closeFocusedPane() -> Bool {
        guard panes.count > 1 else { return false }
        if panes[focused]?.terminal.exit == nil {
            Ask.sure("Close Pane?",
                     detail: "Closing the pane will terminate its terminal session.",
                     confirm: "Close Pane") { [weak self] in self?.closePane() }
        } else {
            closePane()
        }
        return true
    }

    /// Gives the keys to the pane next to the focused one in a direction,
    /// as the arrow keys name it — the pane under the arrow, not merely
    /// the nearest one anywhere (see `TerminalTree.neighbour`).
    func moveFocus(_ direction: TerminalDirection) {
        guard let next = tree.neighbour(of: focused, toward: direction, in: placed ?? placement()) else { return }
        focus(next)
    }

    /// Gives the keys to a pane: the title and the directory are said
    /// again — the tab's say-so of them belongs to whoever holds the keys,
    /// and a tab left saying the closed pane's title is a tab lying — and
    /// the keyboard follows if there is a window to follow into. A pane
    /// already holding them is left alone, so the arrival the keyboard's
    /// own handing-over brings about (see `onFocused`) is not a second
    /// saying of everything.
    func focus(_ id: Int) {
        guard id != focused, panes[id] != nil else { return }
        focused = id
        sayTitle()
        needsLayout = true
        if let view = panes[id]?.view, let window {
            window.makeFirstResponder(view)
        }
    }

    /// Moves the divider next to the focused pane a step in a direction:
    /// one cell of the room, the smallest move a terminal can feel as its
    /// own size changing. Clamped by the tree, so a pane is never stepped
    /// under the least it can be.
    func nudge(_ direction: TerminalDirection) {
        guard !zoomed else { return }
        let layout = placed ?? placement()
        guard let node = tree.divider(of: focused, toward: direction, in: layout),
              let room = layout.rooms[node], let share = tree.fraction(of: node) else { return }
        let whole = direction.axis == .horizontal ? room.width : room.height
        let shared = max(1, whole - Self.gutter)
        let cellAlong = direction.axis == .horizontal ? cell.width : cell.height
        let toward = direction == .right || direction == .down ? 1.0 : -1.0
        tree.setFraction(share + toward * Double(cellAlong / shared), of: node,
                         room: whole, gutter: Self.gutter, minimum: least)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Steps a split's share by a fraction of its room, clamped to the
    /// minimums: VoiceOver's five percent a step, and nothing else is
    /// asking in fractions.
    func step(_ node: Int, by fraction: Double) {
        guard case .split(let axis, _, _, _) = tree.nodes[node],
              let share = tree.fraction(of: node), let room = placed?.rooms[node] else { return }
        tree.setFraction(share + fraction, of: node,
                         room: axis == .horizontal ? room.width : room.height,
                         gutter: Self.gutter, minimum: least)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Every pane takes the even share of its leaves (see
    /// `TerminalTree.equalize`) — the double-click on a divider and the
    /// menu's word for the same thing.
    func equalize() {
        guard panes.count > 1, !zoomed else { return }
        tree.equalize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Shows the pane the keys are in alone, or puts the room back the way
    /// it was. The arrangement is untouched throughout: zooming is a way
    /// of looking, not a way of arranging.
    func toggleZoom() {
        guard panes.count > 1 else { return }
        zoomed.toggle()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: - laid out

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        if zoomed {
            for (id, pane) in panes {
                pane.view.isHidden = id != focused
                if id == focused { pane.view.frame = bounds }
            }
            dividers.values.forEach { $0.isHidden = true }
            if let cue { fade(cue, to: false) }
            return
        }

        let layout = placement()
        placed = layout
        for (id, pane) in panes {
            pane.view.isHidden = false
            if let rect = layout.panes[id] { pane.view.frame = rect }
        }

        // One divider per split the arrangement has now, and no others:
        // dividers of splits that closed go with them.
        let living = Set(layout.dividers.map(\.node))
        for (node, divider) in dividers where !living.contains(node) {
            divider.removeFromSuperview()
            dividers[node] = nil
        }
        for line in layout.dividers {
            let divider: TerminalDivider
            if let held = dividers[line.node] {
                divider = held
            } else {
                divider = TerminalDivider(axis: line.axis)
                divider.onDrag = { [weak self] at in self?.dragged(line.node, axis: line.axis, to: at) }
                divider.onEven = { [weak self] in self?.equalize() }
                divider.onZoom = { [weak self] in self?.toggleZoom() }
                divider.onClose = { [weak self] in self?.closeFocusedPane() }
                divider.share = { [weak self] in
                    self?.tree.fraction(of: line.node).map { Int(($0 * 100).rounded()) } ?? 50
                }
                divider.onStep = { [weak self] by in self?.step(line.node, by: by) }
                addSubview(divider, positioned: .below, relativeTo: cue)
                dividers[line.node] = divider
            }
            divider.isHidden = false
            divider.frame = line.frame
        }

        // The hairline goes only round the pane the keys are in, and only
        // when there is more than one to tell apart. It comes and goes
        // with the same fade the page panes' own cue has, unless the Mac
        // is told to keep its movements still.
        let lit = panes.count > 1
        if lit, let rect = layout.panes[focused] {
            if cue == nil {
                let made = FocusCue()
                made.alphaValue = 0
                cue = made
                addSubview(made, positioned: .above, relativeTo: nil)
            }
            cue?.frame = rect
        }
        if let cue { fade(cue, to: lit) }
    }

    /// The cue's own coming and going: the fade the page panes' cue has
    /// too (PaneStage), and none at all when the Mac is told to keep its
    /// movements still.
    private func fade(_ cue: FocusCue, to lit: Bool) {
        guard cueLit != lit else { return }
        cueLit = lit
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0 : 0.14
            cue.animator().alphaValue = lit ? 1 : 0
        }
    }

    /// Where everything is in this room, with the least a pane can be
    /// worked out from the face the panes are drawn with: a terminal
    /// narrower than its cells' own width is not a terminal.
    private func placement() -> TerminalTree.Placement {
        tree.placement(in: bounds, gutter: Self.gutter, minimum: least)
    }

    /// The smallest pane there is room for: a few columns and rows, with
    /// the room the edges leave. In points, which is what the tree asks
    /// for — it does not know a renderer is deciding them.
    var least: CGSize {
        CGSize(
            width: TerminalDraw.inset * 2 + 8 * cell.width,
            height: TerminalDraw.inset * 2 + 3 * cell.height
        )
    }

    /// The cell the focused pane is drawn in — the size all the panes are
    /// drawn in, the face being one for the whole tab.
    private var cell: CGSize {
        panes[focused]?.view.cell ?? TerminalDraw.measure(TerminalLook.face())
    }

    /// A divider was dragged to a place along its split's room. The share
    /// follows the hand live — laid out now, not on the next pass — with a
    /// rest at the middle, felt as it is taken.
    private func dragged(_ node: Int, axis: TerminalAxis, to at: CGFloat) {
        guard let room = placed?.rooms[node] else { return }
        let whole = axis == .horizontal ? room.width : room.height
        let shared = max(1, whole - Self.gutter)
        var along = axis == .horizontal ? at - room.minX : at - room.minY
        let even = shared / 2
        if abs(along - even) <= 3 {
            if !snapped {
                snapped = true
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            along = even
        } else {
            snapped = false
        }
        tree.setFraction(Double(along / shared), of: node, room: whole, gutter: Self.gutter, minimum: least)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: - a pane

    /// Makes a pane and puts it in the arrangement's room: a terminal
    /// started in the directory given, its view, and the ears that keep
    /// the tab saying this pane's title and place while the keys are in
    /// it. The terminal's notices are the tab's; its view says when the
    /// keys arrive, which is how the container knows whose ear is the one
    /// to be listening through.
    private func makePane(id: Int, in directory: String?) {
        let terminal = onPane?(directory) ?? Terminal(directory: directory)
        let view = TerminalView(terminal: terminal)
        view.onFocused = { [weak self] in self?.focus(id) }
        if let cue {
            addSubview(view, positioned: .below, relativeTo: cue)
        } else {
            addSubview(view)
        }
        terminal.onNotice = { [weak self] notice in self?.onNotice?(notice) }

        var ears: [AnyCancellable] = []
        terminal.$title
            .receive(on: RunLoop.main)
            .sink { [weak self, weak terminal] _ in
                guard let self, self.panes[self.focused]?.terminal === terminal else { return }
                self.sayTitle()
            }
            .store(in: &ears)
        terminal.$cwd
            .receive(on: RunLoop.main)
            .sink { [weak self, weak terminal] _ in
                guard let self, self.panes[self.focused]?.terminal === terminal else { return }
                // A new place moves the title too, when the title is ours
                // to say: the shell has just told us where it is.
                self.sayTitle()
            }
            .store(in: &ears)
        terminal.$exit
            .receive(on: RunLoop.main)
            .sink { [weak self] code in
                guard let self, code != nil else { return }
                self.shellExited(id)
            }
            .store(in: &ears)
        panes[id] = Pane(terminal: terminal, view: view, ears: ears)
    }

    /// Says the tab's title and place again from the pane that holds the
    /// keys. Called whenever the keys move — a title that says the closed
    /// pane's shell is a title that has been left behind.
    private func sayTitle() {
        guard let pane = panes[focused] else { return }
        // A shell that set a title of its own keeps its word; one that
        // never did is called by the directory it is in — "search", not
        // "zsh" — which is what a tab is for. Until the shell has said
        // where it is (OSC 7), the terminal's own name stands in.
        title = pane.terminal.title.isEmpty
            ? pane.terminal.cwd.map(Self.directoryName(of:)) ?? pane.terminal.named
            : pane.terminal.title
        cwd = pane.terminal.cwd
    }

    /// A directory as a tab's title says it: the directory's own name, the
    /// home directory itself said as "~", the root as "/".
    private static func directoryName(of place: URL) -> String {
        let path = place.path
        if path == NSHomeDirectory() { return "~" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}

// MARK: - the line between two panes

/// The gutter between two terminals: a hairline that grows a little under
/// the pointer, dragged it moves the split's share, double-clicked the
/// sides are made even. It never takes the keys — the panes keep them.
///
/// Its mechanism is PaneDivider's (which divides pages, and stays the
/// page splitter it is); what is different here is the axis — this line
/// runs either way — and that it is told what to do rather than knowing:
/// the container owns the arrangement, and the divider is only the hand
/// on it.
final class TerminalDivider: NSView {
    /// The split's axis: which way this line runs, and which way it takes
    /// the pointer's drag.
    private let axis: TerminalAxis

    /// Where the divider was dragged to, in the container's own
    /// coordinates along the axis.
    var onDrag: ((CGFloat) -> Void)?
    /// Made even, from a double-click or the menu.
    var onEven: (() -> Void)?
    /// The focused pane shown alone, from the menu.
    var onZoom: (() -> Void)?
    /// The focused pane closed, from the menu.
    var onClose: (() -> Void)?
    /// The share the first side holds, as a whole percent, said for
    /// VoiceOver.
    var share: (() -> Int)?
    /// Steps the share by a fraction, as VoiceOver's increment and
    /// decrement ask for it — five percent either way, clamped by whoever
    /// owns the arrangement.
    var onStep: ((Double) -> Void)?

    private let line = CALayer()
    private var hovering = false
    private var dwell: DispatchWorkItem?
    private var dragging = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(axis given: TerminalAxis) {
        axis = given
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        line.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        line.backgroundColor = (hovering || dragging ? Palette.NS.muted : Palette.NS.faint).cgColor
    }

    override func layout() {
        super.layout()
        place()
    }

    /// The hairline sits in the middle of the gutter, thin at rest and a
    /// little less thin under the pointer.
    private func place() {
        let width: CGFloat = hovering || dragging ? 3 : 1
        if axis == .horizontal {
            line.frame = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        } else {
            line.frame = CGRect(x: 0, y: (bounds.height - width) / 2, width: bounds.width, height: width)
        }
        line.cornerRadius = width / 2
    }

    private func light(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.14)
        place()
        line.backgroundColor = (on || dragging ? Palette.NS.muted : Palette.NS.faint).cgColor
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        // A moment's rest first, so passing over it doesn't flicker.
        dwell?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.light(true) }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        dwell?.cancel()
        if !dragging { light(false) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onEven?()
            return
        }
        dragging = true
        dwell?.cancel()
        light(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        guard let room = superview else { return }
        let at = room.convert(event.locationInWindow, from: nil)
        onDrag?(axis == .horizontal ? at.x : at.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hovering = !inside
        light(inside)
    }

    // MARK: - its menu

    /// What can be done with the arrangement, from the gutter itself.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, act) in [("Even Out", onEven), ("Zoom Pane", onZoom), ("Close Pane", onClose)] {
            guard let act else { continue }
            let item = NSMenuItem(title: title, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = act
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chose(_ item: NSMenuItem) {
        (item.representedObject as? () -> Void)?()
    }

    // MARK: - VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Divider between the terminals" }
    override func accessibilityValue() -> Any? { share?() }
    override func accessibilityPerformIncrement() -> Bool {
        guard onStep != nil else { return false }
        onStep?(0.05)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard onStep != nil else { return false }
        onStep?(-0.05)
        return true
    }
}
