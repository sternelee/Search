import AppKit
import QuartzCore

// When a terminal draws, and what it draws for.
//
// Nothing here draws: it decides that a frame is owed, and says so. A
// terminal has three reasons to draw and no others — something came out of
// the program, the caret blinked, or a program that was holding the screen
// with synchronized output (2026) has let go — and any one of them wanting
// a frame keeps a display link running. With none of them wanting one the
// link is paused, which is the whole of "no frames when idle": not fewer
// frames, none. The promise used to be broken by the caret alone, whose
// timer ran on for every terminal that was merely on screen.
//
// The clock is the display's own, so a terminal scrolls at the rate the
// screen actually has — 120 on a ProMotion one, where a timer would have
// gone on stepping at whatever interval it was made with. It also gives
// the blink a clock to be measured against rather than a count of
// firings, and measuring is what makes it survive a pause: a link stopped
// while a tab was in the background comes back on the half of the blink it
// belongs on instead of wherever wall time had got to.
//
// A frame owed is not a frame drawn at once: the reasons accumulate until
// the next tick, so a reading that arrives as a thousand lines is one
// frame rather than a thousand, and a keystroke never costs more than the
// frame it belongs to.

@MainActor
final class TerminalPacer {
    /// Why a frame is owed. The set being empty is what stops the clock.
    struct Purpose: OptionSet {
        let rawValue: Int
        /// The caret is blinking, and this is what keeps time for it. Held
        /// only while the keyboard is in the terminal and the caret is on
        /// screen — a terminal nobody is typing into has no caret to blink.
        static let caret = Purpose(rawValue: 1 << 1)
        /// One frame, then nothing: something the program printed, a
        /// layout, a new selection, a scroll, a find stepping to its match.
        static let once = Purpose(rawValue: 1 << 2)
        /// A program is holding the screen (synchronized output, 2026).
        /// Nothing shows until it lets go, however much arrives meanwhile.
        static let hold = Purpose(rawValue: 1 << 3)
    }

    /// Twice a second, which is what a Mac's own caret blinks at.
    private static let blink: CFTimeInterval = 0.5

    /// How long a program may hold the screen before the frames are let
    /// through anyway. A program that sets 2026 and then dies before it
    /// unsets it would otherwise leave a terminal that never draws again,
    /// which is a worse thing to own than one drawn mid-composition: a
    /// frame of half a screen is a flicker, and this is a hang.
    private static let patience: CFTimeInterval = 1

    /// Draws one frame. The view that owns the pacer puts its own frame
    /// here, and is the only thing that ever asks for one.
    var draw: (() -> Void)?

    /// A display link off the view's own screen, or nil when there is no
    /// screen to keep time by — a test's window, or one built off every
    /// one. With none, a frame owed is a frame drawn at once, and the wall
    /// clock stands in for the blink.
    var makeLink: (() -> CADisplayLink?)?

    /// What is owed a frame right now.
    private(set) var purpose: Purpose = []
    /// Whether the caret shows in the frame now being drawn. Only the
    /// clock in here moves it; the view reads it as it draws.
    private(set) var caretShown = true

    private var link: CADisplayLink?
    private var blinkedAt: CFTimeInterval = 0
    /// When the program took hold of the screen, so the hold can be timed
    /// out rather than trusted (see `patience`).
    private var heldAt: CFTimeInterval = 0

    // MARK: - asking

    /// Something a frame would show. The frame follows on the next tick of
    /// the display's clock — or at once, when there is no display to wait
    /// for one.
    func want(_ reason: Purpose) {
        purpose.insert(reason)
        if reason == .hold { heldAt = CACurrentMediaTime() }
        // The clock starts even for a hold, because a hold is the one
        // thing that has to be measured: nothing else can notice a
        // program that never lets go.
        start()
        if link == nil { tick(now: CACurrentMediaTime()) }
    }

    /// The caret is no longer a reason to keep ticking: it shows, and the
    /// frame that shows it is asked for once. A terminal that loses the
    /// keyboard gets its caret back in the same frame that takes it away,
    /// rather than up to half a second later.
    func settleCaret() {
        purpose.remove(.caret)
        caretShown = true
        want(.once)
    }

    /// A program that was holding the screen has let go: the frame it was
    /// holding back is owed now, and it is the one that shows everything
    /// that arrived while it held.
    func release() {
        purpose.remove(.hold)
        want(.once)
    }

    /// No frame is wanted at all: the terminal left its window, or is
    /// being taken down. The link goes with it, so nothing is left ticking
    /// for a view that is gone — a display link holds its target, and a
    /// view holding a pacer holding a link is a ring nothing else breaks.
    func detach() {
        link?.invalidate()
        link = nil
        purpose = []
        caretShown = true
    }

    // MARK: - the clock

    private func start() {
        if let link {
            link.isPaused = false
            return
        }
        // The blink's phase starts with the clock, whether the clock is a
        // display link or the wall clock standing in for one. Started from
        // anywhere else, the half-second it is measured against would be
        // counted from zero, and the first frame of every caret would be a
        // blink already overdue.
        blinkedAt = CACurrentMediaTime()
        guard let made = makeLink?() else { return }
        // The screen's own rate, and no lower than this: a caret quantised
        // below about thirty reads as a stutter rather than a blink.
        made.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        made.add(to: .main, forMode: .common)
        link = made
    }

    private func stop() { link?.isPaused = true }

    /// One tick. Internal, and @objc, because the link is made by the view
    /// — a pacer has no view of its own, and `NSView.displayLink` is the
    /// only way to one that is sure to come from the right display.
    @objc func tick(_ link: CADisplayLink) { tick(now: link.timestamp) }

    /// The frame decision, the same whether the time came from a display
    /// link or from the wall clock standing in for one — and the same,
    /// too, when a test hands it a time of its own, which is the only way
    /// to see a blink or a held screen that outlasts its patience without
    /// waiting for one.
    func tick(now: CFTimeInterval) {
        // The blink first, so a frame drawn for another reason is already
        // on the right half of it rather than showing a caret that should
        // have blinked out.
        var flipped = false
        if purpose.contains(.caret), now - blinkedAt >= TerminalPacer.blink {
            blinkedAt = now
            caretShown.toggle()
            flipped = true
        }

        // A program holding the screen gets no frames until it lets go.
        // What arrives meanwhile keeps arriving into the screen; the frame
        // that comes when it lets go is the one that shows all of it. Held
        // for longer than `patience`, though, it is not holding anything:
        // it is gone, and the frames are owed regardless.
        if purpose.contains(.hold) {
            guard now - heldAt >= TerminalPacer.patience else { return }
            purpose.remove(.hold)
        }

        let owed = flipped || purpose.contains(.once)
        guard owed else { return }
        purpose.remove(.once)
        draw?()
        if purpose.isEmpty { stop() }
    }
}
