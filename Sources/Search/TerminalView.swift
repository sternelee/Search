import AppKit
import QuartzCore
import simd

// The terminal as a view: one CAMetalLayer the renderer draws into (see
// TerminalDraw.swift), a keyboard and an input method feeding the program
// through the Terminal, and a hand that picks words out of the scrollback.
//
// Nothing here draws anything itself, and nothing here draws on the spot
// either: a frame is asked for when something changed — output, a
// keystroke, a scroll, a selection, a focus — and drawn on the next tick
// of the display's own clock (see TerminalPacer), so a burst of output is
// one frame rather than a thousand. A metal layer is never drawn by AppKit
// — no context comes to a `draw` it could call — so that schedule is the
// whole of it, and an idle terminal has none at all.

@MainActor
final class TerminalView: NSView, NSTextInputClient {
    let terminal: Terminal

    /// The renderer, when there was one to have: it owns the layer this
    /// view draws through.
    private var paint: TerminalDraw?

    /// The cell a frame is drawn in, measured from the face — the size the
    /// renderer was last given, or the face's own before a layout. Whoever
    /// divides the room a terminal sits in asks this, to keep from making
    /// a pane too narrow for its own cells.
    var cell: CGSize { paint?.cell ?? TerminalDraw.measure(TerminalLook.face()) }

    /// The keyboard arrived here. Said once per arrival, from the same
    /// place the caret is settled — whoever divides the room listens, to
    /// know which pane the keys are in (see TerminalSplits).
    var onFocused: (() -> Void)?

    /// When the next frame is drawn, and why. The only clock in here — the
    /// caret's blink is the pacer's to keep time for, not a timer's, and
    /// the timer there used to be ran on for every terminal merely on
    /// screen, whether or not any keyboard was in it.
    private let pacer = TerminalPacer()

    /// The modes the last reading left the screen in. The keyboard and the
    /// hand act between frames and cannot reach into the screen to ask
    /// (see Terminal.look for the same reason from the other side), so
    /// they read them from here instead.
    private var modes = Modes()

    /// What the program was last told about the keyboard (1004): true when
    /// it heard the focus arrive. Kept because only the change is worth
    /// sending, and the change is only a change against this.
    private var heard = false

    /// What the terminal has changed since the last frame was drawn. The
    /// frame takes it away; where a frame only says a row again when a row
    /// changed, this is what says which.
    private var owed = Damage()

    /// Settings talking about the terminal's look (see TerminalLook).
    private var watching: NSObjectProtocol?
    /// The window's own two notices — it took the keyboard, it gave it up.
    /// Kept as a pair rather than one, because they are added and removed
    /// together and there is no third.
    private var watchingKey: [NSObjectProtocol] = []

    /// The size the terminal was last told it is, in cells.
    private var sized = (width: 0, height: 0)
    /// How far the frame is lifted into the scrollback, in lines. 0 is
    /// the live screen. TerminalFind carries it to a match; the wheel and
    /// the keys walk it.
    var lift = 0
    /// A selection, as the grid's own coordinates: the columns and rows it
    /// spans, inclusive, of the scene it was picked in. Lifted or fed, it
    /// means nothing — anything that moves the scene drops it.
    private var pick: ((Int, Int), (Int, Int))?
    /// The anchor a drag is picking from.
    private var anchor = (column: 0, row: 0)

    /// A search of the scrollback (⌘F — the field, the matches, the one
    /// being stood on: see TerminalFind, where it all happens).
    var findField: NSTextField?
    var findings: [(row: Int, col: Int, len: Int)] = []
    var finding = -1

    // MARK: - born

    init(terminal given: Terminal) {
        terminal = given
        paint = TerminalDraw(font: TerminalLook.face())
        super.init(frame: .zero)
        wantsLayer = true
        terminal.onDraw = { [weak self] damage, modes in self?.moved(damage, modes) }
        // A glyph the atlas had to cut is a square some frame drew blank
        // (see TerminalAtlas), so the frame after it is worth asking for —
        // and on a terminal that is otherwise idle there is nothing else
        // that would ask.
        paint?.onLanded = { [weak self] in self?.present() }
        // The pacer draws nothing of its own: the frame is this view's,
        // and the link has to be asked for off this view's own screen.
        pacer.draw = { [weak self] in self?.frame() }
        pacer.makeLink = { [weak self] in
            guard let self, self.window?.screen != nil else { return nil }
            return self.displayLink(target: self.pacer, selector: #selector(TerminalPacer.tick(_:)))
        }
        // The look is the app's and not this view's: the panel writes it
        // down, and every terminal open takes it as it changes.
        watching = NotificationCenter.default.addObserver(
            forName: TerminalLook.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookChanged() }
        }
        lookChanged()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let watching { NotificationCenter.default.removeObserver(watching) }
        MainActor.assumeIsolated { pacer.detach() }
    }

    override func makeBackingLayer() -> CALayer {
        paint?.layer ?? CAMetalLayer()
    }

    // MARK: - laid out

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for notice in watchingKey { NotificationCenter.default.removeObserver(notice) }
        watchingKey = []
        if let window {
            // The keyboard arriving at and leaving the window is the
            // terminal's own focus, and the first responder is not the
            // same question: a window that stops being key keeps its
            // first responder, and a terminal that missed that would
            // never tell a program it had been left (1004).
            watchingKey = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.settleFocus() }
                    }
                }
        }
        // A terminal that left its window has no display to keep time by
        // and nothing to draw for; one that arrived has a frame waiting.
        if window == nil { pacer.detach() } else { present() }
        settleFocus()
    }

    /// In a slot that is not showing — the other half of a split that has
    /// been collapsed, or a frame too narrow to hold two (see PaneStage):
    /// in the window, but nowhere anyone is looking. The clock is stopped
    /// for it rather than left running with nothing to draw for.
    override func viewDidHide() {
        super.viewDidHide()
        pacer.detach()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        present()
    }

    override func layout() {
        super.layout()
        guard let paint, bounds.width > 1, bounds.height > 1 else { return }
        paint.size(bounds, scale: window?.backingScaleFactor ?? 1)
        let width = paint.columns(for: bounds.width)
        let height = paint.rows(for: bounds.height)
        if width != sized.width || height != sized.height {
            sized = (width, height)
            lift = 0
            terminal.resize(width: width, height: height)
        }
        placeFindField()
        present()
    }

    override func viewDidChangeEffectiveAppearance() {
        // A terminal set to match the Mac paints with the Mac's own light
        // or dark, so the appearance going over is a change of theme: every
        // cell says a colour the frame holds, and all of them have to be
        // said again.
        paint?.repaint()
        present()
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        // A caret that had blinked out comes back the moment the keyboard
        // does, rather than up to half a second later: the blink is
        // settled to shown before it is held again.
        pacer.settleCaret()
        settleFocusSoon()
        present()
        if took { onFocused?() }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        settleFocusSoon()
        present()
        return gave
    }

    /// The same question, asked once the responder has stopped moving.
    /// `makeFirstResponder` asks the old responder to resign before it
    /// hands the place on and the new responder to accept after, so
    /// neither of them can see where the keyboard ended up from inside
    /// its own call.
    private func settleFocusSoon() {
        DispatchQueue.main.async { [weak self] in self?.settleFocus() }
    }

    /// Whether the keyboard is in this terminal: it has the first
    /// responder and its window is the key one. Both halves are needed —
    /// a terminal in a background window still holds the first responder.
    private var holdsKeyboard: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    /// Tell the program where the keyboard is, if it asked to hear (1004).
    /// Only the changes are sent: a program that hears "focus came" twice
    /// with nothing in between has been told nothing.
    private func settleFocus() {
        let now = holdsKeyboard
        guard modes.focus else {
            // Turned off: nothing is reported, and nothing is remembered
            // either — a program that asks for the reports later is
            // answered with where the keyboard actually is, rather than
            // with a change that may never come.
            heard = false
            return
        }
        guard now != heard else { return }
        heard = now
        terminal.send(now ? "\u{1b}[I" : "\u{1b}[O")
    }

    // MARK: - one frame

    // A view backed by a CAMetalLayer is never drawn by AppKit: a metal
    // layer has no context to hand a `draw`, so the redraw AppKit owes
    // on `needsDisplay` goes nowhere — MetalKit's own view drives itself
    // for the same reason. So the frames here are driven the way the
    // zero-frame promise wants them anyway: something changed — output,
    // a keystroke, a scroll, a selection, a focus — and the frame is
    // drawn then and only then. Nothing scheduled, nothing idle, nothing
    // drawn that nobody asked for.
    //
    // `draw` stays for the direct asks: `StageView.settle` marks a
    // landing view dirty, and nothing of ours ever needs it, but a
    // `display()` from anywhere still finds a frame here.

    /// Something the terminal said or did: a frame now has something to
    /// show, and the modes the keyboard and the hand act on may have
    /// moved. What the frame shows is asked of the terminal when the frame
    /// is drawn — never kept here, where it would sit between the two.
    private func moved(_ damage: Damage, _ modes: Modes) {
        let was = self.modes
        self.modes = modes
        owe(damage)
        // The pointer is watched only while a program is asking to hear
        // about it (1003), so the area is put up and taken down as that
        // comes and goes rather than left to deliver every pass of the
        // mouse over a terminal that would throw it away.
        if modes.mouse != was.mouse { updateTrackingAreas() }
        // A program that has just asked to hear about focus hears where
        // the keyboard is now, rather than waiting for it to move.
        if modes.focus != was.focus { settleFocus() }
        // A program holding the screen (synchronized output, 2026) is
        // building its next frame out of sight: what arrives meanwhile is
        // written into the screen and none of it is shown. Letting go is
        // what shows it — one frame, all of it at once, which is the whole
        // point of asking. See TerminalPacer for the timeout that keeps a
        // program that dies mid-hold from taking the terminal with it.
        syncHeld()
        present()
        // A search standing in a screen that moved under it follows the
        // rows it found (see TerminalFind).
        if findField != nil { research() }
    }

    override func draw(_ dirtyRect: NSRect) {
        present()
    }

    /// Whether the screen is being held for a program that asked to draw a
    /// frame whole (2026) — and that the setting lets it, which is a
    /// question of when the hold should be let go of as much as taken up.
    private var holding = false

    /// Take up or let go of the hold, as the screen says. A program asking
    /// is what starts it; the mode going off, or the setting doing so under
    /// a program that has already asked, is what ends it — read afresh here
    /// rather than compared against the modes that came before, because the
    /// setting can change on its own (see lookChanged).
    private func syncHeld() {
        let want = modes.sync && TerminalLook.syncsOutput
        guard want != holding else { return }
        holding = want
        if want { pacer.want(.hold) } else { pacer.release() }
    }

    /// A frame is owed. Nothing is drawn here: it follows on the next tick
    /// of the display's own clock (see TerminalPacer), so a burst of
    /// output is one frame rather than a thousand, and a frame asked for
    /// by a keystroke, a scroll or a layout takes its turn with whatever
    /// arrived in the meantime.
    func present() {
        guard window != nil else { return }
        // A terminal in a tab that is not the one on screen is a frame
        // nobody would see, and asking for one would start the clock for
        // it again — a background split running `cat` is the case. Hidden
        // by an ancestor counts: it is the slot that is hidden, not the
        // terminal inside it.
        guard !isHiddenOrHasHiddenAncestor else {
            pacer.detach()
            return
        }
        // The caret is a reason to keep ticking only while it is blinking
        // with the keyboard in the terminal. Any other time it simply
        // shows, and the frame owed for something else carries it —
        // `settleCaret` asks for one of its own, which is what puts a
        // caret back the moment the keyboard leaves.
        if TerminalLook.blinks, window?.firstResponder === self, caretIsLive {
            pacer.want(.caret)
        } else {
            pacer.settleCaret()
        }
        pacer.want(.once)
    }

    /// The frame itself: what the scene says, asked of the terminal, put
    /// on the layer. Only the pacer's clock calls this.
    private func frame() {
        guard let paint, var scene = terminal.scene(scroll: lift) else { return }
        lift = min(lift, scene.back)
        links = scene.links
        linked = scene.links.isEmpty ? [] : runs(of: scene)
        // A link under the pointer with ⌘ held is drawn underlined — and
        // it is drawn here, by marking the copy of the scene the frame is
        // about to read, rather than by teaching the renderer about
        // hover: a scene handed over is this view's to decorate, and an
        // argument the renderer has no other use for would be one more
        // thing for every caller of `update` to pass.
        //
        // Nothing has to be said about it afterwards. Marking a square
        // writes the row, and a row that is written is a row the renderer
        // has not seen before — so the row is converted again with the
        // underline on it, and converted back when the hover moves on.
        if let hovering { underline(hovering, in: &scene) }
        paint.update(
            scene: scene, damage: owed, selection: selection(in: scene),
            strong: window?.firstResponder === self,
            cursor: pacer.caretShown, marks: scene.marks,
            finds: finds(in: scene), found: found(in: scene)
        )
        paint.render()
        owed = Damage()
    }

    /// One run of squares wearing the same hyperlink, in the frame being
    /// drawn. Kept from the last frame so that a hover is answered without
    /// reaching into the screen: the mouse moves far more often than the
    /// screen does, and a `look` per move would block the keyboard behind
    /// whatever the program is writing.
    private struct LinkRun: Equatable {
        var row: Int
        var from: Int
        var to: Int
        var index: UInt16
    }

    private var linked: [LinkRun] = []
    /// Every address the screen knows, from the last frame (see
    /// Terminal.Scene.links). A square carries the number.
    private var links: [String] = []
    /// The run under the pointer with ⌘ held, if there is one. The frame
    /// draws it underlined; a click opens it.
    private var hovering: LinkRun?
    /// Whether the command key is down. Held only to know whether the
    /// pointer is worth watching at all.
    private var commandHeld = false
    /// Whether the pointer is being followed for a link's sake: ⌘ down, and
    /// links something a click is to open at all (see TerminalLook).
    private var overLinks: Bool { commandHeld && TerminalLook.opensLinks }

    /// The runs of linked squares in a row, left to right.
    private func runs(of scene: Terminal.Scene) -> [LinkRun] {
        var found: [LinkRun] = []
        for row in 0..<scene.lines.count {
            let cells = scene.lines[row].cells
            var column = 0
            while column < cells.count {
                let link = cells[column].link
                guard link != 0 else {
                    column += 1
                    continue
                }
                var end = column
                while end + 1 < cells.count, cells[end + 1].link == link { end += 1 }
                found.append(LinkRun(row: row, from: column, to: end, index: link))
                column = end + 1
            }
        }
        return found
    }

    /// The address a run stands for, when it is one this terminal would
    /// open. Only the two the web is made of: a program may name any
    /// scheme it likes, and a click that could launch anything the program
    /// chose is not a click anyone can predict.
    private func address(of run: LinkRun) -> URL? {
        let at = Int(run.index) - 1
        guard at >= 0, at < links.count, let url = URL(string: links[at]),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Underline a run of linked squares in the scene this frame is about
    /// to draw: a write to the row, and nothing else has to be arranged —
    /// the renderer converts a row it has not been given before, and this
    /// is a row it has not been given before (see TerminalCells).
    private func underline(_ run: LinkRun, in scene: inout Terminal.Scene) {
        guard run.row < scene.lines.count else { return }
        let cells = scene.lines[run.row].cells.count
        guard run.from < cells else { return }
        for column in run.from...min(run.to, cells - 1) {
            scene.lines[run.row].cells[column].ink.underline = true
        }
    }

    /// The pointer moved, with ⌘ held: whatever is under it is the link
    /// the next click would open, and saying so is what the underline and
    /// the hand are both for.
    private func hover(_ event: NSEvent) {
        guard overLinks,
              let spot = square(of: convert(event.locationInWindow, from: nil)),
              let run = linked.first(where: {
                  $0.row == spot.row && spot.column >= $0.from && spot.column <= $0.to
              }),
              address(of: run) != nil
        else {
            guard hovering != nil else { return }
            hovering = nil
            NSCursor.arrow.set()
            present()
            return
        }
        guard hovering != run else { return }
        hovering = run
        NSCursor.pointingHand.set()
        present()
    }

    override func flagsChanged(with event: NSEvent) {
        let held = event.modifierFlags.contains(.command)
        guard held != commandHeld else { return }
        commandHeld = held
        // The pointer is only worth watching while ⌘ is down: it is the
        // only thing a hover is for, and a terminal nobody is holding ⌘
        // over should not be paying for a tracking area.
        updateTrackingAreas()
        if !held, hovering != nil {
            hovering = nil
            NSCursor.arrow.set()
            present()
        }
    }

    /// Whether the caret is somewhere a frame would draw it: the live
    /// screen and not the scrollback (a frame lifted into the scrollback
    /// draws no caret at all — see Terminal.scene), and the program has
    /// not turned it off (DECTCEM).
    private var caretIsLive: Bool { modes.visible && lift == 0 }

    /// Take what the terminal said changed, to be spent by the next frame.
    private func owe(_ damage: Damage) {
        owed.merge(damage)
    }

    /// Settings said the terminal's look changed: the face, the theme, the
    /// cursor, the room left at the edges. The face is the renderer's to
    /// re-cut — the glyph atlas is cut from it — and the rest is read out
    /// of the settings by the next frame, so all this has to do is ask for
    /// one. The caret is left blinking: whether it is a reason to tick is
    /// worked out afresh by that frame.
    private func lookChanged() {
        let face = TerminalLook.face()
        if face != paint?.font {
            paint?.refont(face)
        }
        // Every cell a frame holds carries a colour out of the theme and,
        // in its glyph, a slot in the atlas — and both are cut from the
        // look. Saying so is what makes the next frame say all of them
        // again rather than only the rows the screen has touched.
        paint?.repaint()
        // Cells of a different size — a new face, or more room left at the
        // edges — fit in a different number: the layout has to be worked out
        // again, which presents the frame.
        needsLayout = true
        terminal.setScrollback(TerminalLook.scrollback)
        // A setting about what a program may do can change while it is
        // doing it: the hold is taken up or let go of now, and a link the
        // pointer was standing on stops being one.
        syncHeld()
        if !TerminalLook.opensLinks, hovering != nil || pointer != nil {
            hovering = nil
            NSCursor.arrow.set()
            updateTrackingAreas()
        }
        present()
    }

    // MARK: - the selection

    /// The selection, as the renderer's uniform wants it, or nothing. The
    /// scene is the one the frame is already drawing: asking the terminal
    /// for a second one would copy the whole visible grid again for
    /// nothing, which on a frame is the difference between one look and
    /// two.
    private func selection(in scene: Terminal.Scene) -> simd_float4? {
        guard let pick else { return nil }
        guard pick.0.1 >= 0, pick.0.1 < scene.lines.count, pick.1.1 >= 0, pick.1.1 < scene.lines.count else { return nil }
        let column0 = min(pick.0.0, pick.1.0), column1 = max(pick.0.0, pick.1.0)
        let row0 = min(pick.0.1, pick.1.1), row1 = max(pick.0.1, pick.1.1)
        guard column0 < scene.width, row0 < scene.height else { return nil }
        return simd_float4(
            Swift.Float(column0), Swift.Float(row0),
            Swift.Float(min(column1, scene.width - 1)), Swift.Float(min(row1, scene.height - 1))
        )
    }

    /// The words a selection holds, as they would be pasted: the span of
    /// each row it touches, and a newline between the rows. An ask that
    /// happens once — a copy, a drag's end — so one look of its own is
    /// cheaper than carrying the scene around to answer it.
    private var selected: String? {
        guard let pick, let scene = terminal.scene(scroll: lift) else { return nil }
        let row0 = max(0, min(pick.0.1, pick.1.1)), row1 = min(scene.lines.count - 1, max(pick.0.1, pick.1.1))
        let column0 = min(pick.0.0, pick.1.0), column1 = max(pick.0.0, pick.1.0)
        guard row0 <= row1 else { return nil }
        var said = ""
        for row in row0...row1 {
            let line = scene.lines[row]
            let from = row == row0 ? min(column0, line.cells.count - 1) : 0
            let till = row == row1 ? min(max(column0, column1), line.cells.count - 1) : line.cells.count - 1
            guard from <= till else { continue }
            said += String(line.cells[from...till].map(\.char))
            if row != row1 { said += "\n" }
        }
        return said.isEmpty ? nil : said
    }

    // MARK: - the keyboard

    /// The keys that say something other than themselves.
    private static let keys: [UInt16: String] = [
        36: "\r", 48: "\t", 51: "\u{7f}", 53: "\u{1b}",
        114: "\u{1b}[3~",                              // forward delete
        123: "\u{1b}[D", 124: "\u{1b}[C", 125: "\u{1b}[B", 126: "\u{1b}[A",
        115: "\u{1b}[H", 119: "\u{1b}[F",              // home, end
        116: "\u{1b}[5~", 121: "\u{1b}[6~",            // page up, page down
        122: "\u{1b}OP", 120: "\u{1b}OQ", 99: "\u{1b}OR", 118: "\u{1b}OS",
        96: "\u{1b}[15~", 97: "\u{1b}[17~", 98: "\u{1b}[18~", 100: "\u{1b}[19~",
        101: "\u{1b}[20~", 109: "\u{1b}[21~", 103: "\u{1b}[23~", 111: "\u{1b}[24~",
    ]

    /// The arrows, for the modifiers that speak through them.
    private static let arrows: [UInt16: String] = [123: "D", 124: "C", 125: "B", 126: "A"]

    /// The keys that say something different under DECCKM. A program that
    /// turned application cursor keys on — vim, less, every full-screen
    /// thing — reads SS3 for the arrows and the ends and nothing else, so
    /// a terminal that answers in CSI has its arrows come out as junk
    /// (`ESC [ A` where the program wanted `ESC O A`). The ends move with
    /// the arrows because xterm's do: they are the same "put the cursor
    /// somewhere" family, and a program that switched one switched for the
    /// other.
    private static let application: [UInt16: String] = [
        123: "\u{1b}OD", 124: "\u{1b}OC", 125: "\u{1b}OB", 126: "\u{1b}OA",
        115: "\u{1b}OH", 119: "\u{1b}OF",
    ]

    /// The keypad under DECKPAM, in the codes the hardware sent: the
    /// digits and the point keep their names, and the operators take the
    /// letters the numeric block had printed on it — `k` for the plus,
    /// `m` for the minus, `j` for the star, `o` for the slash.
    private static let keypad: [UInt16: String] = [
        82: "\u{1b}Op", 83: "\u{1b}Oq", 84: "\u{1b}Or", 85: "\u{1b}Os", 86: "\u{1b}Ot",
        87: "\u{1b}Ou", 88: "\u{1b}Ov", 89: "\u{1b}Ow", 91: "\u{1b}Ox", 92: "\u{1b}Oy",
        65: "\u{1b}On", 75: "\u{1b}Oo", 67: "\u{1b}Oj", 78: "\u{1b}Om", 69: "\u{1b}Ok",
        76: "\u{1b}OM", 81: "\u{1b}OX",
    ]

    override func keyDown(with event: NSEvent) {
        let marks = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if marks.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c", "C":
                if let held = selected {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(held, forType: .string)
                }
            case "v", "V":
                if let held = NSPasteboard.general.string(forType: .string) {
                    terminal.paste(held)
                }
            default:
                break
            }
            return
        }
        if let said = TerminalView.keys[event.keyCode] {
            if marks.contains(.shift), let letter = TerminalView.arrows[event.keyCode] {
                // A shifted arrow is CSI with the modifier whatever the
                // mode says: SS3 has nowhere to put a modifier.
                terminal.send("\u{1b}[1;2\(letter)")
            } else if modes.applicationCursor, let ss3 = TerminalView.application[event.keyCode] {
                terminal.send(ss3)
            } else {
                terminal.send(said)
            }
            return
        }
        // The keypad, for a program that asked for it (DECKPAM). Its keys
        // are characters in a text field and little function keys in a
        // calculator: a program that turned the mode on is reading the
        // second way, and wants `ESC Ok` rather than a `+` it has to guess
        // the meaning of.
        if modes.applicationKeypad, let ss3 = TerminalView.keypad[event.keyCode] {
            terminal.send(ss3)
            return
        }
        guard let words = event.characters, !words.isEmpty else { return }
        if marks.contains(.option) {
            // The option key is the terminal's meta: what it modifies is
            // sent as the escape it stands for, not the glyph it draws.
            terminal.send("\u{1b}" + (event.charactersIgnoringModifiers ?? words))
            return
        }
        terminal.send(words)
    }

    // MARK: - an input method

    override func insertText(_ string: Any) {
        if let words = string as? String { terminal.send(words) }
        unmarkText()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        insertText(string)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}

    func hasMarkedText() -> Bool { false }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Read off the live screen without copying it: the input method
        // asks this on the keystroke path, with a composing string on
        // screen, and it wants two numbers — a copy of the whole grid to
        // get them is not what a keystroke should cost.
        guard let paint else { return .zero }
        let looked = terminal.look(scroll: lift) { screen, lifted in screen.caret(lifted: lifted) }
        guard let caret = looked ?? nil else { return .zero }
        // The caret's cell: its row is counted down from the top of the
        // grid, and the view's own y up from the bottom.
        let spot = NSRect(
            x: TerminalDraw.inset + CGFloat(caret.x) * paint.cell.width,
            y: bounds.height - TerminalDraw.inset - CGFloat(caret.y + 1) * paint.cell.height,
            width: paint.cell.width, height: paint.cell.height
        )
        return convert(spot, to: nil)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func unmarkText() {}

    // MARK: - the hand

    /// Where a point is in the grid, clamped to it: the cell, in the
    /// frame's own terms. The selection, the hover and a link are about
    /// cells, so they come through here whether or not the program on the
    /// other end has been promised pixels.
    private func square(of point: NSPoint) -> (column: Int, row: Int)? {
        guard let paint else { return nil }
        let at = MouseReport.place(
            of: inGrid(point), inset: TerminalDraw.inset, cell: paint.cell,
            scale: window?.backingScaleFactor ?? 1, pixels: false
        )
        return (min(at.column, sized.width - 1), min(at.row, sized.height - 1))
    }

    /// A point as the frame counts it. This view is not flipped, so its own
    /// y runs up from the bottom — AppKit's way — and the frame's rows run
    /// down from the top, which is where the renderer draws row 0.
    /// Everything that is about to become a cell or a pixel comes through
    /// here, so that a click lands on the row it looks like it landed on
    /// rather than the one that far up from the other end.
    private func inGrid(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x, y: bounds.maxY - point.y)
    }

    /// Where a point is for the program: `square`'s cell, or — when the
    /// program asked for pixels (1016) — the pixel of the frame it is on,
    /// which is a place no cell coordinate can name and is what the mode
    /// exists for. A program drawing with the pointer over a picture wants
    /// that; the selection still wants the cell.
    private func heard(of point: NSPoint) -> (column: Int, row: Int)? {
        guard modes.mouseFormat.pixels else { return square(of: point) }
        guard let paint else { return nil }
        return MouseReport.place(
            of: inGrid(point), inset: TerminalDraw.inset, cell: paint.cell,
            scale: window?.backingScaleFactor ?? 1, pixels: true
        )
    }

    // A program that asked for the mouse gets the mouse, and one that did
    // not gets the selection. Option is the way back: a program can turn
    // mouse reporting on and then sit there swallowing every click — vim
    // and tmux both do — and without a key to override it there is no way
    // left to copy anything out of such a terminal.
    private func taken(_ event: NSEvent) -> Bool {
        TerminalLook.takesMouse && modes.mouse != .off && !event.modifierFlags.contains(.option)
    }

    /// The button number the protocol counts in — see MouseReport, where
    /// the two numberings are reconciled and the rest of the arithmetic
    /// lives, out where a test can reach it without a shell behind it.
    private func number(of event: NSEvent) -> Int {
        MouseReport.number(for: event.buttonNumber)
    }

    /// The modifiers a report carries. Option is never among them: it was
    /// checked before we got here, and it means the selection.
    private func held(_ event: NSEvent) -> Int {
        MouseReport.held(
            shift: event.modifierFlags.contains(.shift),
            control: event.modifierFlags.contains(.control)
        )
    }

    /// One mouse event, as the program asked to have it.
    private func report(
        _ button: Int, at spot: (column: Int, row: Int), dragging: Bool = false,
        release: Bool = false, _ event: NSEvent
    ) -> [UInt8] {
        MouseReport.bytes(
            button: button, column: spot.column, row: spot.row, held: held(event),
            dragging: dragging, release: release, format: modes.mouseFormat
        )
    }

    /// A wheel notch, which the program sees as a press of button 4 or 5.
    private func reportWheel(up: Bool, at spot: (column: Int, row: Int), _ event: NSEvent) -> [UInt8] {
        MouseReport.wheel(up: up, column: spot.column, row: spot.row, held: held(event), format: modes.mouseFormat)
    }

    /// Only while the pointer is being watched for a reason: a program
    /// asking for its every move (1003), or ⌘ held, which is when a hover
    /// over a link means something. An area is a mouseMoved per pixel of
    /// every pass over the terminal, and a terminal nobody is pointing
    /// into has no use for one.
    private var pointer: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointer { removeTrackingArea(pointer) }
        pointer = nil
        guard modes.mouse == .motion || overLinks else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        pointer = area
    }

    /// A move with no button held, told to the program as the motion of
    /// nothing: the protocol's "no button" is 3, and motion adds 32.
    private func moved(_ event: NSEvent) {
        guard taken(event), modes.mouse == .motion,
              let spot = heard(of: convert(event.locationInWindow, from: nil)) else { return }
        terminal.pour(report(3, at: spot, dragging: true, event))
    }

    override func mouseMoved(with event: NSEvent) {
        moved(event)
        hover(event)
    }

    override func mouseEntered(with event: NSEvent) {
        moved(event)
        hover(event)
    }

    override func mouseExited(with event: NSEvent) {
        moved(event)
        guard hovering != nil else { return }
        hovering = nil
        NSCursor.arrow.set()
        present()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let spot = square(of: point) else { return }
        // ⌘ over a link opens it. Nothing else in here is reached: a click
        // that opens a page is not also the start of a selection.
        if overLinks, let run = hovering, let url = address(of: run) {
            NSWorkspace.shared.open(url)
            return
        }
        if taken(event) {
            // The program hears the pointer in whatever unit it asked for;
            // the selection below is cells, always.
            guard let at = heard(of: point) else { return }
            terminal.pour(report(number(of: event), at: at, event))
            return
        }
        pick = nil
        anchor = spot
        present()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let spot = square(of: point) else { return }
        // 1000 is the presses alone; 1002 and 1003 want the moves between
        // them as well.
        if taken(event) {
            guard modes.mouse == .drag || modes.mouse == .motion, let at = heard(of: point) else { return }
            terminal.pour(report(number(of: event), at: at, dragging: true, event))
            return
        }
        pick = ((anchor.column, anchor.row), (spot.column, spot.row))
        present()
    }

    override func mouseUp(with event: NSEvent) {
        if taken(event), let spot = heard(of: convert(event.locationInWindow, from: nil)) {
            terminal.pour(report(number(of: event), at: spot, release: true, event))
            return
        }
        if let held = selected, !held.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(held, forType: .string)
        }
        present()
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = event.scrollingDeltaY / (paint?.cell.height ?? 13)
        guard lines != 0 else { return }
        if taken(event), let spot = heard(of: convert(event.locationInWindow, from: nil)) {
            // A trackpad's momentum arrives as a great many events, and
            // the program is owed a notch for each — but a wheel is a
            // button, and a hundred button presses for one flick is a
            // program scrolling a hundred lines where the terminal was
            // meant to scroll a dozen. Capped, and the cap is what the
            // rest of the flick is worth.
            let up = event.scrollingDeltaY > 0
            for _ in 0..<min(Int(abs(lines).rounded()), 3) {
                terminal.pour(reportWheel(up: up, at: spot, event))
            }
            return
        }
        // A swipe toward the start of the scrollback lifts the view up
        // out of it; one toward the end settles it back at the bottom.
        lift = min(max(lift + Int(lines.rounded()), 0), 10_000)
        pick = nil
        present()
    }

    // MARK: - the command blocks

    /// Walk to the next command's prompt (⌘↓), or the one before it (⌘↑).
    /// The shell prints a mark before every prompt it draws (OSC 133; see
    /// TerminalParse), and those marks — the blocks — are what there is to
    /// walk; a shell with no integration has none, and then both keys do
    /// what they do with no block that way. The prompt comes to the top of
    /// the frame. With nothing that way, forward settles back on the live
    /// screen, where the newest output is, and backward goes to the very
    /// beginning of the scrollback — so the two keys are also the way to
    /// either end of it.
    func jumpToPrompt(forward: Bool) {
        guard let went = terminal.look(scroll: lift, { screen, lifted in
            // Meant from the frame's own top row rather than from wherever
            // the lift sits, so that a second press goes on to the next
            // block instead of standing still.
            let top = screen.place(0) - lifted
            let starts = screen.blocks.map(\.first)
            let target = forward
                ? starts.first { $0 > top }
                : starts.last { $0 < top }
            guard let target else { return forward ? 0 : screen.back.count }
            return min(max(screen.place(0) - target, 0), screen.back.count)
        }) else { return }
        guard went != lift else { return }
        lift = went
        pick = nil                        // a selection means nothing once the scene moves
        present()
    }

    /// ⇧⌘K: the screen and the scrollback gone at a stroke (Terminal.clear).
    /// The wipe is done on the lane, where nothing the reader path does will
    /// account for it, so the frame is told to say everything again — the
    /// same debt a new look runs up (see lookChanged) — and the view is
    /// settled back on the living line, there being nothing left to lift to.
    func clearBuffer() {
        terminal.clear()
        lift = 0
        pick = nil
        paint?.repaint()
        present()
    }
}
