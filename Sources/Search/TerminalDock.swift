import AppKit
import QuartzCore

// The input dock: the terminal's bottom plate that stands in for the
// prompt while the shell's own line editor holds the line.
//
// Metalterm's dock is its furniture and TERMINAL.md once left it alone for
// that — but the user asked for Metalterm's terminal, the whole of it, and
// the dock is half of what that is: not a bar of chrome but the prompt's
// other half, drawn where the prompt is being typed and hiding the shell's
// own echo of it until the command runs. The motion in it is the same
// motion the find panel already carries (see TerminalField, where the
// curves were read out of Metalterm's arm64): the caret travels on the
// warp's head and tail with the smear between them, and every keystroke
// bleeds it once. What is new here is the protocol that makes a dock
// possible at all without teaching the terminal to be an editor:
//
//   OSC 7784;buf;<cursor>;<text>;<suggestion>  the shell's editor reports
//                                               its line before zle redraws
//   OSC 7784;off                                too long or wrapped: the
//                                               grid takes the input back
//   ESC [27;9;71~<len>;<col>~                   a click in the dock, as a
//                                               column the editor moves
//                                               its caret to
//
// The script that prints the reports lives in TerminalShell (zsh, wrapped
// through its own ZDOTDIR); the marks that frame each command still arrive
// by the grid (OSC 133, see TerminalParse), and the turn of them is the
// dock's news: `C` lifts the veil — the line became a command, its echo
// became history — and `A` drops whatever line the dock was holding,
// because a new prompt's report is coming and "empty again" is every
// Ctrl-C at an empty one.
//
// The veil itself is the hover underline's trick at a larger scale: while
// the dock owns the input, the frame blanks the prompt's rows in the copy
// of the scene it is about to read, and the renderer's own damage makes
// the rows new again. The program's keystrokes are untouched — the editor
// on the other end of the pipe is still the one doing the editing, which
// is why a dock can stand in for bash as easily as zsh, and why nothing
// here parses the line it is handed beyond unescaping it.

/// The dock's measurements, in points. Metalterm's own dock spans the
/// width of its terminal with the input on the left of a translucent
/// ground; the numbers here are the find panel's scale (see FieldBox)
/// read at the bottom of the frame, where Metalterm puts its own.
enum DockBox {
    /// How tall the plate is.
    static let height: CGFloat = 30
    /// The gap at the frame's left and right, matching the find panel's
    /// inset, so the two boxes belong to the same window.
    static let margin: CGFloat = 14
    /// The gap at the frame's bottom — a plate further in than this sits
    /// over the last row of a running command's output, which it does
    /// anyway (the ground is translucent for exactly that), but the
    /// hairline should clear the frame's own edge.
    static let edge: CGFloat = 12
    /// The room the plate leaves before the prompt glyph.
    static let pad: CGFloat = 10
    /// Between the prompt glyph and the line.
    static let gap: CGFloat = 7
    /// The caret's width.
    static let bar: CGFloat = 2
    /// How far a glyph rises on arrival, and the window it rises in:
    /// Metalterm's `rise` keypress — a fifth of a window, which is the
    /// caret's own share of one (see `FieldCurve.bleed`).
    static let rise: CGFloat = 2.5
    static let arrive: CFTimeInterval = 0.2
    /// How faint the suggestion ghost is.
    static let ghost: CGFloat = 0.45
    /// The ground's opacity: the find panel's own, because the plate is
    /// the same furniture — and the rows it stands over are the shell's
    /// echo, blank under the veil, not a running command's last line.
    static let ground: CGFloat = 0.82

    /// Where the plate goes for a frame of a given size: pinned to the
    /// bottom — above the status bar, which owns the frame's own edge —
    /// spanning the width less a margin each side. Pure, so the place can
    /// be checked without a terminal.
    static func home(in bounds: CGRect, above bar: CGFloat) -> CGRect {
        let width = max(120, bounds.width - margin * 2)
        return NSRect(x: margin, y: edge + bar, width: width, height: height)
    }
}

/// Which glyphs of a line are new, for the arrival each one is owed. Pure,
/// because it is the half of typing that has to be exactly right: a
/// keystroke that appends marks only what it appended, and a line that did
/// not type itself — a rewrite in the middle, an accept from history —
/// arrives whole and already there, which is how Metalterm treats those.
enum DockLedger {
    /// The arrival of a glyph old enough that no frame owes it anything.
    static let settled: CFTimeInterval = 0

    static func arrivals(
        for said: String, after was: String, holding old: [CFTimeInterval], at now: CFTimeInterval
    ) -> [CFTimeInterval] {
        // Nothing changed in the line: every glyph keeps the arrival it
        // had — a caret that only moved is not a glyph that arrived.
        guard said != was else { return old }
        // An append: the glyphs that were there keep their arrivals, and
        // the ones the keystroke put on the end get one each.
        if said.hasPrefix(was), old.count == was.count {
            return old + Array(repeating: now, count: said.count - was.count)
        }
        return Array(repeating: settled, count: said.count)
    }
}

/// The dock's own state — no view, no clock of its own, everything driven
/// by the reports and the marks, so it can be walked by a test one frame at
/// a time. The line it holds is in characters (the shell counts them the
/// same way), and the caret is walked in columns on the find panel's own
/// curves (TerminalField), which is Metalterm's caret to the number.
@MainActor
final class TerminalDock {
    /// What one frame wants drawn.
    struct Model {
        /// Whether the dock owns the input — the veil's question.
        var owns = false
        /// The plate's opacity: arriving on the find panel's own fade,
        /// whole when it has landed.
        var plate: CGFloat = 0
        /// The line's opacity, while the empty report after an accepted
        /// line fades it out where it stood.
        var line: CGFloat = 1
        var text = ""
        var cursor = 0
        var suggestion = ""
        /// One arrival per glyph, `DockLedger.settled` for the ones no
        /// frame owes anything.
        var arrivals: [CFTimeInterval] = []
        /// The caret, in columns, on the warp's curves.
        var caret = TerminalField.Model()
    }

    private enum Plate { case gone, arriving, shown, leaving }
    private var plate: Plate = .gone
    private var plateAt: CFTimeInterval = 0

    /// Whether the shell's editor still holds the line (OSC 7784 `buf`).
    /// The veil follows this and nothing else.
    private(set) var owns = false
    /// The line as the shell's editor holds it — characters, counted the
    /// way the script counts them. Read by the view to answer a click with
    // a column the editor can move to.
    private(set) var text = ""
    private(set) var cursor = 0
    private var suggestion = ""
    private var arrivals: [CFTimeInterval] = []

    /// The line is leaving: the empty report after the line was accepted,
    /// fading out where it stood over the window the find panel leaves in.
    private var lineLeaving = false
    private var lineAt: CFTimeInterval = 0

    /// When a keystroke last changed the line, and when the caret last came
    /// to rest somewhere — Metalterm's own two clocks for the blink: the
    /// caret is solid while the person is typing and for a moment after,
    /// and it gives up blinking entirely once it has been left alone long
    /// enough. A solid-on-solid caret is what "doesn't blink constantly"
    /// means, and it is why the dock keeps these itself.
    private var keyAt: CFTimeInterval = 0
    private var caretAt: CFTimeInterval = 0

    /// The caret, on the find panel's engine — a move is a leg, a
    /// keystroke a bleed, at rest the two curves are one bar.
    let caret = TerminalField()

    /// Whether a plate is owed at all: the first report makes one, and the
    /// frame that finishes an `off` collapse is what ends it.
    var owed: Bool { plate != .gone }

    /// The rows of a frame the veil covers while the dock stands in for
    /// the prompt: from the prompt's own row to the bottom of the screen —
    /// the shell's echo of the line being edited and everything under it.
    /// A prompt above the frame (scrolled away) veils nothing, and one
    /// that somehow is below it veils nothing either. Pure.
    static func veil(prompt: Int, top: Int, rows: Int) -> Range<Int>? {
        let row = prompt - top
        guard row >= 0, row < rows else { return nil }
        return row..<rows
    }

    // MARK: - the news

    /// The shell's editor reported its line (OSC 7784, TerminalParse's
    /// `dock`): the text, the caret's column counted in characters, the
    /// suggestion behind the text. The report says what the line is,
    /// never that it changed — this works the legs out, and a report that
    /// says nothing new owes nothing.
    func report(_ said: Dock, at now: CFTimeInterval) {
        switch said {
        case .off:
            // The editor gave the line up: too long, or wrapped, and the
            // grid takes the input back. The veil lifts and the plate
            // leaves; a report that comes back re-arrives it.
            owns = false
            lineLeaving = false
            guard plate != .gone else { return }
            plate = .leaving
            plateAt = now
        case .line(let said, let at, let ghost):
            // The first report of a prompt — or the first after an `off`
            // — arrives the plate. Reduced Motion gets it whole.
            if plate == .gone || plate == .leaving {
                plate = Motion.reduced ? .shown : .arriving
                plateAt = now
            }
            // The empty report after an accepted line — what line-finish
            // sends — fades the line already on the plate out where it
            // stands: the old line is what is drawn while it fades, and its
            // caret goes home with it. Nothing is a leg and nothing a
            // keystroke, because nothing was typed.
            if said.isEmpty, !text.isEmpty {
                lineLeaving = true
                lineAt = now
                caret.settle(0, wide: 0)
                caretAt = now
                return
            }
            // A keystroke interrupts the leaving fade of the line before
            // it: the line being typed is the line to draw.
            lineLeaving = false
            let was = text
            let wasAt = cursor
            arrivals = DockLedger.arrivals(for: said, after: was, holding: arrivals, at: now)
            text = said
            cursor = min(max(0, at), said.count)
            suggestion = ghost
            owns = true
            // The caret: settled the first time it is seen, and after that
            // a column that moved is a leg on the warp's curves, and a
            // line that changed — a keystroke — bleeds it once, wherever
            // the caret itself went.
            let column = CGFloat(cursor)
            if caret.isAway || Motion.reduced {
                caret.settle(column, wide: 0)
            } else {
                if cursor != wasAt { caret.place(column, wide: 0, at: now) }
                if said != was { caret.press(at: now) }
            }
            if said != was { keyAt = now }
            caretAt = now
        }
    }

    /// OSC 133 `C`: the line became a command. The veil lifts — the rows
    /// under the plate are the command's own echo now, and history. The
    /// plate stays for the next prompt with whatever is left of the line
    /// fading on it, which the empty report of line-finish already began.
    func ran(at now: CFTimeInterval) {
        owns = false
        if !text.isEmpty, !lineLeaving {
            lineLeaving = true
            lineAt = now
        }
    }

    /// OSC 133 `A`: a prompt block began. Whatever line the dock was
    /// holding — fading or not — is dropped at once, because the rows it
    /// stood in for are the shell's own now; and the next report, which
    /// every prompt sends even empty, re-establishes the line.
    func prompted(at now: CFTimeInterval) {
        owns = false
        lineLeaving = false
        text = ""
        cursor = 0
        suggestion = ""
        arrivals = []
        caret.settle(0, wide: 0)
    }

    // MARK: - what a frame is

    /// The alternate screen came up: a full-screen program — nvim, less,
    /// pi — owns the whole frame, and the dock is gone at once. No fade,
    /// because the program's first frame is already redrawing everything
    /// the plate stood over; and the shell's own prompt is still there
    /// under the swap, so the next report re-arrives the plate when the
    /// program lets go.
    func suspend() {
        owns = false
        lineLeaving = false
        dropLine(plate: true)
    }

    /// Whether the caret shows in the frame asked about. Metalterm's blink,
    /// read from its caret's own two clocks: solid while the line is being
    /// typed and for half a second after the last keystroke; then a sine —
    /// not a square toggle, so it fades in and out rather than jumping —
    /// for ten seconds of idleness, and solid again once the person has
    /// well and truly gone. A caret on a leg never blinks, because a
    /// moving thing is a visible thing. Reduced Motion and a caret the
    /// person has asked not to blink are solid, plainly.
    func blink(at now: CFTimeInterval) -> Bool {
        if !TerminalLook.blinks || Motion.reduced { return true }
        if caret.moving(at: now) { return true }
        if now - keyAt < 0.5 { return true }
        let left = now - caretAt
        if left >= 10 { return true }
        // A period of 1.8263637 s — Metalterm's number, a sine read against
        // it, and a threshold of -0.35, which is what makes it a soft blink
        // that spends more of its cycle visible than hidden.
        return sin(left / 1.8263637 * 2 * .pi) > -0.35
    }

    /// Whether the blink needs the clock at all: from the last keystroke
    /// to ten seconds past it. The frames the dock's own legs ask for are
    /// frames already; this is the ones in between — solid-at-first does
    /// not mean still, because the moment it stops being solid is a
    /// frame nobody else owes.
    func blinkClock(at now: CFTimeInterval) -> Bool {
        TerminalLook.blinks && !Motion.reduced && owns && now - keyAt < 10
    }

    /// Whether anything is still owed a frame: a plate arriving or
    /// leaving, a line fading out, a glyph still rising, or a caret on a
    /// leg. The question the view asks to keep its clock running.
    func moving(at now: CFTimeInterval) -> Bool {
        switch plate {
        case .arriving where !Self.faded(now - plateAt, over: FieldMotion.arrive),
             .leaving where !Self.faded(now - plateAt, over: FieldMotion.leave):
            return true
        case .gone, .shown, .arriving, .leaving: break
        }
        if lineLeaving, !Self.faded(now - lineAt, over: FieldMotion.leave) { return true }
        if arrivals.contains(where: { $0 > 0 && now - $0 < DockBox.arrive }) { return true }
        return caret.moving(at: now)
    }

    /// Everything the plate needs, for the instant asked about. The last
    /// frame of a fade ends it as it is read, so the caller learns the
    /// plate is gone from the frame that finishes it.
    func model(at now: CFTimeInterval) -> Model {
        var model = Model()
        switch plate {
        case .gone:
            return model
        case .arriving:
            model.plate = CGFloat(FieldCurve.fade(Double(now - plateAt) / FieldMotion.arrive))
            if model.plate >= 1 { plate = .shown }
        case .shown:
            model.plate = 1
        case .leaving:
            model.plate = 1 - CGFloat(FieldCurve.fade(Double(now - plateAt) / FieldMotion.leave))
            if model.plate <= 0 { dropLine(plate: true) }
        }
        if lineLeaving {
            model.line = 1 - CGFloat(FieldCurve.fade(Double(now - lineAt) / FieldMotion.leave))
            if model.line <= 0 { dropLine() }
        }
        // The plate outstayed the line: a command owns the rows now (or an
        // `off` did), and the dock's invitation goes with the line — no
        // prompt glyph hovering under a running command, waiting to be
        // typed at. The next prompt's report re-arrives the plate.
        if !owns, plate == .shown {
            plate = .leaving
            plateAt = now
        }
        model.owns = owns
        model.text = text
        model.cursor = cursor
        model.suggestion = suggestion
        model.arrivals = arrivals
        model.caret = caret.advance(at: now)
        return model
    }

    /// A fade spent: `FieldCurve.fade` is whole at 17% of its window — the
    /// head's own share, which is when a thrown thing has landed — so
    /// that is when an arriving plate is whole and a leaving one is gone.
    private static func faded(_ elapsed: CFTimeInterval, over window: CFTimeInterval) -> Bool {
        elapsed >= 0 && FieldCurve.fade(elapsed / window) >= 1
    }

    /// The line is over: drop what it held. With the plate, the whole dock
    /// is gone.
    private func dropLine(plate: Bool = false) {
        lineLeaving = false
        text = ""
        cursor = 0
        suggestion = ""
        arrivals = []
        if plate { self.plate = .gone }
    }
}

// MARK: - the plate

/// The dock as a view: a translucent ground with a hairline, the prompt
/// glyph, the line's glyphs rising as they arrive, the suggestion ghosted
/// after them, and the caret on Metalterm's warp curves. Scenery — it takes
/// no input itself; the terminal under it turns a click into a column, and
/// the input method's candidates are given the caret's rect to sit on.
///
/// Drawn by AppKit rather than the renderer because it is words rather
/// than cells, and it is put in the picture only when the picture changed:
/// the terminal under it redraws at the display's own rate while a
/// command runs, and a plate with nothing moving on it has no reason to
/// follow.
@MainActor
final class TerminalDockPlate: NSView {
    /// What the last frame wanted drawn, kept to see whether the next one
    /// is worth an AppKit draw at all.
    struct Picture: Equatable {
        var plate: CGFloat = 0
        var line: CGFloat = 1
        var text = ""
        var cursor = 0
        var suggestion = ""
        var arrivals: [CFTimeInterval] = []
        var head: CGFloat = 0
        var tail: CGFloat = 0
        var squeeze: CGFloat = 1
        var edge: CGFloat = 1
        var blink = true
    }

    private var picture = Picture()

    /// The face the dock writes with — the terminal's own, a step down
    /// from the grid like the find panel's field. Re-read when the look
    /// changes.
    private(set) var face = TerminalLook.face(size: 12)
    /// One cell's width in it, measured once per face rather than asked
    /// again every glyph.
    private(set) var advance: CGFloat = 0
    /// The line's own ink center, measured off the drawn digits — the one
    /// height the caret and the prompt are both put on, so the three read
    /// on a line the way the person reads them against each other.
    private(set) var caretMid: CGFloat = DockBox.height / 2
    /// How far the prompt glyph sits off that height, measured rather than
    /// guessed: the ❯ comes from a fallback font (the mono face has no
    /// such glyph) and lands where that font's metrics put it, not where
    /// the line's digits do.
    private(set) var promptDy: CGFloat = 0

    init() {
        super.init(frame: .zero)
        remeasure()
    }

    required init?(coder: NSCoder) { nil }

    /// A click is the terminal's to answer, not this plate's.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The look changed: the face, and with it the measure of a cell.
    func refont() {
        face = TerminalLook.face(size: 12)
        remeasure()
        needsDisplay = true
    }

    private func remeasure() {
        advance = ("0" as NSString).size(withAttributes: [.font: face as Any]).width.rounded(.up)
        // The digits' ink, drawn and scanned, becomes the height the
        // caret and the prompt are put on. Measured rather than derived
        // because no font metric survives a fallback: SF Mono has no ❯,
        // and the font that supplies it puts its ink ~1pt high next to
        // the digits' own — a face that has it drifts elsewhere.
        caretMid = Self.inkCenter(of: "0", in: face)
        promptDy = caretMid - Self.inkCenter(of: "❯", in: face)
    }

    /// Where a glyph's ink center lands in the plate's glyph rect — the
    /// glyph drawn into an offscreen plate the size of the real one and
    /// its ink's rows scanned, once per face. This is the same drawing
    /// the plate does, so whatever the fonts do, this is where the ink
    /// the person sees actually sits.
    static func inkCenter(of text: String, in face: NSFont) -> CGFloat {
        let box = DockBox.height
        let image = NSImage(size: NSSize(width: 40, height: box))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: box).fill()
        (text as NSString).draw(
            in: NSRect(x: 5, y: (box - 15) / 2, width: 30, height: 15),
            withAttributes: [.font: face as Any, .foregroundColor: NSColor.black]
        )
        image.unlockFocus()
        guard
            let data = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: data)
        else { return box / 2 }
        let scale = CGFloat(rep.pixelsHigh) / box
        var low = -1, high = -1
        for row in 0..<rep.pixelsHigh {
            for col in 0..<rep.pixelsWide
            where (rep.colorAt(x: col, y: row)?.redComponent ?? 1) < 0.5 {
                if low == -1 { low = row }
                high = row
                break
            }
        }
        guard low >= 0 else { return box / 2 }
        return (CGFloat(low) + CGFloat(high)) / 2 / scale
    }

    /// Take a frame's model. True when it differs from the last one — a
    /// leg moving, a fade falling, a glyph arriving, a blink flipping —
    /// and only a picture that changed is a draw worth asking for.
    func take(_ model: TerminalDock.Model, blink: Bool) -> Bool {
        var next = Picture()
        next.plate = model.plate
        next.line = model.line
        next.text = model.text
        next.cursor = model.cursor
        next.suggestion = model.suggestion
        next.arrivals = model.arrivals
        next.head = model.caret.head
        next.tail = model.caret.tail
        next.squeeze = model.caret.squeeze
        next.edge = model.caret.edgeAlpha
        next.blink = blink
        guard next != picture else { return false }
        picture = next
        return true
    }

    /// Where the line begins, in the plate's own coordinates.
    private var textX: CGFloat { DockBox.pad + advance + DockBox.gap }

    /// How far the line is scrolled left, so a caret beyond the end of
    /// what fits is still in sight: a long line rides the band with its
    /// caret, exactly as far as it has to.
    private var offset: CGFloat {
        let band = bounds.width - textX - DockBox.pad
        let caret = advance * CGFloat(picture.cursor)
        let room = band - advance * 2
        return max(0, caret - max(0, room))
    }

    /// The column of the line a point sits over, clamped to the line —
    /// the answer a click is looking for.
    func column(at point: NSPoint) -> Int {
        let col = ((point.x - textX + offset) / max(1, advance)).rounded()
        return min(max(0, Int(col)), picture.text.count)
    }

    /// The caret's rect in this view, for the input method's candidates to
    /// sit on while the dock owns the input.
    func caretSpot(at column: Int) -> NSRect {
        NSRect(
            x: textX + advance * CGFloat(column) - offset,
            y: caretMid - 8,
            width: advance, height: 16
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = picture
        guard p.plate > 0.001 else { return }
        let now = CACurrentMediaTime()
        let ink = TerminalFieldPanel.word
        // The ground is the theme's own lifted off the terminal behind it:
        // translucent, because the plate stays up while commands run and
        // a running command's last line is under it — dimmed, not hidden.
        let ground = TerminalDockPlate.ground
        let plate = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7
        )
        ground.withAlphaComponent(DockBox.ground * p.plate).setFill()
        plate.fill()
        ink.withAlphaComponent(0.14 * p.plate).setStroke()
        plate.lineWidth = 1
        plate.stroke()
        // The prompt glyph, where Metalterm's own sits: at the left of
        // the ground, and the line after it.
        let shown = p.plate * p.line
        drawGlyph("❯", at: DockBox.pad, alpha: 0.55, rise: 0, shown: shown, dy: promptDy)
        let band = bounds.width - textX - DockBox.pad
        let shift = offset
        for (index, char) in p.text.enumerated() {
            let x = textX + advance * CGFloat(index) - shift
            guard x >= textX - advance, x < textX + band else { continue }
            // A glyph's arrival: a fifth of a window, the caret's own
            // share of one, spent rising and coming in.
            let arrival = p.arrivals.indices.contains(index) ? p.arrivals[index] : 0
            let t = arrival > 0 ? min(1, max(0, (now - arrival) / DockBox.arrive)) : 1
            drawGlyph(char, at: x, alpha: t, rise: DockBox.rise * (1 - t), shown: shown)
        }
        // The suggestion, ghosted after the line as far as there is room.
        if !p.suggestion.isEmpty {
            for (index, char) in p.suggestion.enumerated() {
                let x = textX + advance * CGFloat(p.text.count + index) - shift
                guard x >= textX - advance, x < textX + band else { continue }
                drawGlyph(char, at: x, alpha: DockBox.ghost, rise: 0, shown: shown)
            }
        }
        // The caret: two bars on the warp's head and tail with the smear
        // between them, thinned by how fast it is going, and bleeding
        // where it was thrown from. Hidden while blinked out, which is
        // the pacer's clock — the same one the grid's caret keeps.
        guard p.blink else { return }
        let headX = textX + advance * p.head - shift
        let tailX = textX + advance * p.tail - shift
        let barY = caretMid - (bounds.height - 14) / 2
        let band2 = NSRect(x: min(headX, tailX), y: barY, width: max(0, abs(headX - tailX)), height: bounds.height - 14)
        if band2.width > 0.1 {
            // Faint, and fainter the further it is stretched, like the
            // find panel's ghost: a long throw is a smudge of light.
            ink.withAlphaComponent(
                0.30 * min(1, FieldBox.reach / max(1, band2.width)) * shown
            ).setFill()
            band2.fill()
        }
        let width = max(1, DockBox.bar * p.squeeze)
        ink.withAlphaComponent(shown).setFill()
        NSRect(x: tailX - width + DockBox.bar, y: barY, width: width, height: bounds.height - 14).fill()
        ink.withAlphaComponent(p.edge * shown).setFill()
        NSRect(x: headX, y: barY, width: width, height: bounds.height - 14).fill()
    }

    /// One glyph, at an alpha and a rise off the line's floor. The ink is
    /// passed in because the plate's opacity is already in it — a glyph
    /// arriving or fading rides the plate it is drawn on.
    private func drawGlyph(
        _ char: Character, at x: CGFloat, alpha: CGFloat, rise: CGFloat, shown: CGFloat, dy: CGFloat = 0
    ) {
        let ink = TerminalFieldPanel.word
        (String(char) as NSString).draw(
            in: NSRect(
                x: x, y: (bounds.height - 15) / 2 - rise + dy,
                width: advance, height: 15
            ),
            withAttributes: [
                .font: face as Any,
                .foregroundColor: ink.withAlphaComponent(alpha * shown),
            ]
        )
    }

    /// The theme's ground, the same read the find panel makes of it.
    private static var ground: NSColor {
        let theme = TerminalDraw.Theme.current(TerminalLook.theme)
        return NSColor(
            srgbRed: CGFloat(theme.ground.x), green: CGFloat(theme.ground.y),
            blue: CGFloat(theme.ground.z), alpha: CGFloat(theme.ground.w)
        )
    }
}

// MARK: - the wiring

extension TerminalView {

    /// The shell's editor reported its line (OSC 7784): the dock takes the
    /// state as it comes, makes its plate the first time one is owed, and
    /// draws the frame the report asks for.
    func docked(_ report: Dock) {
        let now = CACurrentMediaTime()
        dock.report(report, at: now)
        if dockPlate == nil, dock.owed {
            let plate = TerminalDockPlate()
            dockPlate = plate
            addSubview(plate)
            placeDock()
        }
        drawDock()
        present()
    }

    /// The plate over the frame's bottom, placed by every layout.
    func placeDock() {
        guard let plate = dockPlate else { return }
        plate.frame = DockBox.home(in: bounds, above: statusBar.frame.height)
    }

    /// One frame of the dock: the engine's model put in the plate's
    /// picture, and the next frame asked for off the run loop while one is
    /// owed — the same hop the find panel makes, so a leg never draws a
    /// frame inside a frame. The caret's blink — Metalterm's own rule:
    /// solid while the person types, a sine for ten seconds of idleness,
    /// solid again after — is drawn here and its clock kept here, riding
    /// the pacer's caret purpose the way the grid's blink rides it when the
    /// grid's caret is the one on screen.
    func drawDock() {
        guard let plate = dockPlate else { return }
        let now = CACurrentMediaTime()
        if !dock.owed {
            tearDownDock()
            present()
            return
        }
        let model = dock.model(at: now)
        if plate.take(model, blink: dock.blink(at: now)) {
            plate.needsDisplay = true
        }
        if dock.owns {
            if dock.blinkClock(at: now) {
                pacer.want(.caret)
            } else {
                pacer.settleCaret()
            }
        }
        guard dock.moving(at: now) else { return }
        dockAsking = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dockAsking else { return }
            self.dockAsking = false
            self.present()
        }
    }

    /// The plate let go — the frame that finished the `off` collapse.
    func tearDownDock() {
        dockPlate?.removeFromSuperview()
        dockPlate = nil
        dockAsking = false
    }
}
