import XCTest
@testable import Search

/// When a terminal draws: the reasons a frame is owed, and the promise that
/// none of them owing means no frame at all.
///
/// There is no display in here. A pacer with no link to wait for draws on
/// the wall clock, which is the same decision a tick of the link makes, so
/// the decisions are all testable and only the cadence is not: a burst
/// coalescing into one frame and a caret blinking on the half-second want a
/// clock that keeps running between two calls, and that is a display
/// link's to give (the app is where that is seen).
@MainActor
final class TerminalPacerTests: XCTestCase {
    /// A pacer with nothing to wait for, and a count of the frames it drew.
    private func bare() -> (TerminalPacer, () -> Int) {
        let pacer = TerminalPacer()
        var frames = 0
        pacer.draw = { frames += 1 }
        pacer.makeLink = { nil }
        return (pacer, { frames })
    }

    /// One ask, one frame, and then nothing owed — which is the very
    /// condition the clock stops on. This is the promise the whole file
    /// exists for: an idle terminal draws no frames, not fewer.
    func testAOneFrameAskIsDrawnAndForgetsItself() {
        let (pacer, frames) = bare()
        pacer.want(.once)
        XCTAssertEqual(frames(), 1, "the ask was drawn")
        XCTAssertTrue(pacer.purpose.isEmpty, "nothing owed: the clock would stop here")
    }

    /// The caret is a reason to keep the clock, and on its own it draws
    /// nothing: a frame is owed only when it blinks, which is measured
    /// against the clock rather than counted in ticks.
    func testTheCaretKeepsTheClockAndDrawsNothingOnItsOwn() {
        let (pacer, frames) = bare()
        pacer.want(.caret)
        XCTAssertEqual(frames(), 0, "nothing has blinked yet")
        XCTAssertEqual(pacer.purpose, [.caret], "the caret is still a reason to tick")
        XCTAssertTrue(pacer.caretShown, "and it shows until the clock says otherwise")
    }

    /// Losing the keyboard settles the caret: it shows, and the frame that
    /// shows it is asked for — so a caret that had blinked out does not
    /// wait up to half a second to come back.
    func testSettlingTheCaretDrawsItOnceAndStopsTicking() {
        let (pacer, frames) = bare()
        pacer.want(.caret)
        pacer.settleCaret()
        XCTAssertEqual(frames(), 1, "the frame that puts the caret back")
        XCTAssertTrue(pacer.caretShown)
        XCTAssertTrue(pacer.purpose.isEmpty, "and the clock stops with it")
    }

    /// A program holding the screen (synchronized output, 2026) gets no
    /// frames however much arrives, and the frame it was holding back is
    /// owed the moment it lets go.
    func testAHoldHoldsEveryFrameUntilItIsLetGo() {
        let (pacer, frames) = bare()
        pacer.want(.hold)
        pacer.want(.once)
        pacer.want(.once)
        XCTAssertEqual(frames(), 0, "held: nothing shows")
        XCTAssertEqual(pacer.purpose, [.hold, .once], "what arrived is still owed")
        pacer.release()
        XCTAssertEqual(frames(), 1, "one frame, with all of it in it")
        XCTAssertTrue(pacer.purpose.isEmpty)
    }

    /// A program that takes hold of the screen and then dies — a crash, a
    /// kill, a sunken ssh — never lets go, and a terminal that waited for
    /// it would never draw again. The hold is timed out instead: past its
    /// patience the frames are owed regardless, and the first of them
    /// shows everything that arrived while it held.
    func testAHoldThatOutlastsItsPatienceIsLetGoAnyway() {
        let (pacer, frames) = bare()
        let at = CACurrentMediaTime()
        pacer.want(.hold)
        pacer.want(.once)
        pacer.tick(now: at)
        pacer.tick(now: at + 0.5)
        XCTAssertEqual(frames(), 0, "still held, and still inside its patience")
        XCTAssertEqual(pacer.purpose, [.hold, .once], "and everything that arrived is still owed")
        pacer.tick(now: at + 1.5)
        XCTAssertEqual(frames(), 1, "past its patience, the screen is drawn")
        XCTAssertTrue(pacer.purpose.isEmpty)
    }

    /// A hold that lets go in time is a hold like any other: the timeout
    /// is there for the program that never does, not to hurry the one that
    /// does.
    func testAHoldInsideItsPatienceIsNotLetGo() {
        let (pacer, frames) = bare()
        let at = CACurrentMediaTime()
        pacer.want(.hold)
        pacer.tick(now: at + 0.9)
        XCTAssertEqual(frames(), 0)
        XCTAssertEqual(pacer.purpose, [.hold])
    }

    /// The terminal left its window: no reason survives it, so nothing is
    /// left ticking for a view that has no display to tick on.
    func testLeavingTheWindowDropsEveryReason() {
        let (pacer, frames) = bare()
        pacer.want(.once)
        pacer.want(.caret)
        pacer.want(.hold)
        pacer.detach()
        XCTAssertTrue(pacer.purpose.isEmpty)
        XCTAssertTrue(pacer.caretShown)
        XCTAssertEqual(frames(), 1, "the frames already drawn are not undrawn")
    }
}
