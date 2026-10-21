import XCTest
@testable import Search

/// Several terminals in one tab, as a tree of panes: the room an L of
/// splits makes, the splicing that closes a pane without closing its
/// neighbour's room over, the half a divider keeps being dragged away
/// from, and which pane really is under an arrow.
///
/// Nothing here has a view or a shell behind it. The tree is the
/// arithmetic of the arrangement, and the arithmetic is what these pin —
/// the container that applies it is further down its own file.
final class TerminalSplitsTests: XCTestCase {
    private let room = CGRect(x: 0, y: 0, width: 600, height: 400)
    private let gutter: CGFloat = 6
    private let minimum = CGSize(width: 40, height: 30)

    /// The L every other test stands on: a split right of pane 0, then a
    /// split down of the pane that appeared. A tall pane on the left, two
    /// stacked on the right, and a gutter taken once between each pair.
    private func ell() -> TerminalTree {
        var tree = TerminalTree()
        tree.split(0, across: .horizontal)
        tree.split(1, across: .vertical)
        return tree
    }

    /// One pane is the whole room — which is what a terminal tab is before
    /// anyone splits it, and what the arrangement returns to when the last
    /// split closes.
    func testAPaneAloneIsTheWholeRoom() {
        let placed = TerminalTree().placement(in: room, gutter: gutter, minimum: minimum)
        XCTAssertEqual(placed.panes, [0: room])
        XCTAssertTrue(placed.dividers.isEmpty, "nothing is divided yet")
    }

    /// A split right and a split down makes an L: a tall pane on the left,
    /// the right side stacked, the gutter counted once per division and
    /// nowhere else.
    func testSplittingRightAndThenDownMakesAnL() {
        let tree = ell()
        XCTAssertEqual(tree.panes, [0, 1, 2], "reading order: left to right, then down")

        let placed = tree.placement(in: room, gutter: gutter, minimum: minimum)
        XCTAssertEqual(placed.panes[0], CGRect(x: 0, y: 0, width: 297, height: 400))
        XCTAssertEqual(placed.panes[1], CGRect(x: 303, y: 0, width: 297, height: 197))
        XCTAssertEqual(placed.panes[2], CGRect(x: 303, y: 203, width: 297, height: 197))
        XCTAssertEqual(placed.dividers.count, 2, "one gutter per split")
        XCTAssertEqual(placed.dividers.filter { $0.axis == .horizontal }.count, 1, "one divider down the room")
        XCTAssertEqual(placed.dividers.filter { $0.axis == .vertical }.count, 1, "and one across the right")
        // The panes and the two gutters tile the room exactly.
        let covered = placed.panes.values.map(\.area).reduce(0, +)
            + placed.dividers.map(\.frame.area).reduce(0, +)
        XCTAssertEqual(covered, room.area, accuracy: 0.5, "nothing overlaps and nothing is left over")
    }

    /// Closing a pane closes the split that held it: the other side takes
    /// the room, and a pane elsewhere in the arrangement keeps the rect it
    /// had. Closing the last pane is nobody's to do — the caller closes
    /// the tab instead.
    func testClosingAPaneClosesTheSplitOverIt() {
        var tree = ell()
        let before = tree.placement(in: room, gutter: gutter, minimum: minimum)

        XCTAssertEqual(tree.remove(2), 1, "the pane that takes the room over")
        XCTAssertEqual(tree.panes, [0, 1])
        let afterTwo = tree.placement(in: room, gutter: gutter, minimum: minimum)
        XCTAssertEqual(afterTwo.panes[1], CGRect(x: 303, y: 0, width: 297, height: 400), "the right side, whole again")
        XCTAssertEqual(afterTwo.panes[0], before.panes[0], "and the pane nowhere near it untouched")
        XCTAssertEqual(afterTwo.dividers.count, 1, "one split closed with the pane")

        XCTAssertEqual(tree.remove(1), 0)
        XCTAssertEqual(tree.panes, [0])
        let afterOne = tree.placement(in: room, gutter: gutter, minimum: minimum)
        XCTAssertEqual(afterOne.panes[0], room, "the whole room, as the tab began")
        XCTAssertNil(tree.remove(0), "there is nothing left to collapse — close the tab")
    }

    /// A pane that has closed is gone: its slot in the arena is emptied
    /// with a marker, so a split asked for by the departed id is no split
    /// at all and the arrangement is unchanged.
    func testAClosedPaneCannotBeFoundToSplit() {
        var tree = ell()
        tree.remove(1)
        let before = tree
        XCTAssertNil(tree.split(1, across: .horizontal))
        XCTAssertEqual(tree, before, "nothing moved, nothing was made")
    }

    /// Who is next to whom, on the L: across the room rightward from the
    /// tall pane is the pane above (a tie with the pane below, broken by
    /// reading order), down from the top right is the bottom right, and
    /// no arrow points anywhere the L has no pane.
    func testTheNeighbourUnderAnArrow() {
        let tree = ell()
        let placed = tree.placement(in: room, gutter: gutter, minimum: minimum)

        XCTAssertEqual(tree.neighbour(of: 0, toward: .right, in: placed), 1)
        XCTAssertEqual(tree.neighbour(of: 1, toward: .left, in: placed), 0)
        XCTAssertNil(tree.neighbour(of: 1, toward: .right, in: placed), "the wall")
        XCTAssertEqual(tree.neighbour(of: 2, toward: .left, in: placed), 0)
        XCTAssertEqual(tree.neighbour(of: 1, toward: .down, in: placed), 2)
        XCTAssertEqual(tree.neighbour(of: 2, toward: .up, in: placed), 1)
        XCTAssertNil(tree.neighbour(of: 0, toward: .left, in: placed), "the wall")
        XCTAssertNil(tree.neighbour(of: 0, toward: .up, in: placed))
        XCTAssertNil(tree.neighbour(of: 0, toward: .down, in: placed), "an L has no pane below its tall side")
        XCTAssertNil(tree.neighbour(of: 2, toward: .down, in: placed))
    }

    /// The divider an arrow's nudge moves: the one that spans the pane,
    /// not the deeper one that divides the other side. On the L, the
    /// bottom right pane is nudged left by the divider running the whole
    /// height, and up by the one dividing only the right.
    func testTheDividerToNudgeIsTheOneThePaneSitsAgainst() {
        let tree = ell()
        let placed = tree.placement(in: room, gutter: gutter, minimum: minimum)
        // The splits' slots in the arena: the root split was the first
        // split made, the inner one the second.
        XCTAssertEqual(tree.divider(of: 1, toward: .left, in: placed), 0, "the root split, for the pane against it")
        XCTAssertEqual(tree.divider(of: 2, toward: .left, in: placed), 0)
        XCTAssertEqual(tree.divider(of: 0, toward: .right, in: placed), 0)
        XCTAssertEqual(tree.divider(of: 1, toward: .down, in: placed), 1, "the inner split, dividing the right side")
        XCTAssertEqual(tree.divider(of: 2, toward: .up, in: placed), 1)
        XCTAssertNil(tree.divider(of: 0, toward: .left, in: placed))
        XCTAssertNil(tree.divider(of: 0, toward: .down, in: placed), "no divider of that axis crosses the tall pane")
    }

    /// Equal shares means shares of the leaves: halves for two panes,
    /// thirds where one side of a split holds two and the other one — not
    /// halves down every split, which would squeeze the third pane.
    func testEqualizingGivesLeavesEvenShares() {
        var tree = ell()
        tree.setFraction(0.25, of: 0, room: room.width, gutter: gutter, minimum: minimum)
        tree.equalize()

        XCTAssertEqual(tree.fraction(of: 0) ?? 0, 1.0 / 3.0, accuracy: 1e-9, "one leaf against two")
        XCTAssertEqual(tree.fraction(of: 1) ?? 0, 0.5, accuracy: 1e-9)

        let placed = tree.placement(in: room, gutter: gutter, minimum: minimum)
        XCTAssertEqual(placed.panes[0]!.width, 198, accuracy: 0.5, "a third of the shared width")
        XCTAssertEqual(placed.panes[1]!.width, 396, accuracy: 0.5, "and two thirds")
        XCTAssertEqual(placed.panes[1]!.height, placed.panes[2]!.height, "the stacked side, halved evenly")
    }

    /// A share is clamped to the minimum on both sides: a divider dragged
    /// to either wall stops one minimum short of it, in either axis, and a
    /// room too small to honour both minimums leaves the share where it
    /// was rather than choosing which pane to shortchange.
    func testAShareIsClampedToTheMinimums() {
        var side = TerminalTree()
        side.split(0, across: .horizontal)
        side.setFraction(0, of: 0, room: room.width, gutter: gutter, minimum: minimum)
        XCTAssertEqual(side.fraction(of: 0) ?? 0, 40.0 / 594.0, accuracy: 1e-9, "one minimum from the left wall")
        side.setFraction(1, of: 0, room: room.width, gutter: gutter, minimum: minimum)
        XCTAssertEqual(side.fraction(of: 0) ?? 0, 1 - 40.0 / 594.0, accuracy: 1e-9, "and one from the right")

        var stacked = TerminalTree()
        stacked.split(0, across: .vertical)
        stacked.setFraction(0, of: 0, room: room.height, gutter: gutter, minimum: minimum)
        XCTAssertEqual(stacked.fraction(of: 0) ?? 0, 30.0 / 394.0, accuracy: 1e-9, "the height's minimum, not the width's")

        side.setFraction(0.9, of: 0, room: 70, gutter: gutter, minimum: minimum)
        XCTAssertEqual(side.fraction(of: 0) ?? 0, 1 - 40.0 / 594.0, accuracy: 1e-9,
                       "a room that cannot honour either minimum keeps the share it had")
    }

    /// The tree keeps what was dragged; the room decides what can be shown
    /// of it. A share that was legal where it was set is clamped again at
    /// layout time when the room has shrunk around it.
    func testAShareIsClampedAgainInTheRoomItIsShownIn() {
        var tree = TerminalTree()
        tree.split(0, across: .horizontal)
        tree.setFraction(0.1, of: 0, room: room.width, gutter: gutter, minimum: minimum)

        let placed = tree.placement(in: CGRect(x: 0, y: 0, width: 100, height: 400),
                                     gutter: gutter, minimum: minimum)
        XCTAssertEqual(placed.panes[0]!.width, 40, accuracy: 0.5, "held at the minimum, not dragged under it")
        XCTAssertEqual(tree.fraction(of: 0) ?? 0, 0.1, accuracy: 1e-9, "and the tree still holds what was dragged")
    }

    /// Splitting before puts the new pane on the other side: right splits
    /// put it on the left, down splits put it above — the pane that was
    /// there always keeps the side it had.
    func testSplittingBeforePutsTheNewPaneOnTheOtherSide() {
        var side = TerminalTree()
        let fresh = side.split(0, across: .horizontal, before: true)!
        XCTAssertEqual(side.panes, [fresh, 0], "the newcomer reads first")
        let placedSide = side.placement(in: room, gutter: gutter, minimum: minimum)
        XCTAssertEqual(placedSide.panes[fresh], CGRect(x: 0, y: 0, width: 297, height: 400), "the newcomer on the left")
        XCTAssertEqual(placedSide.panes[0], CGRect(x: 303, y: 0, width: 297, height: 400), "and the pane that was there keeps the right")

        var stacked = TerminalTree()
        let above = stacked.split(0, across: .vertical, before: true)!
        let placedStack = stacked.placement(in: room, gutter: gutter, minimum: minimum)
        XCTAssertEqual(placedStack.panes[above]!.maxY, 197, accuracy: 0.5, "the newcomer above")
        XCTAssertEqual(placedStack.panes[0]!.minY, 203, accuracy: 0.5, "and the pane that was there below")
    }
}

/// The area a rect covers, for the tiling test.
private extension CGRect {
    var area: CGFloat { width * height }
}

/// The room itself, with real terminals in a real window: panes where the
/// tree says, a divider per split, the keys following a click or an arrow
/// into a pane, and the tab's title following the keys.
///
/// The terminals are shells that sleep rather than ones that talk — what
/// is pinned here is the arrangement around them, which is the
/// container's; what a shell says on a screen is TerminalWindowTests'
/// and has been.
@MainActor
final class TerminalSplitsWindowTests: XCTestCase {
    /// A room in a window, with panes that sleep — each argv distinct, so
    /// a title read after the keys move says which pane they are in. A
    /// test that needs panes of its own hands them over per pane, in the
    /// order they are made (1 for the first).
    private func room(
        _ width: CGFloat, _ height: CGFloat,
        onPane birth: ((Int) -> Terminal)? = nil
    ) -> (container: TerminalSplits, window: NSWindow) {
        var made = 0
        let container = TerminalSplits(onPane: { _ in
            made += 1
            return birth?(made) ?? Terminal(command: TerminalCommand(
                argv: ["/bin/zsh", "-f", "-c", "sleep 5 #\(made)"]))
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = container
        window.orderFrontRegardless()
        return (container, window)
    }

    /// The panes in the room, in no order but their own.
    private func panes(_ container: TerminalSplits) -> [TerminalView] {
        container.subviews.compactMap { $0 as? TerminalView }
    }

    private func dividers(_ container: TerminalSplits) -> [TerminalDivider] {
        container.subviews.compactMap { $0 as? TerminalDivider }
    }

    /// A split right divides the room: the pane that was there keeps the
    /// left, the new one takes the right and the keyboard, and the gutter
    /// between them is one divider wide.
    func testSplittingRightDividesTheRoom() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        XCTAssertTrue(container.split(across: .horizontal))
        XCTAssertEqual(container.paneCount, 2, "two terminals in the tab")
        XCTAssertEqual(panes(container).count, 2)
        XCTAssertEqual(dividers(container).count, 1, "one gutter")

        let views = panes(container)
        let left = views.first { $0.frame.minX == 0 }
        let right = views.first { $0 !== left }
        XCTAssertEqual(left?.frame, CGRect(x: 0, y: 0, width: 496.5, height: 500))
        XCTAssertEqual(right?.frame, CGRect(x: 503.5, y: 0, width: 496.5, height: 500))
        XCTAssertEqual(dividers(container).first?.frame, CGRect(x: 496.5, y: 0, width: 7, height: 500))
        XCTAssertEqual(container.focusedView, right, "the pane that was made took the keys")
    }

    /// A split down of the right pane makes an L, and closing the bottom
    /// closes the split that held it: the top takes the right side back,
    /// whole.
    func testAnLClosesOverItsBottomPane() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.split(across: .horizontal)
        XCTAssertTrue(container.split(across: .vertical))
        XCTAssertEqual(container.paneCount, 3)
        XCTAssertEqual(dividers(container).count, 2)

        container.closePane()
        XCTAssertEqual(container.paneCount, 2)
        XCTAssertEqual(container.focusedView?.frame, CGRect(x: 503.5, y: 0, width: 496.5, height: 500),
                       "the top of the right side, whole again")
        XCTAssertEqual(dividers(container).count, 1, "one split closed with the pane")
    }

    /// Zoom shows the pane with the keys alone, and the others cost
    /// nothing while they are behind it — hidden, which is what stops a
    /// terminal's frame clock (see TerminalView). Unzooming puts the room
    /// back as it was: the arrangement was kept throughout.
    func testZoomShowsTheFocusedPaneAloneAndPutsTheRoomBack() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.split(across: .horizontal)
        container.split(across: .vertical)
        let before = panes(container).map(\.frame)
        let alone = container.focusedView

        container.toggleZoom()
        XCTAssertEqual(alone?.frame, CGRect(x: 0, y: 0, width: 1000, height: 500), "the whole room")
        for view in panes(container) where view !== alone {
            XCTAssertTrue(view.isHidden, "hidden panes cost no frames")
        }
        XCTAssertTrue(dividers(container).allSatisfy(\.isHidden))

        container.toggleZoom()
        XCTAssertEqual(panes(container).map(\.frame).sorted { $0.minY < $1.minY }, before.sorted { $0.minY < $1.minY },
                       "the room put back as it was")
        XCTAssertFalse(panes(container).contains(where: \.isHidden))
    }

    /// The keys go where they are pointed: an arrow steps to the pane
    /// under it, and arriving as the first responder — a click's way of
    /// saying so — says the same.
    func testTheKeysFollowArrowsAndArrivals() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.split(across: .horizontal)
        container.split(across: .vertical)
        XCTAssertEqual(container.focused, 2, "the pane the L grew with")

        container.moveFocus(.up)
        XCTAssertEqual(container.focused, 1)
        container.moveFocus(.left)
        XCTAssertEqual(container.focused, 0)
        XCTAssertNil(container.tree.neighbour(of: 0, toward: .left, in: container.tree.placement(
            in: container.bounds, gutter: 7, minimum: .zero
        )), "the wall, so the keys stay")
        XCTAssertEqual(container.focused, 0)

        // Arriving as the first responder is the click's word for it.
        let top = panes(container).first { $0.frame.minX > 0 && $0.frame.minY == 0 }
        window.makeFirstResponder(top)
        XCTAssertEqual(container.focused, 1, "the keyboard arrived, and the room knows whose it is")
        XCTAssertEqual(container.focusedView, top)
    }

    /// ⌘[ and ⌘] walk the panes in reading order — the tall pane, then the
    /// two stacked — wrapping at the ends, where a room's shape has no
    /// arrow to name the way.
    func testCyclingWalksTheReadingOrderAndWraps() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.split(across: .horizontal)
        container.split(across: .vertical)
        XCTAssertEqual(container.focused, 2, "the pane the L grew with")

        container.cycleFocus(1)
        XCTAssertEqual(container.focused, 0, "⌘] off the end starts again at the tall pane")
        container.cycleFocus(1)
        XCTAssertEqual(container.focused, 1)
        container.cycleFocus(1)
        XCTAssertEqual(container.focused, 2, "and the round trip lands where it began")

        container.cycleFocus(-1)
        XCTAssertEqual(container.focused, 1, "⌘[ steps back the way ⌘] came")
        container.cycleFocus(-1)
        XCTAssertEqual(container.focused, 0)
        container.cycleFocus(-1)
        XCTAssertEqual(container.focused, 2, "⌘[ off the start ends at the last pane")
    }

    /// A room of one pane has nowhere to go: the walk leaves the keys
    /// where they are, as the arrow keys do at a wall.
    func testAOnePaneRoomHasNothingToCycle() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.cycleFocus(1)
        container.cycleFocus(-1)
        XCTAssertEqual(container.focused, 0)
    }

    /// The tab's title says the pane the keys are in — the terminal's own
    /// name while it has said no directory — with the count of the panes
    /// beside it, and says the next pane's the moment the keys move.
    func testTheTitleFollowsTheKeys() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.split(across: .horizontal)
        XCTAssertEqual(container.title, "sleep 5 #2 (2)", "the pane that was made holds the keys, beside the one it came from")

        container.moveFocus(.left)
        XCTAssertEqual(container.title, "sleep 5 #1 (2)", "and the title moved with them, not left saying the closed room's")
    }

    /// The directory names the tab even over a title the shell set of its
    /// own (OSC 0/2) — oh-my-zsh sets one at every prompt — because the
    /// integration has every prompt say where it is (OSC 7), and where
    /// the keys are is what a tab is called.
    func testTheDirectoryNamesTheTabOverAShellSetTitle() {
        let (container, window) = room(1000, 500, onPane: { _ in
            Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c",
                "printf '\\033]0;My Title\\033\\\\'; printf '\\033]7;file:///tmp/rooms/search\\033\\\\'; sleep 5"]))
        })
        defer { container.close(); window.orderOut(nil) }

        let said = expectation(description: "the shell said a title and its place")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { said.fulfill() }
        wait(for: [said], timeout: 5)

        XCTAssertEqual(container.title, "search", "the title the shell set gives way to the directory it is in")
    }

    /// A tab is called by the directory the keys are in — the directory's
    /// own name, home said as "~" — with the count of panes beside it,
    /// following the keys between panes. The shells here say where they
    /// are the way the integration has every prompt say it (OSC 7).
    func testATabIsCalledByTheDirectoryTheKeysAreIn() {
        let spoken = [
            "printf '\\033]7;file:///tmp/rooms/search\\033\\\\'; sleep 5",
            "printf '\\033]7;file://\(NSHomeDirectory())\\033\\\\'; sleep 5"
        ]
        let (container, window) = room(1000, 500, onPane: { made in
            Terminal(command: TerminalCommand(
                argv: ["/bin/zsh", "-f", "-c", spoken[min(made - 1, spoken.count - 1)]]))
        })
        defer { container.close(); window.orderOut(nil) }

        XCTAssertTrue(container.split(across: .horizontal))
        let said = expectation(description: "the shells said where they are")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { said.fulfill() }
        wait(for: [said], timeout: 5)

        XCTAssertEqual(container.title, "~ (2)", "the pane that was made sits at home, and the title says so beside the count")
        container.moveFocus(.left)
        XCTAssertEqual(container.title, "search (2)", "and the keys moved back to the pane in search")
    }

    /// A pane whose shell exits on its own — the `exit` you typed, or a
    /// command that ran out — closes with no asking (there is nothing left
    /// to end), and the room closes over it.
    func testAPaneWhoseShellExitsClosesAndTheRoomClosesOverIt() {
        let (container, window) = room(1000, 500, onPane: { made in
            Terminal(command: TerminalCommand(
                argv: ["/bin/zsh", "-f", "-c", made == 1 ? "sleep 0.3" : "sleep 5"]))
        })
        defer { container.close(); window.orderOut(nil) }

        XCTAssertTrue(container.split(across: .horizontal))
        XCTAssertEqual(container.paneCount, 2)

        let closed = expectation(description: "the first pane's shell ran out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { closed.fulfill() }
        wait(for: [closed], timeout: 5)

        XCTAssertEqual(container.paneCount, 1, "the pane whose shell exited closed on its own")
        XCTAssertEqual(container.focusedView?.frame, CGRect(x: 0, y: 0, width: 1000, height: 500),
                       "and the pane that slept on takes the whole room")
        XCTAssertEqual(container.title, "sleep 5", "and a room of one is a tab the way it always was, saying no number")
    }

    /// A nudge steps the divider a cell: the smallest move a terminal can
    /// feel as its own size changing, and clamped, so the pane beside it
    /// is never stepped under the least it can be.
    func testANudgeStepsTheDividerACell() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.split(across: .horizontal)
        let share = container.tree.fraction(of: 0) ?? 0.5

        container.nudge(.left)
        let stepped = container.tree.fraction(of: 0) ?? 0.5
        XCTAssertLessThan(stepped, share, "nudged toward the pane the keys are in")
        let cell = container.focusedView?.cell.width ?? 8
        XCTAssertEqual(share - stepped, Double(cell / 993), accuracy: 0.005, "one cell of the room, no more")

        for _ in 0..<100 { container.nudge(.left) }
        // The floor is the least a pane can be, in points — the room's own
        // figure for it — over the room the divider divides.
        let floor = Double(container.least.width / 993)
        XCTAssertEqual(container.tree.fraction(of: 0) ?? 0.5, floor, accuracy: 0.005,
                       "a hundred nudges stop at the least the other pane can be")
    }

    /// A split is refused where a pane cannot live: a room too narrow for
    /// two terminals of the smallest size there is keeps the one it has.
    func testASplitIsRefusedWhereAPaneCannotLive() {
        let (container, window) = room(100, 80)
        defer { container.close(); window.orderOut(nil) }

        XCTAssertFalse(container.split(across: .horizontal))
        XCTAssertEqual(container.paneCount, 1)
        XCTAssertTrue(dividers(container).isEmpty)
    }

    /// Evened out, every pane takes the share of its leaves — the halves
    /// back, whatever a drag or a hundred nudges had done to them.
    func testEveningOutGivesTheLeavesTheirShares() {
        let (container, window) = room(1000, 500)
        defer { container.close(); window.orderOut(nil) }

        container.split(across: .horizontal)
        for _ in 0..<20 { container.nudge(.left) }
        XCTAssertNotEqual(container.tree.fraction(of: 0) ?? 0.5, 0.5, accuracy: 0.001, "dragged off the half first")

        container.equalize()
        XCTAssertEqual(container.tree.fraction(of: 0) ?? 0, 0.5, accuracy: 1e-9, "the halves back")
        let widths = panes(container).map(\.frame.width)
        XCTAssertEqual(widths.min() ?? 0, widths.max() ?? 0, accuracy: 0.5, "and the frames say so")
    }
}
