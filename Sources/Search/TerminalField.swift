import AppKit

// The find panel's manners (see TerminalFind), which are Metalterm's.
//
// Metalterm's input box is the best-mannered one on the Mac, and the manners
// are mechanical rather than stylistic, which is why they can be taken
// without taking its furniture: the bottom dock, the status bar and the
// command blocks are its UX and TERMINAL.md leaves them alone, but the way a
// thing travels between two places is a curve, and a curve is only numbers.
//
// The numbers here are `mt_gpu::motion::Cursor`'s — `warp_span`, `caret_alpha`,
// `squash` and `update` — read out of the app's own arm64:
//
//   head   p = clamp(t / 0.17),  1 − (1 − p)⁴          two bars, not one: a firm
//   tail   q = clamp((t − 0.05) / 0.2),                head on a quartic ease-out
//          q < 0.5 ? 4q³ : 1 − ½(2 − 2q)³              and a faint tail on a
//   smear  |head − tail|, dead below 1e−4              cubic ease-in-out delayed
//                                                      5% and stretched
//   bleed  t = clamp(e / (d · 0.2)),                   the alpha of a caret that
//          t < 0.35 ? 1 − t/0.35 : (t − 0.35)/0.65      has just been thrown:
//                                                      opaque, gone at 35% of a
//                                                      fifth of the leg, opaque
//                                                      again
//   squash 1 / clamp(1 + v · 0.009333…, 1, 1.3)        a thing moving fast is
//                                                      briefly thinner, and
//                                                      rides its own velocity
//
// One curve here is not Metalterm's, and it is the one that had to be: the
// opacity of the plate. A caret is a cell wide, so it can be there and not be
// there inside a sixth of a leg; a two-hundred-point plate doing that is a cut,
// not an arrival. The plate fades on a smoothstep over the head's own window
// instead, so it is whole exactly when it has landed.
//
// Metalterm reads all of this in cells, because a caret is one cell wide. A
// panel is two hundred points wide, so the same curves are read in points
// here, and the same three things are drawn from them: the plate, whose
// leading edge follows the tail; a bar of light running ahead of it on the
// head; and the gap between the two, which is the smear — terminal showing
// through, which is why the two curves have to be on two *things*. Nothing
// moves when nothing has moved: at rest the two curves meet, the gap closes,
// and the bar sits on the plate's own edge, exactly as Metalterm's caret does.

/// The leg of a panel's travel, in seconds. These are Metalterm's `duration`
/// — the window its curves are read against — not the time the travel takes:
/// its head finishes a sixth of the way in and its tail before a quarter, so
/// a plate's whole journey is a third of what is written here. Longer than a
/// caret's window for the same reason a plate is bigger than a caret: the
/// same flick that crosses a cell in 40 ms would cross a third of the window
/// as a cut.
enum FieldMotion {
    /// Arriving, leaving, and changing size: three windows of the same shape.
    static let arrive: CFTimeInterval = 0.44
    static let leave: CFTimeInterval = 0.36
    static let settle: CFTimeInterval = 0.40
    /// How much of a window the travel actually takes: the tail's own end, as
    /// `FieldCurve.tail` runs it. Everything after this is a dwell, and a
    /// dwell is not a reason to ask the display for frames — so a 0.44 window
    /// is a 110 ms journey, not a 440 ms one.
    static let travel: Double = 0.25
    /// A keystroke's dip, which is a fifth of a window as Metalterm times it.
    static let dip: CFTimeInterval = 0.08
}

/// How big the panel is and where it goes, in points. Separate from the
/// timings because it is the half of this that is a rectangle rather than a
/// curve — and because the two ends of the frame are a setting, which is a
/// question about a box and not about a journey.
enum FieldBox {
    /// The bars' own width.
    static let bar: CGFloat = 2
    /// The room the plate leaves around the words.
    static let pad: CGFloat = 7
    /// The gap, in points, at which the smear is at its strongest. Past it the
    /// smear is thinned in inverse proportion — a long throw is a smudge of
    /// light, not a bright rule across the terminal.
    static let reach: CGFloat = 26
    /// How tall the plate is, and how far its right edge sits from the
    /// frame's — Metalterm's `FindUi::panel_rect` inset, read in points rather
    /// than in its own font grid. The same at either end of the frame.
    static let height: CGFloat = 30
    static let margin: CGFloat = 14
    /// The room left above (or below) the frame's edge. Metalterm's own panel
    /// clears its title bar by more than this; a terminal has no title bar to
    /// clear, and a plate further in than this sits over the first row of
    /// text at the top and the prompt at the bottom.
    static let edge: CGFloat = 12
    /// The room left on the far side, when the panel hangs off the other end.
    /// A terminal's frame has nothing at its bottom edge to clear, so the plate
    /// can sit closer there; the top edge is where a window's own chrome is.
    static let farEdge: CGFloat = 12

    /// Where the panel hangs when it is still, for a frame of a given size:
    /// its leading (left) edge, its own width, the band it sits over, and how
    /// tall that band is. Its right edge is pinned to the frame's, and the end
    /// of the frame it hangs off is the one setting about it — over the top
    /// corner, where it has always been, or the bottom one, which is where
    /// Metalterm puts its own input box. Pure, so the two places can be checked
    /// without a terminal: a view is not needed to know where a rectangle goes.
    ///
    /// A frame too narrow for the wanted width gets what there is, less a
    /// margin at each side, and never less than 120 points — a plate narrower
    /// than its own padding would be a plate with no words in it.
    static func home(
        wide wanted: CGFloat, in bounds: CGRect, at place: TerminalFindPlace
    ) -> (leading: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat) {
        let width = min(wanted, max(120, bounds.width - margin * 2))
        let y: CGFloat = switch place {
        case .top: bounds.height - edge - height
        case .bottom: farEdge
        }
        return (bounds.width - margin - width, width, y, height)
    }

    /// The same place, for a box measured top-down rather than bottom-up —
    /// a flipped view, or a SwiftUI overlay's alignment. The plate is the same
    /// height either way, so only the top has to be worked out again.
    static func top(
        wide wanted: CGFloat, in bounds: CGRect, at place: TerminalFindPlace
    ) -> (leading: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat) {
        let home = home(wide: wanted, in: bounds, at: place)
        return (home.leading, home.width, bounds.height - home.y - home.height, home.height)
    }
}

/// The curves, and nothing else: no view, no clock, no state. Everything here
/// is a pure function of a normalized leg, so the shapes are testable without
/// a screen — which is the only way to see a 40 ms bleed at all.
enum FieldCurve {
    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// The head of the smear: Metalterm's quartic ease-out, over the first
    /// 17% of the leg. This is the bar of light, which runs ahead of the plate
    /// and pulls it in — a caret that crept instead would read as lag rather
    /// than as travel.
    static func head(_ t: Double) -> Double {
        let p = clamp(t / 0.17)
        let rest = 1 - p
        return 1 - rest * rest * rest * rest
    }

    /// The tail: a cubic ease-in-out, delayed 5% and stretched over a fifth
    /// of the leg. It is the head's shadow, and the gap between the two is
    /// the whole of the smear.
    static func tail(_ t: Double) -> Double {
        let q = clamp((t - 0.05) / 0.2)
        guard q < 0.5 else { return 1 - pow(2 - 2 * q, 3) / 2 }
        return 4 * q * q * q
    }

    /// A caret's alpha just after it was thrown: opaque, out at 35% of a
    /// window that is a fifth of the leg, opaque again at the end of it. The
    /// dip is what makes a keystroke read as one — a bar that only slid
    /// would look like it had always been there.
    static func bleed(_ t: Double) -> Double {
        let dipped = clamp(t)
        guard dipped < 0.35 else { return (dipped - 0.35) / 0.65 }
        return 1 - dipped / 0.35
    }

    /// The plate's opacity: smoothstep over the head's own window, so it is
    /// whole exactly when it has arrived — a plate that slid into place and
    /// then faded in there would be two events where a throw is one.
    static func fade(_ t: Double) -> Double {
        let p = clamp(t / 0.17)
        return p * p * (3 - 2 * p)
    }

    /// The head's slope at a normalized leg, relative to its own launch
    /// slope — 1 at the throw, falling away as the quartic spends itself.
    /// `squash` reads a velocity, and Metalterm's velocity is a spring's,
    /// which is bounded; the head's analytic slope is not (it starts around
    /// twenty thousand points a second on a plate-size leg, which would sit
    /// on the clamp for the whole travel and then pop off it). Reading the
    /// slope *relative to this leg's own* keeps the shape — thinnest at the
    /// throw, whole again on arrival — without the scale.
    static func headSlope(_ t: Double) -> Double {
        let p = clamp(t / 0.17)
        let rest = 1 - p
        return rest * rest * rest
    }

    /// `squash`: the faster a thing is going, the thinner it gets, held
    /// between one and one over 1.3. Points per second in, a width factor out
    /// — a plate changing size at a thousand points a second is at its
    /// thinnest, which is a 23% squeeze and reads as a shove rather than as a
    /// resize.
    static func squash(_ speed: CGFloat) -> CGFloat {
        let held = min(1.3, max(1, 1 + speed * 0.009333333333333334))
        return 1 / held
    }

    /// The speed that `squash` is read with for a leg: the knee of the clamp
    /// (where the squeeze first reaches its floor) times how much of the
    /// launch slope is left. A plate starts at its thinnest and is whole by
    /// the time it arrives, which is what a shove looks like from the side.
    static func squeezeAt(_ t: Double) -> CGFloat {
        let knee = (1.3 - 1) / 0.009333333333333334
        return squash(CGFloat(knee * headSlope(t)))
    }
}

/// The panel's own clock: where it is, where it is going, and how it is
/// getting there. It draws nothing — TerminalFind hands the state to its
/// views and TerminalView asks for the frames — so what is here can be walked
/// by a test one millisecond at a time.
@MainActor
final class TerminalField {
    /// What one frame wants drawn, in the view's own points. `head` is where
    /// the bar of light is, `tail` where the plate's leading edge is, and the
    /// gap between them is the smear — open while travelling, closed at rest.
    struct Model {
        var head: CGFloat = 0
        var tail: CGFloat = 0
        var squeeze: CGFloat = 1
        var body: CGFloat = 1
        var edgeAlpha: CGFloat = 1
        /// How wide the smear is right now, in points: nothing when the two
        /// curves have met.
        var smear: CGFloat { abs(tail - head) }
    }

    private enum Stage { case away, moving, resting }

    private var stage: Stage = .away
    /// The resting place the legs end at: the leading edge, and the width the
    /// squeeze is measured against.
    private var rest: CGFloat = 0
    private var wide: CGFloat = 0

    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var began: CFTimeInterval = 0
    private var length: CFTimeInterval = 0

    /// A leg that arrives fades in on the way; one that leaves fades out. A
    /// leg that only changes size is already there, and does neither.
    private var rising = false
    private var fading = false

    /// The keystroke whose bleed is being drawn, and when its dip is over.
    private var pressed: CFTimeInterval = -.greatestFiniteMagnitude
    private var bleeding: CFTimeInterval = 0

    /// Whether anything is still moving, or has yet to be drawn — the panel
    /// is somewhere it was not, or a keystroke's bleed is still on.
    func moving(at now: CFTimeInterval) -> Bool {
        if stage == .moving, (now - began) / length < FieldMotion.travel { return true }
        return bleeding(at: now)
    }

    /// Whether a leg is being walked that ends with the panel gone.
    var isLeaving: Bool { stage == .moving && fading }

    /// Nothing has been put anywhere yet: the find is not open.
    var isAway: Bool { stage == .away }

    // MARK: - the legs

    /// Where the panel belongs when it is still. Asked on every layout: the
    /// plate hangs off the right edge, so what a count growing actually does
    /// is stretch the plate further left, and only an edge that moved is a
    /// leg. A width that changed with the edge still is a stretch, which is
    /// what it looks like anyway.
    func place(_ leading: CGFloat, wide width: CGFloat, at now: CFTimeInterval) {
        rest = leading
        wide = width
        switch stage {
        case .away:
            from = leading
            to = leading
        case .resting, .moving:
            // Retargeted mid-flight — a resize, or an edge that moved while
            // the plate was still coming in. The leg restarts from wherever
            // the head is, which is where a thrown thing actually is.
            guard abs(leading - to) > 0.5 else { return }
            leg(to: leading, at: now, over: FieldMotion.settle)
        }
    }

    /// The panel arriving: from off its own right edge, which is where a
    /// thing that belongs to the right side of the window comes from.
    func arrive(_ leading: CGFloat, wide width: CGFloat, at now: CFTimeInterval) {
        rest = leading
        wide = width
        stage = .moving
        rising = true
        fading = false
        from = leading + width
        to = leading
        began = now
        length = FieldMotion.arrive
        pressed = -.greatestFiniteMagnitude
        bleeding = 0
    }

    /// The panel leaving: out its own corner, head first, the smear left
    /// trailing in the gap behind it.
    func leave(at now: CFTimeInterval) {
        guard stage != .away else { return }
        let leaving = advance(at: now).head
        stage = .moving
        rising = false
        fading = true
        from = leaving
        to = rest + wide
        began = now
        length = FieldMotion.leave
        pressed = -.greatestFiniteMagnitude
        bleeding = 0
    }

    /// Put it where it belongs and be done with it — Reduce Motion, and any
    /// frame that has no display to be measured against.
    func settle(_ leading: CGFloat, wide width: CGFloat) {
        rest = leading
        wide = width
        stage = .resting
        rising = false
        fading = false
        from = leading
        to = leading
        pressed = -.greatestFiniteMagnitude
        bleeding = 0
    }

    /// A key landed in the field: the bar at the panel's leading edge bleeds
    /// once, whether or not anything else moved. This is the per-glyph half
    /// of Metalterm's typing, and it is the only part of the panel that
    /// answers every keystroke — the plate itself answers only movement,
    /// because a counter that changed and a counter that did not are not the
    /// same event.
    func press(at now: CFTimeInterval) {
        guard stage != .away else { return }
        pressed = now
        bleeding = FieldMotion.dip
    }

    private func leg(to target: CGFloat, at now: CFTimeInterval, over span: CFTimeInterval) {
        from = advance(at: now).head
        to = target
        began = now
        length = span
        rising = false
        fading = false
        stage = .moving
    }

    // MARK: - what a frame is

    /// Everything the views need, for the instant asked about. The last leg
    /// of a travel ends the stage as it is read, so the caller learns the
    /// panel has finished from the frame that finishes it.
    func advance(at now: CFTimeInterval) -> Model {
        end(at: now)
        return model(at: now)
    }

    /// Whether a keystroke's bleed is still owed a frame.
    func bleeding(at now: CFTimeInterval) -> Bool { bleeding > 0 && now - pressed < bleeding }

    /// A travel ends when its curves do, not when its window does: the tail
    /// has caught the head by a quarter of the window, and the rest is a
    /// dwell nobody should be asked to draw.
    private func end(at now: CFTimeInterval) {
        guard stage == .moving else { return }
        guard (now - began) / length >= FieldMotion.travel else { return }
        stage = fading ? .away : .resting
        from = to
    }

    private func model(at now: CFTimeInterval) -> Model {
        guard stage != .away else { return Model(body: 0) }
        let raw = length > 0 ? (now - began) / length : 1
        let t = min(FieldMotion.travel, max(0, raw))
        let head = from + (to - from) * CGFloat(FieldCurve.head(t))
        let tail = from + (to - from) * CGFloat(FieldCurve.tail(t))
        // The squeeze is a reading of how fast the thing is going, and the
        // head's own slope is that reading: thinnest at the throw, whole
        // again as the quartic spends itself. Not the travel's average speed —
        // an average is not a velocity, and one held to the end would snap off
        // its clamp on the last frame.
        var model = Model(head: head, tail: tail, squeeze: stage == .moving ? FieldCurve.squeezeAt(t) : 1)
        model.body = rising ? CGFloat(FieldCurve.fade(t)) : (fading ? 1 - CGFloat(FieldCurve.fade(t)) : 1)
        if bleeding(at: now) {
            model.edgeAlpha = CGFloat(FieldCurve.bleed((now - pressed) / bleeding))
        }
        return model
    }
}

// MARK: - laying it down

/// The plate the field sits on: the terminal's own ground lifted a shade, a
/// hairline round it, the field and a count inside. Metalterm's panel tints —
/// 0.85 of the ink for a border, 0.14 and 0.185 for the softer two, taken from
/// `overlay::find::FindUi::draw` — are the only borrowed colours, because a
/// panel that painted the app's chrome over a terminal's own theme would be
/// the wrong box in the wrong window.
@MainActor
final class TerminalFieldPanel: NSView {
    let field: NSTextField
    let count = NSTextField(labelWithString: "")

    private static let gap: CGFloat = 7
    private static let pad: CGFloat = FieldBox.pad
    private static let fieldWidth: CGFloat = 172

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.alignment = .right
        count.textColor = TerminalFieldPanel.word.withAlphaComponent(0.55)
        field.textColor = TerminalFieldPanel.word
        addSubview(field)
        addSubview(count)
        remeasure()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the field itself takes a click: the plate is scenery, and a
        // click beside the words must reach the terminal under it.
        super.hitTest(point).flatMap { $0 === self ? nil : $0 }
    }

    /// The ink of the words in it, and of everything drawn on it.
    static var word: NSColor {
        let theme = TerminalDraw.Theme.current(TerminalLook.theme)
        return NSColor(
            srgbRed: CGFloat(theme.ink.x), green: CGFloat(theme.ink.y),
            blue: CGFloat(theme.ink.z), alpha: CGFloat(theme.ink.w)
        )
    }

    private static var ground: NSColor {
        let theme = TerminalDraw.Theme.current(TerminalLook.theme)
        return NSColor(
            srgbRed: CGFloat(theme.ground.x), green: CGFloat(theme.ground.y),
            blue: CGFloat(theme.ground.z), alpha: CGFloat(theme.ground.w)
        )
    }

    /// How much room the words want: the field's own width, a gap, the count
    /// as it is written now, and the plate's padding. Measured when the count
    /// changes and kept, rather than asked again every frame — a frame is an
    /// 8.3 ms budget and a string measured in it is a frame spent on text
    /// that has not moved.
    private(set) var wanted: CGFloat = 0

    /// Measure the plate again, for the count as it stands now.
    func remeasure() {
        let said = count.stringValue
        let wide = said.isEmpty ? 0 : (said as NSString)
            .size(withAttributes: [.font: count.font as Any]).width.rounded(.up)
        let room = max(0, wide) + (wide > 0 ? Self.gap : 0)
        wanted = Self.pad * 2 + Self.fieldWidth + room
    }

    override func layout() {
        super.layout()
        let said = (count.stringValue as NSString)
            .size(withAttributes: [.font: count.font as Any]).width.rounded(.up)
        let room = count.stringValue.isEmpty ? 0 : said + Self.gap
        let tall: CGFloat = 18
        field.frame = NSRect(
            x: Self.pad, y: (bounds.height - tall) / 2,
            width: max(40, bounds.width - Self.pad * 2 - room), height: tall
        )
        count.frame = NSRect(
            x: bounds.width - Self.pad - said, y: (bounds.height - 13) / 2,
            width: said, height: 13
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink = Self.word
        let plate = Self.ground.blended(withFraction: 0.055, of: ink) ?? Self.ground
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7
        )
        plate.setFill()
        path.fill()
        ink.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The smear: a band of the panel's own ink filling the gap between the head
/// (the bar of light) and the tail (the plate's leading edge), so thin while
/// the two are close that it is not there at all. A layer rather than a drawn
/// view, because it is re-shaped on every frame of a leg.
@MainActor
final class TerminalFieldSmear: NSView {
    init(tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = tint.withAlphaComponent(0.30).cgColor
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func tint(_ colour: NSColor) { layer?.backgroundColor = colour.withAlphaComponent(0.30).cgColor }
}

/// One of the two bars the motion throws: the leading edge, which bleeds. A
/// layer's own background rather than a drawn rectangle, because it moves on
/// every frame of a leg and a bar that was redrawn would cost a draw for two
/// points of colour.
@MainActor
final class TerminalFieldBar: NSView {
    init(tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = tint.cgColor
        layer?.cornerRadius = FieldBox.bar / 2
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func tint(_ colour: NSColor) { layer?.backgroundColor = colour.cgColor }
}
