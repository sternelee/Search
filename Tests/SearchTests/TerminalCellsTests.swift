import XCTest
@testable import Search

/// What the damage-driven cell cache thinks each slot of the ring is
/// holding, and what it decides has to be said again. No Metal here: a slot
/// is a number and a plan is a value, which is what makes the arithmetic
/// that keeps a row from going stale something that can be read.
///
/// The cache knows a row by the address of its squares, so these tests are
/// about rows rather than about damage: what makes a row one the slot has
/// already got is that it is the very row the slot was written from.
@MainActor
final class TerminalCellsTests: XCTestCase {
    /// A screenful of rows, each with squares of its own — as a screen makes
    /// them, and as `Scene.lines` hands them over.
    private func frame(_ lines: Int, _ columns: Int = 80) -> [Row] {
        (0..<lines).map { _ in Row(width: columns) }
    }

    /// The same frame, scrolled: the rows move along it and the band the
    /// scroll uncovered is new rows. Positive is further down the screen —
    /// what the frame now shows at row 0 was at row `by` before.
    private func scrolled(_ rows: [Row], by delta: Int) -> [Row] {
        (0..<rows.count).map { row in
            let source = row + delta
            return (source >= 0 && source < rows.count) ? rows[source] : Row(width: 80)
        }
    }

    /// A slot nothing has been written into cannot be trusted for anything:
    /// the whole frame is converted.
    func testAFreshSlotIsWrittenWhole() {
        let book = TerminalCells(ring: 3)
        XCTAssertEqual(
            book.plan(0, rows: frame(24), top: 100, columns: 80, overturned: false),
            TerminalCells.Plan(whole: true)
        )
    }

    /// A frame the slot was already written from — the same rows, the same
    /// first place — converts nothing. This is what a terminal that is only
    /// moving its cursor costs.
    func testASlotThatAlreadySaysItConvertsNothing() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)
        let plan = book.plan(0, rows: rows, top: 100, columns: 80, overturned: false)
        XCTAssertTrue(plan.nothing, "the slot is holding exactly this frame: \(plan)")
    }

    /// A screen that scrolled says the band the scroll uncovered and moves
    /// the rest: the rows that were kept come from further down the slot,
    /// which is what the shift is for.
    func testAScrollSaysOnlyTheBandItUncovered() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)

        // Down the screen by three: the content moved three rows up it, and
        // the bottom three rows are new.
        let down = book.plan(0, rows: scrolled(rows, by: 3), top: 103, columns: 80, overturned: false)
        XCTAssertEqual(down.shift, 3, "the kept rows moved three down the slot")
        XCTAssertEqual(down.ranges, [21..<24], "the uncovered band is at the bottom")
        XCTAssertFalse(down.whole)

        // And up by three: the same, the other way.
        let up = book.plan(0, rows: scrolled(rows, by: -3), top: 97, columns: 80, overturned: false)
        XCTAssertEqual(up.shift, -3)
        XCTAssertEqual(up.ranges, [0..<3], "the uncovered band is at the top")
    }

    /// A scroll that takes the frame clean off the slot — further than the
    /// screen is tall — leaves nothing to move.
    func testAScrollPastTheSlotsRowsIsWhole() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)
        let far = TerminalCells.Plan(whole: true)
        XCTAssertEqual(
            book.plan(0, rows: scrolled(rows, by: 24), top: 124, columns: 80, overturned: false), far
        )
        XCTAssertEqual(
            book.plan(0, rows: scrolled(rows, by: -24), top: 76, columns: 80, overturned: false), far
        )
    }

    /// A row written where it stands — the same place, other words — is not
    /// the row the slot was written from, so it is converted, and it is the
    /// only one: this is the case the screen's report of what it wrote would
    /// have had to be right about.
    func testARowWrittenInPlaceIsTheOnlyOneConverted() {
        var book = TerminalCells(ring: 3)
        var rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)
        rows[5] = Row(width: 80)
        let plan = book.plan(0, rows: rows, top: 100, columns: 80, overturned: false)
        XCTAssertEqual(plan.shift, 0)
        XCTAssertEqual(plan.ranges, [5..<6], "the row that was written, and nothing else")
    }

    /// The band a shift uncovers and a row rewritten beside it are said in
    /// one range, not two: they are converted together or not at all.
    func testARewrittenRowBesideTheUncoveredBandIsOneRange() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)
        // Down by two: rows 22 and 23 are new. And the row just above them
        // was written where it stands as well.
        var now = scrolled(rows, by: 2)
        now[21] = Row(width: 80)
        let plan = book.plan(0, rows: now, top: 102, columns: 80, overturned: false)
        XCTAssertEqual(plan.shift, 2)
        XCTAssertEqual(plan.ranges, [21..<24], "one band: the rewritten row and the two uncovered")
    }

    /// Every slot that was written from a frame knows it again by the rows
    /// themselves, so a row written in place is converted by the next frame
    /// whatever slot it lands on — which is the stale frame the ring would
    /// otherwise show one time in three.
    func testEverySlotWrittenFromAFrameKnowsARowTheScreenRewrote() {
        var book = TerminalCells(ring: 3)
        var rows = frame(24)
        for slot in 0..<3 { book.written(slot, top: 100, columns: 80, held: rows) }
        rows[10] = Row(width: 80)

        for slot in 0..<3 {
            XCTAssertEqual(
                book.plan(slot, rows: rows, top: 100, columns: 80, overturned: false).ranges, [10..<11],
                "slot \(slot) sees the row the screen rewrote"
            )
        }
    }

    /// A frame whose slot has come round again — the ring is three deep, so
    /// the fourth frame draws into the first slot — costs nothing when the
    /// screen has not moved since.
    func testASlotsOwnFrameComingRoundAgainConvertsNothing() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        for slot in 0..<3 { book.written(slot, top: 100, columns: 80, held: rows) }
        XCTAssertTrue(book.plan(0, rows: rows, top: 100, columns: 80, overturned: false).nothing)
    }

    /// The premise the whole cache rests on: an array is copied when it is
    /// written to, so a row a slot holds cannot be written under it. A scene
    /// is a copy of each row, and decorating the copy — which is what the
    /// frame does with a hyperlink under the pointer — leaves the held row
    /// saying what it said, so the rest of the frame is still kept.
    func testARowHeldIsARowNobodyCanWriteUnder() {
        var book = TerminalCells(ring: 1)
        var scene = frame(2)
        book.written(0, top: 0, columns: 80, held: scene)
        scene[1].cells[0].char = "x"
        XCTAssertEqual(
            book.plan(0, rows: scene, top: 0, columns: 80, overturned: false).ranges, [1..<2],
            "the decorated row is the only one converted"
        )
        XCTAssertEqual(book.slot(0).held[1].cells[0].char, " ", "and the held row is untouched")
    }

    /// A different shape — a resize, a face whose cell measures differently
    /// — leaves nothing of the slot worth keeping, however few rows it is.
    func testADifferentShapeIsWhole() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)
        XCTAssertTrue(book.plan(0, rows: frame(24, 81), top: 100, columns: 81, overturned: false).whole)
        XCTAssertTrue(book.plan(0, rows: frame(23), top: 100, columns: 80, overturned: false).whole)
        XCTAssertTrue(book.plan(0, rows: [], top: 100, columns: 80, overturned: false).whole)
    }

    /// A screen turned over — the alternate screen, a resize, a dropped
    /// scrollback — is a frame no slot was written from, however much of it
    /// looks the same.
    func testATurnedOverScreenIsWhole() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)
        XCTAssertTrue(book.plan(0, rows: rows, top: 100, columns: 80, overturned: true).whole)
    }

    /// Forgetting is what a change of theme, or of the size a cell is cut
    /// at, comes to: nothing any slot holds is trusted afterwards.
    func testForgettingEmptiesEverySlot() {
        var book = TerminalCells(ring: 3)
        for slot in 0..<3 { book.written(slot, top: 100, columns: 80, held: frame(24)) }
        book.forget()
        for slot in 0..<3 {
            XCTAssertNil(book.slot(slot).top, "slot \(slot) is empty again")
            XCTAssertTrue(book.slot(slot).held.isEmpty, "and is holding no rows")
            XCTAssertTrue(
                book.plan(slot, rows: frame(24), top: 100, columns: 80, overturned: false).whole
            )
        }
    }

    /// Adjacent rows come back as one range, and gaps as more than one: a
    /// copy per range is what converting a frame costs.
    func testBandsMergeWhatIsAdjacent() {
        XCTAssertEqual(TerminalCells.bands(of: []), [])
        XCTAssertEqual(TerminalCells.bands(of: [4]), [4..<5])
        XCTAssertEqual(TerminalCells.bands(of: [4, 5, 6]), [4..<7])
        XCTAssertEqual(TerminalCells.bands(of: [1, 2, 9]), [1..<3, 9..<10])
        XCTAssertEqual(TerminalCells.bands(of: [9, 1, 2, 9]), [1..<3, 9..<10], "out of order, and one of them twice")
        XCTAssertEqual(
            TerminalCells.bands(of: [21, 22, 23]), [(21..<24)],
            "the band a scroll of three uncovers"
        )
    }

    /// A plan for a slot that already says what the frame does is the empty
    /// case, and says the frame costs nothing.
    func testAnEmptyPlanSaysNothingIsDone() {
        var book = TerminalCells(ring: 3)
        let rows = frame(24)
        book.written(0, top: 100, columns: 80, held: rows)
        let plan = book.plan(0, rows: rows, top: 100, columns: 80, overturned: false)
        XCTAssertTrue(plan.nothing)
        XCTAssertEqual(plan, TerminalCells.Plan())
    }
}
