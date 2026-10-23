import XCTest
@testable import Search

/// The find panel's manners (see TerminalField): Metalterm's curves, walked
/// without a screen.
///
/// The curves themselves are pure — a normalized leg in, a fraction out — so
/// the shapes are checked here directly, and then the engine is walked one
/// frame at a time to see that the things the curves are made of actually
/// happen: a head that arrives in a sixth of the leg, a tail that trails it,
/// a ghost in the gap, a bleed on every keystroke, and a squeeze that is spent
/// by the time the plate stops.
@MainActor
final class TerminalFieldTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "terminal-field-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - the curves

    /// The head is Metalterm's quartic ease-out over the first 17% of the
    /// leg: at a sixth of the way it is already all but arrived, which is
    /// what makes a thing read as thrown rather than as dragged.
    func testTheHeadArrivesEarlyOnAQuartic() {
        XCTAssertEqual(FieldCurve.head(0), 0, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.head(1), 1, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.head(0.17), 1, accuracy: 1e-12, "the head is done at 17% of the leg")
        // 1 − (1 − p)⁴ at a quarter of the window.
        let quarter = 1 - 0.75 * 0.75 * 0.75 * 0.75
        XCTAssertEqual(FieldCurve.head(0.17 / 4), quarter, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.head(0.5), 1, accuracy: 1e-12, "and stays arrived")
    }

    /// The tail is a cubic ease-in-out delayed 5% and stretched over a fifth
    /// of the leg: still at rest when the head is already most of the way,
    /// which is the whole of the smear.
    func testTheTailLagsTheHeadAndCatchesItUp() {
        XCTAssertEqual(FieldCurve.tail(0), 0, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.tail(0.05), 0, accuracy: 1e-12, "the delay")
        XCTAssertLessThan(FieldCurve.tail(0.1), FieldCurve.head(0.1), "the tail is behind")
        XCTAssertEqual(FieldCurve.tail(0.25), 1, accuracy: 1e-12, "the stretch ends at 25%")
        XCTAssertEqual(FieldCurve.tail(1), 1, accuracy: 1e-12)
        // 4q³ below the half, 1 − ½(2 − 2q)³ above it.
        let q = 0.1 / 5.0                       // a tenth of the way through the window
        XCTAssertEqual(FieldCurve.tail(0.05 + q * 0.2), 4 * q * q * q, accuracy: 1e-12)
    }

    /// The bleed is a dip: opaque, out at 35%, opaque again — a keystroke has
    /// to look like one, and a bar that only slid would look like it had
    /// always been there.
    func testTheBleedIsATriangleWithItsFloorAtThirtyFive() {
        XCTAssertEqual(FieldCurve.bleed(0), 1, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.bleed(0.35), 0, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.bleed(1), 1, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.bleed(0.175), 0.5, accuracy: 1e-12, "half way down")
        XCTAssertEqual(FieldCurve.bleed(0.675), 0.5, accuracy: 1e-12, "half way back up")
        XCTAssertEqual(FieldCurve.bleed(-1), 1, accuracy: 1e-12, "clamped")
    }

    /// `squash`: a plate moving at a thousand points a second is at its
    /// thinnest, and one that is still is exactly one.
    func testTheSqueezeIsSpentByTheTimeItStops() {
        XCTAssertEqual(FieldCurve.squash(0), 1, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.squash(1_000), 1 / 1.3, accuracy: 1e-12, "the floor")
        XCTAssertEqual(FieldCurve.squash(2_000), 1 / 1.3, accuracy: 1e-12, "and it does not pass it")
        // 1 + 1/0.00933… is where the floor is first met.
        let knee = (1.3 - 1) / 0.009333333333333334
        XCTAssertEqual(FieldCurve.squash(CGFloat(knee)), 1 / 1.3, accuracy: 1e-9)
    }

    /// The plate's own curve, which is the one number here that is not
    /// Metalterm's: a caret is a cell and can blink in and out; a plate is a
    /// third of the window, so it fades in on a smoothstep over the head's
    /// own window and is whole exactly when it has arrived.
    func testThePlateFadesInOverTheHeadWindowRatherThanAppearing() {
        XCTAssertEqual(FieldCurve.fade(0), 0, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.fade(0.17), 1, accuracy: 1e-12, "whole when it has arrived")
        XCTAssertEqual(FieldCurve.fade(1), 1, accuracy: 1e-12)
        XCTAssertEqual(FieldCurve.fade(0.085), 0.5, accuracy: 1e-12, "half way in")
        XCTAssertLessThan(FieldCurve.fade(0.04), FieldCurve.head(0.04) / 2, "slower off the mark than the head")
        XCTAssertGreaterThan(FieldCurve.fade(0.01), 0, "but never a cut")
    }

    /// The squeeze is read off the head's own slope, not off a distance: a
    /// plate is thinnest the instant it is thrown and whole when it lands.
    func testTheSqueezeIsThinnestAtTheThrowAndWholeOnArrival() {
        XCTAssertEqual(FieldCurve.squeezeAt(0), 1 / 1.3, accuracy: 1e-9, "its floor at the throw")
        XCTAssertEqual(FieldCurve.squeezeAt(0.17), 1, accuracy: 1e-9, "whole on arrival")
        XCTAssertEqual(FieldCurve.squeezeAt(1), 1, accuracy: 1e-9)
        let middle = FieldCurve.squeezeAt(0.06)
        XCTAssertGreaterThan(middle, 1 / 1.3)
        XCTAssertLessThan(middle, 1)
    }

    // MARK: - the travel

    /// A panel that has never been anywhere is nowhere, and asks for no
    /// frames: that is the promise the pacer makes, and the panel keeps it.
    func testAnUnopenedPanelIsAwayAndWantsNothing() {
        let field = TerminalField()
        XCTAssertTrue(field.isAway)
        XCTAssertFalse(field.moving(at: 0))
        XCTAssertEqual(field.advance(at: 0).body, 0, "nothing to draw")
    }

    /// Arriving: the plate starts off its own right edge, fades in on the
    /// way, and is still at the end of the travel — with the smear closed,
    /// because two curves that have met are one curve.
    func testArrivingTravelsAndThenRests() {
        let field = TerminalField()
        field.arrive(200, wide: 260, at: 0)
        XCTAssertTrue(field.moving(at: 0))

        let start = field.advance(at: 0)
        XCTAssertEqual(start.tail, 460, accuracy: 0.5, "off its own right edge")
        XCTAssertEqual(start.head, 460, accuracy: 0.5, "both curves, together")
        XCTAssertEqual(start.smear, 0, accuracy: 1e-9, "so no smear yet")
        XCTAssertEqual(start.body, 0, accuracy: 1e-9, "and not yet visible")

        let middle = field.advance(at: FieldMotion.arrive * 0.1)
        XCTAssertLessThan(middle.tail, 460)
        XCTAssertGreaterThan(middle.tail, 200)
        XCTAssertLessThanOrEqual(middle.head, middle.tail, "the light runs ahead")
        XCTAssertGreaterThan(middle.smear, 0, "with terminal showing in the gap")
        XCTAssertGreaterThan(middle.body, 0, "and coming in")

        let end = field.advance(at: FieldMotion.arrive)
        XCTAssertEqual(end.tail, 200, accuracy: 0.5, "arrived")
        XCTAssertEqual(end.body, 1, accuracy: 1e-9)
        XCTAssertEqual(end.smear, 0, accuracy: 0.01, "the gap has closed")
        XCTAssertFalse(field.moving(at: FieldMotion.arrive), "and the clock can stop")
        XCTAssertFalse(field.isAway, "still open, just still")
    }

    /// Leaving: the plate fades out on the head's own curve and is let go
    /// when the leg ends — a close the frame finishes, not a cut.
    func testLeavingFadesOutAndEndsAway() {
        let field = TerminalField()
        field.settle(200, wide: 260)
        field.leave(at: 0)
        XCTAssertTrue(field.isLeaving)

        let middle = field.advance(at: FieldMotion.leave * 0.06)
        XCTAssertGreaterThan(middle.tail, 200)
        XCTAssertLessThan(middle.body, 1)
        XCTAssertGreaterThan(middle.body, 0)

        let end = field.advance(at: FieldMotion.leave)
        XCTAssertTrue(field.isAway, "gone")
        XCTAssertFalse(field.moving(at: FieldMotion.leave))
    }

    /// A count that grew moves the plate's leading edge out on a leg of its
    /// own — and a layout that changed nothing moves nothing at all.
    func testAStillPanelStaysStillUnlessItsEdgeMoved() {
        let field = TerminalField()
        field.settle(200, wide: 260)
        XCTAssertFalse(field.moving(at: 0))

        field.place(200, wide: 260, at: 1)
        XCTAssertFalse(field.moving(at: 1), "the same edge is no leg")

        field.place(160, wide: 300, at: 2)
        XCTAssertTrue(field.moving(at: 2), "a wider count pushes the edge out")
        let moved = field.advance(at: 2 + FieldMotion.settle * 0.1)
        XCTAssertLessThan(moved.head, 200)
        XCTAssertGreaterThan(moved.head, 160)
        XCTAssertEqual(moved.body, 1, accuracy: 1e-9, "already there: it does not fade")
    }

    /// A leg retargeted mid-flight restarts from wherever the head is, which
    /// is where a thrown thing actually is — not from where it started.
    func testARetargetedLegLeavesFromWhereItActuallyIs() {
        let field = TerminalField()
        field.arrive(200, wide: 260, at: 0)
        let half = field.advance(at: FieldMotion.arrive * 0.05)
        field.place(120, wide: 260, at: FieldMotion.arrive * 0.05)
        let after = field.advance(at: FieldMotion.arrive * 0.05)
        XCTAssertEqual(after.head, half.head, accuracy: 0.001, "no jump")

        let end = field.advance(at: FieldMotion.arrive * 0.05 + FieldMotion.settle)
        XCTAssertEqual(end.head, 120, accuracy: 0.5, "and it arrives at the new place")
    }

    // MARK: - the keystroke

    /// A keystroke bleeds the edge once, over a fifth of the leg it happened
    /// during, and asks for frames until the dip is over — even though
    /// nothing else about the panel moved.
    func testAKeystrokeBleedsOnceAndWantsFramesUntilItIsOver() {
        let field = TerminalField()
        field.settle(200, wide: 260)
        XCTAssertFalse(field.moving(at: 100))

        field.press(at: 100)
        XCTAssertTrue(field.moving(at: 100), "the bleed owes frames")
        XCTAssertEqual(field.advance(at: 100).edgeAlpha, 1, accuracy: 1e-9, "opaque at once")

        let window = FieldMotion.settle * 0.2
        let dip = field.advance(at: 100 + window * 0.35)
        XCTAssertEqual(dip.edgeAlpha, 0, accuracy: 1e-9, "gone at 35% of it")
        XCTAssertEqual(field.advance(at: 100 + window * 0.7).edgeAlpha, 0.54, accuracy: 0.01)
        XCTAssertFalse(field.moving(at: 100 + window + 1e-9), "and it is over when it is over")
        XCTAssertEqual(field.advance(at: 100 + window).edgeAlpha, 1, accuracy: 1e-9)
    }

    /// The squeeze is a reading of speed, not of distance: a plate that has
    /// arrived is exactly as wide as it said, and one in the middle of a long
    /// leg is thinner.
    func testThePlateIsThinnestWhileItIsMovingFastest() {
        let field = TerminalField()
        field.arrive(200, wide: 260, at: 0)
        let start = field.advance(at: 0)
        let end = field.advance(at: FieldMotion.arrive)
        XCTAssertLessThan(start.squeeze, 1, "a shove is a squeeze")
        XCTAssertGreaterThanOrEqual(end.squeeze, 0.999, "and it is over when it stops")
    }

    // MARK: - where it hangs

    /// The panel's right edge is pinned and its left one is where the travel
    /// happens, at either end of the frame — the one thing the setting changes
    /// is which end that is, and the box is the same size either way.
    func testThePanelHangsOffTheFramesRightEdgeAtEitherEnd() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let top = FieldBox.home(wide: 260, in: frame, at: .top)
        let bottom = FieldBox.home(wide: 260, in: frame, at: .bottom)

        XCTAssertEqual(top.width, 260)
        XCTAssertEqual(bottom.width, 260)
        XCTAssertEqual(top.height, bottom.height, "the same plate either way")
        XCTAssertEqual(top.leading + top.width, frame.width - FieldBox.margin, "pinned right")
        XCTAssertEqual(bottom.leading + bottom.width, frame.width - FieldBox.margin)
        XCTAssertEqual(top.leading, bottom.leading, "and its left edge is where it was")

        // The view is not flipped, so the top is a large y and the bottom a
        // small one — and neither runs off the frame.
        XCTAssertEqual(bottom.y, FieldBox.edge)
        XCTAssertEqual(top.y, frame.height - FieldBox.edge - top.height)
        XCTAssertGreaterThan(top.y, bottom.y)
        XCTAssertGreaterThanOrEqual(bottom.y, 0)
        XCTAssertLessThanOrEqual(top.y + top.height, frame.height)
    }

    /// A frame too narrow for the width the words want gets what there is,
    /// less a margin at each side, and never so little that there is no room
    /// for a word — a plate narrower than its own padding is not a plate.
    func testANarrowFrameKeepsAMarginAndStillLeavesRoomForWords() {
        let cramped = FieldBox.home(wide: 260, in: CGRect(x: 0, y: 0, width: 250, height: 400), at: .top)
        XCTAssertEqual(cramped.width, 222, "250 less a margin at each side")
        XCTAssertEqual(cramped.leading, FieldBox.margin)
        XCTAssertGreaterThanOrEqual(cramped.leading, 0)

        // A frame that would leave less than the floor keeps the floor: a
        // plate with no room for a word in it is not worth drawing.
        let absurd = FieldBox.home(wide: 260, in: CGRect(x: 0, y: 0, width: 40, height: 400), at: .bottom)
        XCTAssertEqual(absurd.width, 120, "the floor")
        XCTAssertEqual(absurd.leading, 40 - FieldBox.margin - 120, "and it runs off the left, which is what a floor means")
    }

    /// The same place, said top-down for a view that measures from the top:
    /// a flipped pane stage, or a SwiftUI overlay's own alignment. One plate,
    /// measured from either end, is the same plate.
    func testThePlaceSaidTopDownIsTheSamePlace() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        for place in TerminalFindPlace.allCases {
            let up = FieldBox.home(wide: 260, in: frame, at: place)
            let down = FieldBox.top(wide: 260, in: frame, at: place)
            XCTAssertEqual(down.leading, up.leading, "\(place)")
            XCTAssertEqual(down.width, up.width)
            XCTAssertEqual(down.height, up.height)
            XCTAssertEqual(down.y, frame.height - up.y - up.height, "\(place)")
        }
        // Over the top corner is a small distance from the top, and over the
        // bottom one a large one — the two ends swap over when the measurement
        // does.
        XCTAssertLessThan(FieldBox.top(wide: 260, in: frame, at: .top).y,
                          FieldBox.top(wide: 260, in: frame, at: .bottom).y)
    }
}
