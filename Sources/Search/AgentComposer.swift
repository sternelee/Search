import AppKit

// The chat's own composer: the line you write to the agent in, and the
// model it is talking as.
//
// A terminal's chat view is a second window onto a first one, so the
// composer has to be honest about what it owns. It does not talk to the
// agent itself — it writes the line into the pty, exactly as the keyboard
// would, and the switch is the same: `/model <name>` and a return is what
// every one of these CLIs listens for, and it leaves the session's own
// history recording the change the way the agent's own menu would.
//
// What it adds over typing that by hand is the list: the models come from
// the catalog each CLI already wrote for itself (AgentModels), not from
// reading its menu off the screen. A menu is a picture; a picture of a
// list is not a list.
//
// The shape is orbit-pi's composer, translated to AppKit: a rounded box
// with the line on top and a footer of chips under it — the model on the
// left, the keys that work on the right — with the model list opening
// above the chip it belongs to.

/// The chip under the composer that says which model the agent is on and
/// opens the list. Same furniture as the pane's agent chip: a small
/// rounded ground, the terminal's ink, a caret that turns over when open.
@MainActor
final class TerminalModelChip: NSView {
    private(set) var label = ""
    private(set) var open = false
    private var face = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    var pressed: (() -> Void)?

    static let height: CGFloat = 20
    private static let pad: CGFloat = 8

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    /// Says what to show. Returns whether that changed anything — the
    /// caller only asks for a redraw when it did.
    func say(_ model: String, open: Bool) -> Bool {
        let said = Self.short(model)
        guard label != said || self.open != open else { return false }
        label = said
        self.open = open
        needsDisplay = true
        return true
    }

    /// A model id can be long and its tail is the useful part: the last
    /// two segments are what tells one from another, and the provider is
    /// the chip's business only when it is not obvious.
    static func short(_ model: String) -> String {
        let parts = model.split(separator: "/")
        guard parts.count > 1 else { return model.isEmpty ? "model" : model }
        return String(parts.suffix(2).joined(separator: "/"))
    }

    var wanted: NSSize {
        let width = (label as NSString).size(withAttributes: [.font: face as Any]).width
        // A caret's worth of room, then the two pads.
        return NSSize(width: ceil(width) + 14 + Self.pad * 2, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ground = open ? TerminalFieldPanel.word.withAlphaComponent(0.13) : TerminalFieldPanel.word.withAlphaComponent(0.055)
        ground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let ink = TerminalFieldPanel.word.withAlphaComponent(open ? 0.95 : 0.62)
        let attrs: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: ink]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(
            at: NSPoint(x: Self.pad, y: (bounds.height - size.height) / 2), withAttributes: attrs
        )
        // The caret: a small chevron, down when closed and up when open,
        // so the chip reads as a menu either way it stands.
        let x = bounds.width - Self.pad - 6
        let mid = bounds.midY
        let caret = NSBezierPath()
        if open {
            caret.move(to: NSPoint(x: x, y: mid - 1.5))
            caret.line(to: NSPoint(x: x + 3, y: mid + 2))
            caret.line(to: NSPoint(x: x + 6, y: mid - 1.5))
        } else {
            caret.move(to: NSPoint(x: x, y: mid + 1.5))
            caret.line(to: NSPoint(x: x + 3, y: mid - 2))
            caret.line(to: NSPoint(x: x + 6, y: mid + 1.5))
        }
        caret.lineWidth = 1.2
        caret.lineCapStyle = .round
        ink.withAlphaComponent(0.8).setStroke()
        caret.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        pressed?()
    }

    /// A chip takes its own clicks and nothing else does: the corner
    /// around it stays the composer's, the way the pane's chip leaves the
    /// terminal its own. `frame`, not `bounds` — the point arrives in the
    /// superview's space.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
}

/// The list of models, opened above its chip. A view rather than a menu so
/// it can show the group headings and the notes the agents' catalogs have,
/// and so the keyboard can walk it while the line below keeps its text.
@MainActor
final class TerminalModelList: NSView {
    private var rows: [AgentModels.Row] = []
    private var shown: [AgentModels.Row] = []
    private var face = NSFont.systemFont(ofSize: 11.5)
    private var noteFace = NSFont.systemFont(ofSize: 10)
    private var headFace = NSFont.systemFont(ofSize: 9, weight: .semibold)

    /// Which row the keyboard is on, as an index into `shown`. Always a
    /// row that can be chosen — a heading is skipped, never selected.
    private(set) var highlighted = 0
    /// Where the list is scrolled to, in points from the top. A mouse
    /// wheel sets it; the keyboard keeps its row in view through it.
    private var scroll: CGFloat = 0
    private var current = ""

    var chosen: ((AgentModels.Row) -> Void)?

    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 22
    static let headHeight: CGFloat = 18
    private static let pad: CGFloat = 6
    private static let visible: CGFloat = 7

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    /// Hands the list what to show. The current model is put under the
    /// keyboard's first step, so opening the list and pressing return
    /// changes nothing — and a `note` saying so is what marks it.
    func take(_ rows: [AgentModels.Row], current: String) {
        self.rows = rows
        self.current = current
        shown = rows
        scroll = 0
        highlighted = rows.firstIndex { !$0.head && $0.value == current }
            ?? rows.firstIndex { !$0.head } ?? 0
        needsDisplay = true
        scrollHighlightIntoView()
    }

    var holes: Bool { shown.contains { !$0.head } }

    /// The list's own height: what its rows need, up to the point it
    /// scrolls instead of growing.
    var wanted: NSSize {
        let tall = shown.reduce(CGFloat.zero) { $0 + ($1.head ? Self.headHeight : Self.rowHeight) }
        let room = Self.headHeight + Self.rowHeight * Self.visible
        return NSSize(width: Self.width, height: min(tall + Self.pad * 2, room))
    }

    private var contentHeight: CGFloat {
        shown.reduce(CGFloat.zero) { $0 + ($1.head ? Self.headHeight : Self.rowHeight) } + Self.pad * 2
    }

    // MARK: - the keyboard

    /// ↑/↓ move the highlight, skipping the headings as they go. Said
    /// whether the key was the list's — a key at the top with nothing to
    /// go to is still the list's, or the line under it would move.
    func step(_ by: Int) -> Bool {
        guard holes else { return true }
        var at = highlighted
        repeat {
            at += by
            if at < 0 { at = shown.count - 1 }
            if at >= shown.count { at = 0 }
        } while shown[at].head && at != highlighted
        highlighted = at
        scrollHighlightIntoView()
        needsDisplay = true
        return true
    }

    /// ⏎ takes the highlighted row, unless it is the one already in use —
    /// then it just closes, which is the polite answer to "keep going".
    func choose() -> AgentModels.Row? {
        guard holes, highlighted < shown.count, !shown[highlighted].head else { return nil }
        return shown[highlighted]
    }

    private func scrollHighlightIntoView() {
        guard holes else { return }
        // Nothing can be scrolled into a view that has not been laid out
        // yet: a view built and handed rows in the same breath has a zero
        // height, and "keep the row visible" then scrolls to the end of
        // the list rather than to the row. The scrolled answer is asked
        // for again by `layout`, which is when the height is real.
        guard bounds.height > 1 else { return }
        var top = Self.pad
        for (at, row) in shown.enumerated() {
            let height = row.head ? Self.headHeight : Self.rowHeight
            if at == highlighted {
                let bottom = top + height
                if top < scroll + Self.pad { scroll = top - Self.pad }
                if bottom > scroll + bounds.height - Self.pad {
                    // Keep the row's bottom at the list's bottom, so a
                    // step down always shows the row it landed on.
                    scroll = bottom - bounds.height + Self.pad
                }
                scroll = max(0, min(scroll, max(0, contentHeight - bounds.height)))
                return
            }
            top += height
        }
    }

    /// The rows were handed over before this view had a height; the first
    /// layout is where the highlight can finally be put in view.
    override func layout() {
        super.layout()
        guard holes else { return }
        scrollHighlightIntoView()
    }

    // MARK: - the mouse

    override func scrollWheel(with event: NSEvent) {
        scroll = max(0, min(scroll - event.scrollingDeltaY, max(0, contentHeight - bounds.height)))
        needsDisplay = true
    }

    /// A click on a row picks it: the list is short and the pointer is
    /// already on it, so making a person move to the keyboard would be
    /// the wrong sort of consistency.
    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        var top = Self.pad - scroll
        for row in shown {
            let height = row.head ? Self.headHeight : Self.rowHeight
            if at.y >= top, at.y < top + height, !row.head {
                chosen?(row)
                return
            }
            top += height
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    // MARK: - the lines

    override func draw(_ dirtyRect: NSRect) {
        // The list's ground is the composer's, one step raised so it
        // reads as a thing laid over the talk rather than in it.
        TerminalChatView.ground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        TerminalFieldPanel.word.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        TerminalFieldPanel.word.withAlphaComponent(0.14).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        edge.lineWidth = 1
        edge.stroke()

        let clip = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()

        var top = Self.pad - scroll
        for (at, row) in shown.enumerated() {
            let height = row.head ? Self.headHeight : Self.rowHeight
            let box = NSRect(x: 0, y: bounds.height - top - height, width: bounds.width, height: height)
            if box.maxY > 0, box.minY < bounds.height {
                if row.head {
                    drawHeading(row.label, in: box)
                } else {
                    drawRow(row, in: box, lit: at == highlighted, on: row.value == current)
                }
            }
            top += height
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHeading(_ words: String, in box: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: headFace,
            .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(0.34),
            .kern: 0.6,
        ]
        let size = (words.uppercased() as NSString).size(withAttributes: attrs)
        (words.uppercased() as NSString).draw(
            at: NSPoint(x: 10, y: box.midY - size.height / 2), withAttributes: attrs
        )
    }

    private func drawRow(_ row: AgentModels.Row, in box: NSRect, lit: Bool, on: Bool) {
        if lit {
            TerminalFieldPanel.word.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let ink = TerminalFieldPanel.word.withAlphaComponent(lit ? 0.98 : 0.78)
        let attrs: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: ink]
        let label = row.label as NSString
        let size = label.size(withAttributes: attrs)
        // The note is drawn from the right, and the label gets what is
        // left: a long label is cut, never the note that explains it.
        let noteAttrs: [NSAttributedString.Key: Any] = [
            .font: noteFace,
            .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(lit ? 0.52 : 0.34),
        ]
        let note = row.note as NSString
        let noteSize = note.size(withAttributes: noteAttrs)
        let noteRoom = noteSize.width > 0 ? min(noteSize.width, bounds.width * 0.5) : 0
        let labelRoom = bounds.width - 20 - (noteRoom > 0 ? noteRoom + 10 : 0)
        let y = box.midY - size.height / 2
        label.draw(
            with: NSRect(x: 10, y: y, width: max(20, labelRoom), height: size.height),
            options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attrs
        )
        if noteRoom > 0 {
            note.draw(
                with: NSRect(
                    x: bounds.width - 10 - noteRoom, y: box.midY - noteSize.height / 2,
                    width: noteRoom, height: noteSize.height
                ),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: noteAttrs
            )
        }
        if on {
            // The model in use wears a dot at the far left, the same mark
            // the pane's chip uses for "this is the one".
            TerminalFieldPanel.word.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: box.midY - 1.5, width: 3, height: 3)).fill()
        }
    }
}
