import AppKit

// The chat view: the same agent, read as a conversation instead of as a
// screen (see AgentTalk for where the conversation comes from).
//
// A coding agent's terminal is a bad place to read it back. Its answers
// scroll away, its own redraws interleave with them, and a question two
// turns up is gone — the terminal holds the last screen, the agent's
// transcript holds the talk. So the pane gets a second view onto the same
// run: the chip in its corner says which agent is in there, and pressing
// it lays the conversation over the grid.
//
// Nothing here is a copy of the talk. The terminal keeps running under
// the plate, unseen, and typing in the chat's own line writes to that
// same terminal — the bytes a keyboard would have sent, plus the return.
// The terminal stays the truth; this is a second reading of it that
// remembers further back.
//
// It is drawn with AppKit rather than made of SwiftUI views for the
// reason the rest of the terminal is: a transcript is hundreds of rows of
// text and a scroll, and every row should be a draw, not a view.

// MARK: - the plate

/// The conversation itself: what the person said, what the agent said,
/// what it thought, and what tools it used — laid out top to bottom,
/// scrolled as far as the eye goes, and following the bottom while the
/// talk goes on.
@MainActor
final class TerminalChatPaper: NSView {
    /// One row of the view: a turn's part, and where it goes once the
    /// width is known. Turns are the model's; items are what a frame
    /// walks, which is why the layout is kept beside them rather than
    /// derived every draw.
    private struct Item {
        enum Kind {
            case said(ChatLog.Role)
            case thought
            case tool(ChatLog.Tool)
        }
        let kind: Kind
        let text: String
        /// Laid out at this width: how tall the row is, in points.
        var height: CGFloat = 0
        /// Where it starts, from the top of the whole talk.
        var top: CGFloat = 0
    }

    private var items: [Item] = []
    /// What was laid out, said compactly: the talk is only relaid when
    /// this differs, and a tool's answer arriving is a difference the
    /// item's own text does not carry (a call laid out twice, once
    /// answered and once not, is two different rows of the same words).
    private var laid: [String] = []
    /// The width the heights were measured at. A plate that changes width
    /// re-measures every row — wrapping is the one thing that cannot be
    /// carried over.
    private var measured: CGFloat = 0
    private var total: CGFloat = 0
    /// How far up the talk is scrolled, in points from the bottom. 0 is
    /// the live end, which is where a person who has not scrolled is.
    private var scroll: CGFloat = 0
    /// Whether the view is following the end. Scrolling up stops it;
    /// coming back to the bottom starts it again.
    private var following = true
    /// Where tool output is folded in — a set of the items a person
    /// opened. Reset when the talk is replaced, kept while it grows.
    private var opened: Set<Int> = []

    /// The face the talk is written in: the terminal's own, a step down
    /// from the grid's so a paragraph of it reads as prose.
    private var face = TerminalLook.face(size: max(11, TerminalLook.size - 1))
    private var bold = NSFontManager.shared.convert(
        TerminalLook.face(size: max(11, TerminalLook.size - 1)), toHaveTrait: .boldFontMask
    )

    /// The talk as it stands, and whether it changed enough to be drawn.
    /// The reader hands the same log over every tick; a log whose turns
    /// are still the ones laid out costs nothing.
    func take(_ log: ChatLog) {
        var next: [Item] = []
        for turn in log.turns {
            for part in turn.parts {
                switch part {
                case .word(let said):
                    next.append(Item(kind: .said(turn.role), text: said))
                case .thought(let said):
                    next.append(Item(kind: .thought, text: said))
                case .tool(let tool):
                    next.append(Item(kind: .tool(tool), text: tool.name))
                }
            }
        }
        var sigs: [String] = []
        for turn in log.turns {
            for part in turn.parts {
                switch part {
                case .word(let said): sigs.append("w\(said)")
                case .thought(let said): sigs.append("h\(said)")
                case .tool(let tool): sigs.append("t\(tool.name)\u{1}\(tool.summary)\u{1}\(tool.output)\u{1}\(tool.failed)")
                }
            }
        }
        guard sigs != laid else { return }
        laid = sigs
        items = next
        // A talk that only grew keeps its place; one that was replaced
        // (a new run in the same pane) starts at the live end again.
        measured = 0
        if following { scroll = 0 }
        needsDisplay = true
    }

    func refont() {
        face = TerminalLook.face(size: max(11, TerminalLook.size - 1))
        bold = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask)
        measured = 0
        needsDisplay = true
    }

    /// Back to the live end, following what comes next. A line just
    /// written is the one thing certain to be followed by an answer.
    func follow() {
        scroll = 0
        following = true
        needsDisplay = true
    }

    /// Whether anything is worth a frame: an empty talk draws its own
    /// line of text, which is still a draw.
    var empty: Bool { items.isEmpty }

    // MARK: laying the talk out

    private static let margin: CGFloat = 18
    private static let gutter: CGFloat = 14
    private static let air: CGFloat = 6
    /// The bar a person's turn wears on its left, the way a quoted line
    /// does in an editor.
    private static let mark: CGFloat = 2

    /// The room the words get, inside the margins and the gutter.
    private var inner: CGFloat { max(80, bounds.width - Self.margin * 2 - Self.gutter) }

    private func measure() {
        let width = inner
        guard width != measured else { return }
        measured = width
        var top: CGFloat = 0
        for i in items.indices {
            items[i].height = height(of: items[i], at: i, width: width)
            items[i].top = top
            top += items[i].height + Self.air
        }
        total = top
    }

    private func height(of item: Item, at index: Int, width: CGFloat) -> CGFloat {
        switch item.kind {
        case .said:
            return max(18, box(item.text, font: face, width: width).height + 4)
        case .thought:
            return max(16, box(item.text, font: face, width: width - Self.gutter).height + 2)
        case .tool(let tool):
            // The call is one line — its summary — and the answer is
            // folded until asked for: a transcript of a busy agent is
            // mostly output, and output read whole is the screen again.
            let head = row(tool, width: width)
            guard opened.contains(index), !tool.output.isEmpty else { return head + 2 }
            return head + 2 + box(tool.output, font: face, width: width - Self.gutter).height + 6
        }
    }

    /// A tool call as one line: whether it failed, what it was, and what
    /// it was called on.
    private func row(_ tool: ChatLog.Tool, width: CGFloat) -> CGFloat {
        let said = (tool.failed ? "✗ " : "⏵ ") + tool.name
        let line = tool.summary.isEmpty ? said : said + "  " + tool.summary
        let one = (line as NSString).boundingRect(
            with: NSSize(width: width - Self.gutter, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: face as Any]
        )
        return max(16, min(one.height, 18))
    }

    private func box(_ text: String, font: NSFont, width: CGFloat) -> NSRect {
        (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font as Any]
        )
    }

    // MARK: drawing it

    /// The colours, taken from the terminal's own theme so the plate is
    /// the same terminal seen differently rather than the app's chrome on
    /// top of it.
    private static var theme: TerminalDraw.Theme { .current(TerminalLook.theme) }

    private var ground: NSColor {
        let theme = Self.theme
        return NSColor(
            srgbRed: CGFloat(theme.ground.x), green: CGFloat(theme.ground.y),
            blue: CGFloat(theme.ground.z), alpha: 1
        )
    }

    private var ink: NSColor { TerminalFieldPanel.word }

    override func draw(_ dirtyRect: NSRect) {
        measure()
        ground.setFill()
        bounds.fill()
        guard !items.isEmpty else {
            ("This run has not said anything yet." as NSString).draw(
                in: NSRect(x: Self.margin, y: bounds.height - 40, width: inner, height: 20),
                withAttributes: [.font: face as Any, .foregroundColor: ink.withAlphaComponent(0.35)]
            )
            return
        }
        // Where the visible part of the talk starts, in talk points: the
        // talk is laid out from its own top, and the plate is a window
        // onto the end of it.
        let reachable = bounds.height
        let start = max(0, min(scroll, max(0, total - reachable)))
        // A talk shorter than the plate starts at its top, where a reader
        // begins, instead of collecting at the bottom and leaving the rest
        // of the pane blank above it. Longer than the plate, and the clamp
        // does nothing: the window is onto the end of the talk as before.
        let from = max(0, total - start - reachable)
        let clip = NSRect(x: 0, y: 0, width: bounds.width, height: reachable)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        for i in items.indices {
            let item = items[i]
            let y = bounds.height - (item.top - from) - item.height
            guard y + item.height > 0, y < bounds.height else { continue }
            draw(item, at: y, width: inner, index: i)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ item: Item, at y: CGFloat, width: CGFloat, index: Int) {
        let x = Self.margin + Self.gutter
        switch item.kind {
        case .said(.person):
            // A person's line, marked on the left: the one thing in the
            // talk that is not the agent's own words.
            ink.withAlphaComponent(0.5).setFill()
            NSRect(x: Self.margin, y: y + 1, width: Self.mark, height: max(14, item.height - 2)).fill()
            (item.text as NSString).draw(
                in: NSRect(x: x, y: y, width: width, height: item.height),
                withAttributes: [.font: bold as Any, .foregroundColor: ink]
            )
        case .said(.agent):
            (item.text as NSString).draw(
                in: NSRect(x: x, y: y, width: width, height: item.height),
                withAttributes: [.font: face as Any, .foregroundColor: ink.withAlphaComponent(0.92)]
            )
        case .thought:
            // What it thought before saying: dimmer, and set off by the
            // gutter, so a long reasoning turn never reads as an answer.
            (item.text as NSString).draw(
                in: NSRect(x: x, y: y, width: width, height: item.height),
                withAttributes: [.font: face as Any, .foregroundColor: ink.withAlphaComponent(0.40)]
            )
        case .tool(let tool):
            let said = (tool.failed ? "✗ " : "⏵ ") + tool.name + (tool.summary.isEmpty ? "" : "  " + tool.summary)
            let color = tool.failed ? NSColor.systemRed.withAlphaComponent(0.75) : ink.withAlphaComponent(0.5)
            (said as NSString).draw(
                in: NSRect(x: x, y: y, width: width, height: min(item.height, 18)),
                withAttributes: [.font: face as Any, .foregroundColor: color]
            )
            guard opened.contains(index), !tool.output.isEmpty else { return }
            let fold = NSRect(x: x, y: y - box(tool.output, font: face, width: width).height - 2,
                              width: width, height: box(tool.output, font: face, width: width).height)
            ink.withAlphaComponent(0.30).setFill()
            NSRect(x: x, y: fold.maxY + 2, width: 1, height: fold.height).fill()
            (tool.output as NSString).draw(
                in: fold.offsetBy(dx: 8, dy: 0),
                withAttributes: [.font: face as Any, .foregroundColor: ink.withAlphaComponent(0.45)]
            )
        }
    }

    // MARK: walking it

    override func scrollWheel(with event: NSEvent) {
        measure()
        let room = max(0, total - bounds.height)
        scroll = min(room, max(0, scroll + event.scrollingDeltaY))
        // At the live end again: the talk follows from here on, which is
        // what a person who scrolled back down wants.
        following = scroll <= 0.5
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // A click on a tool's line folds or unfolds its output.
        measure()
        let point = convert(event.locationInWindow, from: nil)
        let start = max(0, min(scroll, max(0, total - bounds.height)))
        let from = max(0, total - start - bounds.height)
        for i in items.indices {
            let y = bounds.height - (items[i].top - from) - items[i].height
            guard point.y >= y, point.y <= y + items[i].height else { continue }
            guard case .tool(let tool) = items[i].kind, !tool.output.isEmpty else { return }
            if opened.contains(i) { opened.remove(i) } else { opened.insert(i) }
            measured = 0
            needsDisplay = true
            return
        }
    }
}

// MARK: - the whole thing

/// The overlay: the conversation, and the line to answer it with. Both
/// belong to the terminal's frame rather than to a window of their own —
/// the pane is where the agent lives, and the pane is where its talk is
/// read.
@MainActor
final class TerminalChatView: NSView {
    let paper = TerminalChatPaper()
    let field = NSTextField(string: "")
    /// The model the agent is on, in the composer's footer, and the list
    /// that opens above it.
    let model = TerminalModelChip()
    let list = TerminalModelList()

    private var face = TerminalLook.face(size: max(11, TerminalLook.size - 1))
    private static let margin: CGFloat = 12
    private static let inset: CGFloat = 12
    private static let lineHeight: CGFloat = 28
    private static let footHeight: CGFloat = 24
    private static let bottom: CGFloat = 12
    /// How tall the line may grow before it scrolls instead: a question
    /// worth six lines is worth reading back, and a box that keeps growing
    /// would eat the talk it is asking about.
    private static let mostLines: CGFloat = 6
    private static let textLine: CGFloat = 17

    /// Whether the model list is up. Kept here rather than in the list so
    /// the keyboard can ask one question — "is a list asking for this
    /// key?" — instead of two views holding half the answer each.
    private(set) var askingModels = false

    /// What a return in the line does: the words, to the terminal, as
    /// though they had been typed at it. The chat has no way of its own
    /// to talk to the agent, and shouldn't: the CLI's own stdin is the
    /// one channel both views share.
    var spoke: ((String) -> Void)?
    /// Escape, or a click outside the line: the talk goes away and the
    /// keyboard goes back to the screen.
    var escaped: (() -> Void)?
    /// A model chosen from the list: its `value`, to the terminal as the
    /// agent's own `/model` command.
    var switched: ((String) -> Void)?

    /// The composer's box, in `bounds` coordinates. Every other part of
    /// the view is placed against it, so the box is described once. It
    /// grows upward with the words in the line: the foot stays where it
    /// is, so the keys do not move while a person is typing at them.
    private var box: NSRect {
        NSRect(
            x: Self.inset, y: Self.bottom,
            width: max(80, bounds.width - Self.inset * 2),
            height: lineArea + Self.footHeight
        )
    }

    /// How tall the writing part is: one line, more while the words wrap,
    /// and no more than `mostLines` — past that the field editor scrolls
    /// its own text, which keeps the box off the conversation.
    ///
    /// Measured from the words themselves rather than from the cell: a
    /// wrapping cell's `cellSize` answers with one line's worth for text
    /// that has not been laid out yet, which would leave the third line of
    /// a question clipped inside a box that never grew for it.
    private var lineArea: CGFloat {
        let wide = max(40, bounds.width - Self.inset * 2 - 24 - 4)
        let words = field.stringValue
        guard !words.isEmpty else { return Self.lineHeight }
        let height = (words as NSString).boundingRect(
            with: NSSize(width: wide, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: face]
        ).height
        return max(
            Self.lineHeight,
            min(height + 10, Self.lineHeight + Self.textLine * (Self.mostLines - 1))
        )
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(paper)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = face
        field.textColor = TerminalFieldPanel.word
        field.delegate = self
        // The line wraps and keeps the newlines a person puts in it. A
        // field that could not hold them would silently swallow Shift-⏎,
        // and a question written in three sentences would arrive as one.
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = Int(Self.mostLines)
        field.lineBreakMode = .byWordWrapping
        addSubview(field)
        model.pressed = { [weak self] in self?.toggleModels() }
        addSubview(model)
        list.chosen = { [weak self] row in self?.take(row) }
        list.isHidden = true
        addSubview(list)
        refont()
    }

    required init?(coder: NSCoder) { nil }

    /// The talk, as the reader holds it.
    func take(_ log: ChatLog) { paper.take(log) }

    /// What the agent can be switched to, and what it is on now. The list
    /// is rebuilt from this, and the chip says the current one in the
    /// same words the list's rows use — so the open list always has one
    /// row that is visibly the one in use.
    func takeModels(_ rows: [AgentModels.Row], current: String) {
        self.current = current
        rowsSnapshot = rows
        let before = model.label
        _ = model.say(current, open: askingModels)
        list.take(rows, current: current)
        // A chip that changed its words has changed its width, and the
        // list hangs off its corner.
        if model.label != before { needsLayout = true }
        if askingModels {
            list.needsDisplay = true
            needsLayout = true
        }
    }

    /// The current model, as the chip says it.
    var modelWords: String { current }
    private var current = ""

    func refont() {
        face = TerminalLook.face(size: max(11, TerminalLook.size - 1))
        field.font = face
        field.placeholderAttributedString = NSAttributedString(
            string: "Write to the agent…",
            attributes: [.font: face, .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(0.35)]
        )
        paper.refont()
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - the list

    /// Opens the list over the composer, or closes it. What a person is
    /// typing is not disturbed: the field keeps the keyboard and its text
    /// while the list is up, the way a command palette does.
    func toggleModels(open: Bool? = nil) {
        let want = open ?? !askingModels
        guard want != askingModels else { return }
        guard !want || list.holes else { return }
        askingModels = want
        list.isHidden = !want
        _ = model.say(current, open: want)
        if want {
            list.take(rowsSnapshot, current: current)
        }
        needsLayout = true
        needsDisplay = true
    }

    /// The rows the list was handed; kept so opening and closing does not
    /// need them again from the agent.
    private var rowsSnapshot: [AgentModels.Row] = []

    /// One row taken — by the keyboard or the pointer. The list closes and
    /// the switch goes to the terminal; the chip says the new model at
    /// once, so the answer is visible before the agent has drawn anything.
    func take(_ row: AgentModels.Row) {
        toggleModels(open: false)
        current = row.value
        _ = model.say(row.value, open: false)
        needsLayout = true
        switched?(row.value)
        if let window { window.makeFirstResponder(field) }
    }

    override func layout() {
        super.layout()
        let box = self.box
        paper.frame = NSRect(
            x: 0, y: box.maxY, width: bounds.width,
            height: max(0, bounds.height - box.maxY)
        )
        // The text sits at the top of the writing part, where the first
        // line began when there was only one: a box that grows upward
        // must not move the words already in it.
        field.frame = NSRect(
            x: box.minX + 12, y: box.minY + Self.footHeight + 5,
            width: max(40, box.width - 24), height: max(19, lineArea - 10)
        )
        let want = model.wanted
        model.frame = NSRect(
            x: box.minX + 8, y: box.minY + (Self.footHeight - want.height) / 2,
            width: want.width, height: want.height
        )
        guard askingModels else { list.frame = .zero; return }
        let tall = list.wanted
        // Above the chip it belongs to, and never off the top of the pane:
        // a list that opens past the edge would hide its own first rows.
        var y = box.maxY + 6
        if y + tall.height > bounds.height - 6 {
            y = max(6, bounds.height - 6 - tall.height)
        }
        let width = min(tall.width, max(120, bounds.width - Self.inset * 2 - 8))
        list.frame = NSRect(x: box.minX + 8, y: y, width: width, height: tall.height)
    }

    /// The talk's own ground under everything, then the composer's box: a
    /// rounded ground one step raised, with the line above and the footer
    /// under it. The same furniture as the dock's plate, in a second place.
    override func draw(_ dirtyRect: NSRect) {
        TerminalChatView.ground.setFill()
        bounds.fill()

        let box = self.box
        let ground = TerminalChatView.ground
        ground.withAlphaComponent(DockBox.ground).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        TerminalFieldPanel.word.withAlphaComponent(0.11).setStroke()
        let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        edge.lineWidth = 1
        edge.stroke()

        // The hairline between the line and its footer, stopped short of
        // both ends so the box still reads as one thing.
        TerminalFieldPanel.word.withAlphaComponent(0.07).setStroke()
        let hair = NSBezierPath()
        hair.move(to: NSPoint(x: box.minX + 10, y: box.minY + Self.footHeight - 0.5))
        hair.line(to: NSPoint(x: box.maxX - 10, y: box.minY + Self.footHeight - 0.5))
        hair.lineWidth = 1
        hair.stroke()

        // What the keys do, at the footer's right: a chat whose only
        // affordances are a chip and a line would leave return and escape
        // for a person to guess.
        let keys = "⏎ send   ⇧⏎ newline   esc close"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(0.26),
        ]
        let said = (keys as NSString).size(withAttributes: attrs)
        (keys as NSString).draw(
            at: NSPoint(
                x: box.maxX - 10 - said.width,
                y: box.minY + (Self.footHeight - said.height) / 2
            ), withAttributes: attrs
        )
    }

    /// The talk's own ground, the same one every part of the terminal's
    /// furniture is made of.
    static var ground: NSColor {
        let theme = TerminalDraw.Theme.current(TerminalLook.theme)
        return NSColor(
            srgbRed: CGFloat(theme.ground.x), green: CGFloat(theme.ground.y),
            blue: CGFloat(theme.ground.z), alpha: 1
        )
    }

    /// The keyboard goes into the line the moment the talk is laid over
    /// the grid: opening a chat and having to click before typing would
    /// be opening it twice.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.field)
        }
    }
}

extension TerminalChatView: NSTextFieldDelegate {
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        // The list, while it is up, is where the arrow keys go — and a
        // return takes its row rather than sending the line, so a person
        // who opened the list to change models is not made to also send
        // whatever they had half-typed. Escape closes it one step at a
        // time: list first, then the talk.
        if askingModels {
            if selector == #selector(NSResponder.moveUp(_:)) { return list.step(-1) }
            if selector == #selector(NSResponder.moveDown(_:)) { return list.step(1) }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if let row = list.choose() { take(row) }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                toggleModels(open: false)
                return true
            }
        }
        // Down, with no list up, opens one: the chip is small and in a
        // corner, and a switch should not require finding it with the
        // pointer while the keyboard is already in the line.
        if selector == #selector(NSResponder.moveDown(_:)) {
            toggleModels(open: true)
            return true
        }
        // Return sends the line; Escape gives the pane back to the
        // terminal, which is where a person who is done asking goes.
        // Shift-return, and option-return, arrive as the editor's own
        // "newline but do not end editing" — the same intent, so the same
        // answer: a line break in the question, not a send.
        if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            field.currentEditor()?.insertNewline(nil)
            needsLayout = true
            needsDisplay = true
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Shift-return puts a line break in the question instead of
            // sending it: a question that needs three sentences should not
            // have to be one. Asked of the event rather than of the text,
            // because the field editor has already eaten the modifier by
            // the time a key arrives here.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            if shift {
                field.currentEditor()?.insertNewline(nil)
                needsLayout = true
                needsDisplay = true
                return true
            }
            let said = field.stringValue.trimmed
            guard !said.isEmpty else { return true }
            field.stringValue = ""
            needsLayout = true
            needsDisplay = true
            spoke?(said)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            escaped?()
            return true
        }
        return false
    }

    /// Words arriving are what make the box grow, so the layout is asked
    /// for again on every change rather than only when a key is caught
    /// above: a paste and a dead-key composition both change the text
    /// without passing through `doCommandBy`.
    func controlTextDidChange(_ note: Notification) {
        needsLayout = true
        needsDisplay = true
    }
}

// MARK: - the chip

/// The chip in the pane's corner: which agent is in here, and the switch
/// between the screen and the talk. Only present while an agent that can
/// be read as a conversation is in the terminal — a chip offering a view
/// of nothing would be a switch to nowhere.
@MainActor
final class TerminalChatPill: NSView {
    /// What it says: the agent's name, and whether the talk is up.
    private(set) var name = ""
    private(set) var showing = false

    private var face = NSFont.systemFont(ofSize: 10, weight: .medium)
    private var advance: CGFloat = 6

    /// Pressing it: the terminal's to answer, the way the dock's plate
    /// answers for its own line.
    var pressed: (() -> Void)?

    static let height: CGFloat = 20
    static let inset: CGFloat = 10

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        remeasure()
    }

    required init?(coder: NSCoder) { nil }

    /// The size it wants for the words and the glyph in it.
    var wanted: NSSize {
        NSSize(width: Self.height / 2 * 2 + label.width, height: Self.height)
    }

    private var label: NSSize {
        (name as NSString).size(withAttributes: [.font: face as Any])
    }

    func say(_ agent: String, showing: Bool) -> Bool {
        guard name != agent || self.showing != showing else { return false }
        name = agent
        self.showing = showing
        remeasure()
        needsDisplay = true
        return true
    }

    private func remeasure() {
        advance = ("0" as NSString).size(withAttributes: [.font: face as Any]).width.rounded(.up)
    }

    /// Only the chip itself takes a click: the frame around it must stay
    /// the terminal's, or a corner would stop being part of the pane.
    ///
    /// The point arrives in the *superview's* space — the terminal's,
    /// where the chip sits in a corner a screen away from its own origin
    /// — so it is `frame`, not `bounds`, that says whether it landed.
    /// Asked against `bounds`, no click ever did: the chip drew itself
    /// perfectly and was pure scenery, which is how it was found (by
    /// clicking one on a live pane and watching nothing happen).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressed?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // The dock's plate, in its small size: the same ground, the same
        // hairline, the agent's name in the terminal's ink.
        let ground = TerminalChatView.ground
        ground.withAlphaComponent(DockBox.ground).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        TerminalFieldPanel.word.withAlphaComponent(showing ? 0.28 : 0.16).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        edge.stroke()
        // A dot that is filled while the talk is up: the chip is a switch,
        // and a switch has to say which way it stands.
        let dot = NSRect(x: 7, y: (bounds.height - 4) / 2, width: 4, height: 4)
        TerminalFieldPanel.word.withAlphaComponent(showing ? 0.9 : 0.35).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let size = label
        (name as NSString).draw(
            in: NSRect(
                x: 16, y: (bounds.height - size.height) / 2,
                width: max(10, bounds.width - 22), height: size.height
            ),
            withAttributes: [
                .font: face as Any,
                .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(showing ? 1 : 0.6),
            ]
        )
    }
}
