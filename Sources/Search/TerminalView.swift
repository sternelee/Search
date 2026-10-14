import AppKit
import simd

// The terminal as a view: one CAMetalLayer the renderer draws into (see
// TerminalDraw.swift), a keyboard and an input method feeding the program
// through the Terminal, and a hand that picks words out of the scrollback.
//
// Nothing here draws anything itself, and nothing asks for a frame until
// something changed: output, a keystroke, a scroll, a selection, a focus.
// A metal layer is never drawn by AppKit — no context comes to a `draw` it
// could call — so the frame is presented by whatever changed it, and that
// is the whole of the frame schedule there is.

@MainActor
final class TerminalView: NSView, NSTextInputClient {
    let terminal: Terminal

    /// The renderer, when there was one to have: it owns the layer this
    /// view draws through.
    private var paint: TerminalDraw?

    /// The size the terminal was last told it is, in cells.
    private var sized = (width: 0, height: 0)
    /// How far the view is lifted out of the scrollback, in lines. Zero is
    /// the bottom, where the caret is.
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

    init(terminal given: Terminal, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
        terminal = given
        paint = TerminalDraw(font: font)
        super.init(frame: .zero)
        wantsLayer = true
        terminal.onDraw = { [weak self] _, _ in self?.moved() }
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        paint?.layer ?? CAMetalLayer()
    }

    // MARK: - laid out

    override var acceptsFirstResponder: Bool { true }

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
        present()
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        present()
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        present()
        return gave
    }

    // MARK: - one frame

    // A view backed by a CAMetalLayer is never drawn by AppKit: a metal
    // layer has no context to hand a `draw`, so the redraw AppKit owes
    // on `needsDisplay` goes nowhere — MetalKit's own view drives itself
    // for the same reason. So the frames here are driven the way the
    // zero-frame promise wants them anyway: something changed — output,
    // a keystroke, a scroll, a selection, a focus — and the frame is
    // presented then and only then. Nothing scheduled, nothing idle,
    // nothing drawn that nobody asked for.
    //
    // `draw` stays for the direct asks: `StageView.settle` marks a
    // landing view dirty, and nothing of ours ever needs it, but a
    // `display()` from anywhere still finds a frame here.

    /// Something the terminal said or did: a frame now has something to
    /// show. What the frame shows is asked of the terminal when the frame
    /// is drawn — never kept here, where it would sit between the two.
    private func moved() {
        present()
        // A search standing in a screen that moved under it follows the
        // rows it found (see TerminalFind).
        if findField != nil { research() }
    }

    override func draw(_ dirtyRect: NSRect) {
        present()
    }

    /// The frame itself: what the scene says, asked of the terminal, put
    /// on the layer. Whatever changed — the terminal's output, a key, a
    /// scroll, the layout — presents its own frame here (TerminalFind
    /// carries its hits here too).
    func present() {
        guard let paint, let scene = terminal.scene(scroll: lift) else { return }
        lift = min(lift, scene.back)
        paint.refresh(
            scene: scene, selection: selection, strong: window?.firstResponder === self,
            marks: scene.marks, finds: finds(in: scene), found: found(in: scene)
        )
        paint.render()
    }

    /// The selection, as the renderer's uniform wants it, or nothing.
    private var selection: simd_float4? {
        guard let pick, let scene = terminal.scene(scroll: lift) else { return nil }
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
    /// each row it touches, and a newline between the rows.
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
                terminal.send("\u{1b}[1;2\(letter)")
            } else {
                terminal.send(said)
            }
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
        guard let scene = terminal.scene(scroll: lift), let paint,
              let caret = scene.caret else { return .zero }
        let spot = NSRect(
            x: TerminalDraw.inset + CGFloat(caret.x) * paint.cell.width,
            y: TerminalDraw.inset + CGFloat(caret.y) * paint.cell.height,
            width: paint.cell.width, height: paint.cell.height
        )
        return convert(spot, to: nil)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func unmarkText() {}

    // MARK: - the hand

    /// Where a point is in the grid, clamped to it.
    private func square(of point: NSPoint) -> (column: Int, row: Int)? {
        guard let paint else { return nil }
        let column = Int((point.x - TerminalDraw.inset) / paint.cell.width)
        let row = Int((point.y - TerminalDraw.inset) / paint.cell.height)
        return (min(max(column, 0), sized.width - 1), min(max(row, 0), sized.height - 1))
    }

    override func mouseDown(with event: NSEvent) {
        guard let spot = square(of: convert(event.locationInWindow, from: nil)) else { return }
        pick = nil
        anchor = spot
        present()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let spot = square(of: convert(event.locationInWindow, from: nil)) else { return }
        pick = ((anchor.column, anchor.row), (spot.column, spot.row))
        present()
    }

    override func mouseUp(with event: NSEvent) {
        if let held = selected, !held.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(held, forType: .string)
        }
        present()
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = event.scrollingDeltaY / (paint?.cell.height ?? 13)
        guard lines != 0 else { return }
        // A swipe toward the start of the scrollback lifts the view up
        // out of it; one toward the end settles it back at the bottom.
        lift = min(max(lift + Int(lines.rounded()), 0), 10_000)
        pick = nil
        present()
    }
}
