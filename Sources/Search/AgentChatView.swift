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
    /// One row of the talk. A turn's parts become rows; runs of thought and
    /// tool work between two things that were *said* are folded into one
    /// activity row, the way orbit-pi folds a turn's machinery so a
    /// conversation reads as a conversation.
    struct Item {
        enum Kind {
            case said(ChatLog.Role)
            case thought
            case tool(ChatLog.Tool)
        }

        let kind: Kind
        let text: String
        /// The turn it came from — footers and the rail group by this.
        let turn: Int
        /// Which activity group it belongs to, or -1 when it is a row of its
        /// own (anything that was said).
        let fold: Int
        /// The last part of its turn: where that turn's footer goes.
        let last: Bool

        var height: CGFloat = 0
        var top: CGFloat = 0
        /// False for the tail of a folded group: it takes no room and draws
        /// nothing, but it may still carry the turn's footer.
        var body = true
        /// True for the first row of a folded group: it draws the summary
        /// instead of its own tool row.
        var folded = false
    }

    private var items: [Item] = []
    private var turns: [ChatLog.Turn] = []
    /// Each turn's top in talk points, for the rail.
    private var turnTops: [CGFloat] = []
    /// One line per turn — what the paper was last built from.
    private var laid: [String] = []
    private var measured: CGFloat = 0
    private var total: CGFloat = 0
    private var scroll: CGFloat = 0
    private var following = true
    /// Tool rows whose output a person opened, by item index.
    private var openedTools: Set<Int> = []
    /// Activity groups a person opened, by group number.
    private var openedGroups: Set<Int> = []
    /// An answer's markdown, parsed and measured once per width. A talk of
    /// hundreds of rows is re-laid out on every scroll, and parsing prose
    /// on every frame would be work done for nothing — the words did not
    /// change, only where they are being looked at.
    private var proseCache: [Int: [Prose.Piece]] = [:]
    /// True while the agent is mid-work. A row of its own, below the talk,
    /// saying what it is doing — and the only thing on this paper that
    /// moves without the file changing.
    private(set) var working = false
    /// True when the last measure was made with the working row in place,
    /// so the row appearing or going re-measures the paper.
    private var measuredWork = false
    /// A person asked for something to be put on the pasteboard.
    var copied: ((String) -> Void)?

    private let margin: CGFloat = 18
    private let gutter: CGFloat = 14
    private let air: CGFloat = 6
    private let mark: CGFloat = 2
    /// The rail down the right edge, and the room it claims.
    private static let rail: CGFloat = 12
    /// A turn's footer line.
    private static let footHeight: CGFloat = 16
    /// A folded group's summary row.
    private static let activityRow: CGFloat = 18
    /// The row that says the agent is still working.
    private static let workRow: CGFloat = 22

    override var isFlipped: Bool { false }

    /// Where a row's words are drawn: past the mark, short of the rail.
    private var inner: CGFloat {
        max(80, bounds.width - margin * 2 - gutter - Self.rail)
    }

    /// The talk wears the terminal's own ground and ink: it is the same
    /// terminal seen differently, not the app's chrome on top of it.
    private static var theme: TerminalDraw.Theme { .current(TerminalLook.theme) }

    private var ground: NSColor {
        let theme = Self.theme
        return NSColor(srgbRed: CGFloat(theme.ground.x), green: CGFloat(theme.ground.y),
                       blue: CGFloat(theme.ground.z), alpha: 1)
    }

    private var ink: NSColor { TerminalFieldPanel.word }

    /// Ink at an alpha, so every row is the same ink seen nearer or further.
    private func ink(_ alpha: CGFloat) -> NSColor { ink.withAlphaComponent(alpha) }

    /// The one colour that is not ink: a tool that failed.
    private func bad(_ alpha: CGFloat) -> NSColor { NSColor.systemRed.withAlphaComponent(alpha) }

    private var face: NSFont { TerminalLook.face(size: max(11, TerminalLook.size - 1)) }
    private var footFace: NSFont { TerminalLook.face(size: max(9, TerminalLook.size - 3)) }
    private var railFace: NSFont { TerminalLook.face(size: max(9, TerminalLook.size - 4)) }

    /// The talk's turns, for the composer and for tests.
    var talk: [ChatLog.Turn] { turns }

    func take(_ log: ChatLog) {
        var next: [Item] = []
        var group = 0
        for (index, turn) in log.turns.enumerated() {
            var open = false
            for (place, part) in turn.parts.enumerated() {
                let last = place == turn.parts.count - 1
                switch part {
                case .word(let said):
                    // Words end the run: what comes after them is a new
                    // piece of machinery, not more of the old one.
                    open = false
                    next.append(Item(kind: .said(turn.role), text: said,
                                     turn: index, fold: -1, last: last))
                case .thought(let said):
                    if !open { group += 1; open = true }
                    next.append(Item(kind: .thought, text: said,
                                     turn: index, fold: group, last: last))
                case .tool(let tool):
                    if !open { group += 1; open = true }
                    next.append(Item(kind: .tool(tool), text: tool.name,
                                     turn: index, fold: group, last: last))
                }
            }
        }

        var sigs: [String] = []
        for turn in log.turns {
            var sig = "\(turn.id)|\(turn.at?.timeIntervalSince1970 ?? 0)|\(turn.until?.timeIntervalSince1970 ?? 0)"
            if let use = turn.usage {
                sig += "|\(use.input),\(use.output),\(use.cached)"
            }
            for part in turn.parts {
                switch part {
                case .word(let said): sig += "|w\(said.count)"
                case .thought(let said): sig += "|t\(said.count)"
                case .tool(let tool):
                    sig += "|k\(tool.name)\(tool.summary)\(tool.output.count)\(tool.failed)"
                }
            }
            sigs.append(sig)
        }
        guard sigs != laid else { return }
        laid = sigs
        items = next
        turns = log.turns
        proseCache = [:]
        // A person who opened a tool keeps it open as the talk grows, and
        // the first rows of a talk start open so nothing is hidden on
        // arrival.
        if sigs.count <= 2 {
            openedGroups = Set(next.map(\.fold).filter { $0 >= 0 })
        }
        measure()
        if following { scroll = 0 }
        needsDisplay = true
    }

    // MARK: - measure

    private func measure() {
        let width = inner
        guard width != measured || turnTops.count != turns.count || measuredWork != working else {
            return
        }
        measuredWork = working
        // The width changed, so every answer has to be measured again — the
        // cache is keyed by item, and an item's height is a fact about the
        // width it was measured at.
        proseCache = [:]
        measured = width
        turnTops = Array(repeating: 0, count: turns.count)
        var top: CGFloat = 0
        var seen = -1
        var lastTurn = -1
        for i in items.indices {
            let item = items[i]
            if item.turn != lastTurn {
                if item.turn < turnTops.count { turnTops[item.turn] = top }
                lastTurn = item.turn
            }
            if item.fold >= 0, !openedGroups.contains(item.fold) {
                if item.fold == seen {
                    // The rest of the folded run: no room of its own.
                    items[i].body = false
                    items[i].folded = false
                    let h: CGFloat = item.last ? Self.footHeight : 0
                    items[i].height = h
                    items[i].top = top
                    top += h
                    continue
                }
                seen = item.fold
                items[i].body = true
                items[i].folded = true
                var h = Self.activityRow
                if item.last { h += Self.footHeight }
                items[i].height = h
                items[i].top = top
                top += h + air
            } else {
                seen = -1
                items[i].body = true
                items[i].folded = false
                var h = height(of: item, at: i, width: width)
                if item.last { h += Self.footHeight }
                items[i].height = h
                items[i].top = top
                top += h + air
            }
        }
        total = top + (working ? Self.workRow : 0)
    }

    private func height(of item: Item, at index: Int, width: CGFloat) -> CGFloat {
        switch item.kind {
        case .said(.person):
            return bubble(item.text, width: width).box.height + 2
        case .said(.agent):
            return prose(item, at: index, width: width).reduce(0) { $0 + $1.before + $1.height } + 2
        case .thought:
            let room = max(40, width - 10)
            return prose(item, at: index, width: room).reduce(0) { $0 + $1.before + $1.height } + 2
        case .tool(let tool):
            var h = rowHeight
            if openedTools.contains(index), !tool.output.isEmpty {
                h += 2 + box(tool.output, font: footFace, width: foldRoom(width)).height
            }
            return h
        }
    }

    /// What an answer is made of, parsed and measured at the width it will
    /// be drawn in. Cached: the words change when the agent says more, not
    /// when the view is scrolled.
    private func prose(_ item: Item, at index: Int, width: CGFloat) -> [Prose.Piece] {
        if let had = proseCache[index] { return had }
        let tone: CGFloat
        switch item.kind {
        case .thought: tone = 0.40
        default: tone = 0.88
        }
        let pieces = Prose.pieces(
            Prose.blocks(item.text), width: width,
            style: Prose.Style(face: face, base: face.pointSize, ink: ink, tone: tone)
        )
        proseCache[index] = pieces
        return pieces
    }

    private var rowHeight: CGFloat { 18 }

    private func foldRoom(_ width: CGFloat) -> CGFloat {
        max(40, width - 8)
    }

    // MARK: - draw

    override func draw(_ dirty: NSRect) {
        ground.setFill()
        bounds.fill()

        measure()
        let start = scroll
        let reachable = bounds.height
        guard total > 0 else {
            let words = "This terminal is not running an agent yet."
            let room = box(words, font: face, width: bounds.width - 40)
            words.draw(in: NSRect(x: 20, y: (bounds.height - room.height) / 2,
                                  width: bounds.width - 40, height: room.height),
                       withAttributes: [.font: face, .foregroundColor: ink(0.35)])
            return
        }
        let from = max(0, total - start - reachable)

        for i in items.indices {
            let item = items[i]
            let y = bounds.height - (item.top - from) - item.height
            guard y + item.height > -2, y < bounds.height + 2 else { continue }
            let top = y + item.height
            if item.body {
                let body = item.height - (item.last ? Self.footHeight : 0)
                if item.folded {
                    drawActivity(item.fold, top: top, width: inner)
                } else {
                    draw(item, at: i, top: top, body: body, width: inner)
                }
            }
            if item.last, item.turn < turns.count {
                drawFoot(turns[item.turn], at: y, width: inner)
            }
        }

        // The working row is not part of the talk — it is what the talk has
        // not got yet — so it is drawn after the last turn rather than
        // being one of the items.
        if working {
            let top = bounds.height - (total - Self.workRow - from)
            if top > -Self.workRow, top - Self.workRow < bounds.height {
                drawWorking(at: top, width: inner)
            }
        }

        drawRail(from: from, reachable: reachable)
    }

    /// What the agent is doing, in the fewest words that are true: the tool
    /// it last reached for, or nothing more than that it is going.
    var workingWords: String {
        guard let last = items.last else { return "Working" }
        switch last.kind {
        case .tool(let tool):
            let said = tool.name + (tool.summary.isEmpty ? "" : "  \(tool.summary)")
            return said.trimmed
        case .thought: return "Thinking"
        case .said: return "Working"
        }
    }

    /// The row that says the agent is still going. Its words carry a band
    /// of brighter ink travelling across them; the band is paid for by the
    /// agent's own work — when the work stops, the row and its motion both
    /// go, which is why this paper still has no clock of its own.
    private func drawWorking(at top: CGFloat, width: CGFloat) {
        let y = top - Self.workRow
        let words = workingWords
        let room = NSRect(x: margin + gutter + 12, y: y + 3,
                          width: max(20, width - 12), height: Self.workRow - 6)
        // A dot that is filled while working, so the row still says what it
        // is on a frame where the band happens to be off the words.
        ink(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: margin + gutter + 1, y: y + Self.workRow / 2 - 2.5,
                                    width: 5, height: 5)).fill()
        words.draw(in: room, withAttributes: [.font: face, .foregroundColor: ink(0.32)])

        // The band. Its place comes from the wall clock rather than from a
        // stored start, so it is already in motion the first time it is
        // drawn; nothing here keeps time between frames.
        let phase = CGFloat(CACurrentMediaTime().truncatingRemainder(dividingBy: 1.7) / 1.7)
        let span = room.width
        let band = max(70, span * 0.32)
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: room.minX - band + phase * (span + band * 2), y: room.minY,
               width: band, height: room.height).clip()
        words.draw(in: room, withAttributes: [.font: face, .foregroundColor: ink(0.95)])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ item: Item, at index: Int, top: CGFloat, body: CGFloat, width: CGFloat) {
        let x = margin + gutter
        switch item.kind {
        case .said(.person):
            let shape = bubble(item.text, width: width)
            let box = NSRect(x: shape.box.minX, y: top - shape.box.height,
                             width: shape.box.width, height: shape.box.height)
            let path = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
            ink(0.07).setFill()
            path.fill()
            ink(0.14).setStroke()
            path.lineWidth = 1
            path.stroke()
            item.text.draw(in: NSRect(x: shape.text.minX, y: top - shape.box.height + shape.text.minY,
                                      width: shape.text.width, height: shape.text.height),
                           withAttributes: [.font: face, .foregroundColor: ink(0.86)])

        case .said(.agent):
            drawProse(prose(item, at: index, width: width), at: top, width: width, shift: 0)

        case .thought:
            // A thought is set back behind a hairline so it reads as the
            // agent's own aside, never as something it said to you.
            let room = max(40, width - 10)
            ink(0.13).setFill()
            NSRect(x: x, y: top - body + 1, width: mark, height: max(0, body - 3)).fill()
            drawProse(prose(item, at: index, width: room), at: top, width: room, shift: 10)

        case .tool(let tool):
            let row = NSRect(x: x, y: top - rowHeight, width: width, height: rowHeight)
            let open = openedTools.contains(index)
            let tone: CGFloat = tool.failed ? 0.75 : 0.50
            let head = (open ? "▾ " : "▸ ") + tool.name
                + (tool.summary.isEmpty ? "" : "  \(tool.summary)")
            head.draw(in: row, withAttributes: [
                .font: face,
                .foregroundColor: tool.failed ? bad(tone) : ink(tone),
            ])
            if open, !tool.output.isEmpty {
                let room = foldRoom(width)
                let h = box(tool.output, font: footFace, width: room).height
                let where_ = NSRect(x: x + 8, y: top - rowHeight - 2 - h, width: room, height: h)
                // A diff says which lines are there now and which are gone,
                // and it is the one kind of output where colour carries
                // something a person needs rather than something they like.
                if let painted = Prose.diff(tool.output, face: footFace, ink: ink) {
                    painted.draw(with: where_, options: [.usesLineFragmentOrigin, .usesFontLeading])
                } else {
                    tool.output.draw(in: where_, withAttributes: [
                        .font: footFace, .foregroundColor: ink(tool.failed ? 0.62 : 0.36),
                    ])
                }
            }
        }
    }

    /// A run of prose: each block drawn as what it is. The words carry
    /// their own marks (bold, code, links); the shape carries the rest — a
    /// code block's ground, a quote's bar, a rule's line.
    private func drawProse(_ pieces: [Prose.Piece], at top: CGFloat, width: CGFloat, shift: CGFloat) {
        var y = top
        for piece in pieces {
            y -= piece.before
            let h = piece.height
            let left = margin + gutter + shift
            let room = max(20, width - piece.inset)
            if piece.band {
                ink(0.05).setFill()
                NSRect(x: left, y: y - h, width: width, height: h).fill()
            }
            if piece.bar {
                ink(0.14).setFill()
                NSRect(x: left, y: y - h + 2, width: mark, height: max(0, h - 4)).fill()
            }
            if case .rule = piece.block {
                ink(0.16).setFill()
                NSRect(x: left, y: y - 1, width: width, height: 1).fill()
                y -= h
                continue
            }
            // A band's padding is inside its height, so its words start
            // below the top edge; everything else starts at the top.
            let textTop = piece.band ? y - 4 : y
            piece.text.draw(with: NSRect(x: left + piece.inset, y: textTop - h,
                                        width: room, height: h),
                            options: [.usesLineFragmentOrigin, .usesFontLeading])
            if case .code(let language, _) = piece.block, let language, !language.isEmpty {
                let label = NSAttributedString(string: language, attributes: [
                    .font: footFace, .foregroundColor: ink(0.30),
                ])
                let size = label.size()
                label.draw(at: NSPoint(x: left + width - size.width - 8, y: y - 3 - size.height))
            }
            y -= h
        }
    }

    /// A folded run of thought and tool work, said in a sentence.
    private func drawActivity(_ fold: Int, top: CGFloat, width: CGFloat) {
        let open = openedGroups.contains(fold)
        let words = (open ? "▾ " : "▸ ") + activityWords(fold)
        let row = NSRect(x: margin + gutter, y: top - Self.activityRow, width: width, height: Self.activityRow)
        ink(0.10).setFill()
        NSRect(x: margin + gutter, y: top - Self.activityRow + 1, width: mark,
               height: max(0, Self.activityRow - 3)).fill()
        words.draw(in: row, withAttributes: [.font: face, .foregroundColor: ink(0.45)])
    }

    private func activityWords(_ fold: Int) -> String {
        var counts: [Kin: Int] = [:]
        for item in items where item.fold == fold {
            switch item.kind {
            case .thought: counts[.thought, default: 0] += 1
            case .said: break
            case .tool(let tool): counts[Self.kin(tool.name), default: 0] += 1
            }
        }
        var parts: [String] = []
        for kin in Kin.allCases {
            guard let n = counts[kin], n > 0 else { continue }
            parts.append(kin.words(n))
        }
        return parts.isEmpty ? "Worked" : parts.joined(separator: " · ")
    }

    /// What a tool call was, in the few kinds a person would name. A
    /// search is not a read: "Read a file" for a grep would be a lie.
    private enum Kin: CaseIterable {
        case command, read, search, page, edit, tool, thought

        func words(_ n: Int) -> String {
            switch self {
            case .command: return n == 1 ? "Ran a command" : "Ran \(n) commands"
            case .read: return n == 1 ? "Read a file" : "Read \(n) files"
            case .search: return n == 1 ? "Searched" : "Searched \(n) times"
            case .page: return n == 1 ? "Fetched a page" : "Fetched \(n) pages"
            case .edit: return n == 1 ? "Edited a file" : "Edited \(n) files"
            case .tool: return n == 1 ? "Used a tool" : "Used \(n) tools"
            case .thought: return n == 1 ? "Thought once" : "Thought \(n) times"
            }
        }
    }

    private static func kin(_ name: String) -> Kin {
        let low = name.lowercased()
        if low.contains("bash") || low.contains("shell") || low.contains("exec") || low.contains("terminal") {
            return .command
        }
        if low.contains("grep") || low.contains("glob") || low.contains("search")
            || low.contains("find") || low.contains("query") || low.contains("list") {
            return .search
        }
        if low.contains("fetch") || low.contains("web") || low.contains("http") || low.contains("curl") {
            return .page
        }
        if low.contains("read") || low.contains("view") || low.contains("open") {
            return .read
        }
        if low.contains("edit") || low.contains("write") || low.contains("patch") || low.contains("apply") {
            return .edit
        }
        return .tool
    }

    /// What a turn's footer says: when it ran, how long it took, what it
    /// cost. Built here, drawn below, and asserted on directly — the one
    /// part of the talk that is about numbers rather than words.
    static func foot(_ turn: ChatLog.Turn) -> [String] {
        var bits: [String] = []
        if let at = turn.at { bits.append(clock.string(from: at)) }
        if let span = span(of: turn) { bits.append(span) }
        if let use = turn.usage, use.worth {
            bits.append("\(tokens(use.input)) in · \(tokens(use.output)) out")
            if use.cached > 0 { bits.append("\(tokens(use.cached)) cached") }
        }
        return bits
    }

    private func drawFoot(_ turn: ChatLog.Turn, at y: CGFloat, width: CGFloat) {
        let bits = Self.foot(turn)
        guard !bits.isEmpty else { return }
        let words = bits.joined(separator: "   ")
        words.draw(in: NSRect(x: margin + gutter, y: y + 1, width: width, height: Self.footHeight - 2),
                   withAttributes: [.font: footFace, .foregroundColor: ink(0.28)])
    }

    /// A turn's own span — what the agent took, not the gap until you next
    /// spoke. Under a second is not worth a number.
    static func span(of turn: ChatLog.Turn) -> String? {
        guard let from = turn.at, let to = turn.until ?? turn.at as Date? else { return nil }
        let seconds = to.timeIntervalSince(from)
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm %02ds", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - the rail

    private var railRect: NSRect {
        NSRect(x: bounds.width - 10, y: 8, width: 3, height: max(1, bounds.height - 16))
    }

    /// A tick per turn down the right edge — the whole talk at a glance, and
    /// the only way back to something that scrolled away.
    private func drawRail(from: CGFloat, reachable: CGFloat) {
        guard total > 0, !turnTops.isEmpty else { return }
        let rail = railRect
        // A talk shorter than the view is drawn against the view, not
        // against itself: its ticks must sit where its words do, and the
        // band must say "all of this is in front of you".
        let doc = max(total, reachable)

        // Where you are now. Talk coordinates run oldest-first from the
        // top, so the older edge of the window is the higher y.
        let older = max(0, total - scroll - reachable)
        let newer = min(total, older + reachable)
        let yOld = rail.minY + (1 - older / doc) * rail.height
        let yNew = rail.minY + (1 - newer / doc) * rail.height
        ink(0.07).setFill()
        NSRect(x: rail.minX - 1, y: yNew, width: rail.width + 2,
               height: max(2, yOld - yNew)).fill()

        for (i, top) in turnTops.enumerated() {
            let y = rail.minY + (1 - top / doc) * rail.height
            let person = i < turns.count && turns[i].role == .person
            let broke = i < turns.count && (turns[i].parts.contains {
                if case .tool(let tool) = $0 { return tool.failed }
                return false
            })
            let h: CGFloat = person ? 4 : 2
            let color = broke ? bad(0.70) : ink(person ? 0.55 : 0.22)
            color.setFill()
            NSRect(x: rail.minX, y: max(rail.minY, y - h / 2), width: rail.width, height: h).fill()
        }
    }

    /// Jump the talk so a turn sits at the top of what you can see.
    private func jump(to turn: Int) {
        measure()
        guard turn < turnTops.count else { return }
        let room = max(0, total - bounds.height)
        scroll = min(room, max(0, total - bounds.height - turnTops[turn]))
        following = scroll <= 0.5
        needsDisplay = true
    }

    /// Which turn a point on the rail is nearest.
    private func turn(near point: NSPoint) -> Int? {
        let rail = railRect
        guard !turnTops.isEmpty, total > 0 else { return nil }
        let doc = max(total, bounds.height)
        let want = doc * (1 - (point.y - rail.minY) / max(1, rail.height))
        var best: Int?
        var gap = CGFloat.greatestFiniteMagnitude
        for (i, top) in turnTops.enumerated() where abs(top - want) < gap {
            gap = abs(top - want)
            best = i
        }
        return best
    }

    // MARK: - measure

    private func box(_ words: String, font: NSFont, width: CGFloat) -> NSRect {
        guard !words.isEmpty else { return NSRect(x: 0, y: 0, width: 0, height: 0) }
        return (words as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
    }

    private struct Bubble {
        var box: NSRect
        var text: NSRect
    }

    /// A person's words sit in a box on the right, sized to the words but
    /// never wider than four fifths of the column.
    private func bubble(_ words: String, width: CGFloat) -> Bubble {
        let padH: CGFloat = 11
        let padV: CGFloat = 7
        let most = min(width * 0.82, 460)
        let natural = box(words, font: face, width: most - padH * 2).width
        let wide = min(most, max(56, natural + padH * 2))
        let room = max(20, wide - padH * 2)
        let tall = box(words, font: face, width: room).height
        let x = margin + gutter + width - wide
        return Bubble(
            box: NSRect(x: x, y: 0, width: wide, height: tall + padV * 2),
            text: NSRect(x: x + padH, y: padV, width: room, height: tall)
        )
    }

    // MARK: - the clock and the numbers

    private static let clock: DateFormatter = {
        let form = DateFormatter()
        form.dateFormat = "HH:mm"
        return form
    }()

    /// Tokens in the units people use — and the decimal is dropped once
    /// there are three digits to the left of it, because "195.0k" is a
    /// number pretending to be precise.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return said(Double(count) / 1_000_000) + "M" }
        if count >= 1_000 { return said(Double(count) / 1_000) + "k" }
        return "\(count)"
    }

    private static func said(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    // MARK: - the talk's shape

    /// Every row the talk draws, in order — its structure without its
    /// pixels. A folded run of machinery is one row, and the rest of that
    /// run is not listed at all, so this is exactly what a person sees.
    var shape: [(kind: String, words: String, rect: NSRect)] {
        measure()
        let from = max(0, total - scroll - bounds.height)
        var out: [(kind: String, words: String, rect: NSRect)] = []
        for item in items where item.body {
            let rect = NSRect(x: margin, y: bounds.height - (item.top - from) - item.height,
                              width: bounds.width, height: item.height)
            if item.folded {
                out.append(("activity", activityWords(item.fold), rect))
                continue
            }
            switch item.kind {
            case .said(let role): out.append((role == .person ? "you" : "agent", item.text, rect))
            case .thought: out.append(("thought", item.text, rect))
            case .tool(let tool):
                out.append(("tool", tool.name + (tool.summary.isEmpty ? "" : " \(tool.summary)"), rect))
            }
        }
        return out
    }

    /// How much paper the talk takes — the document's own height, not the
    /// view's. A conversation of the same words written flat is shorter.
    var written: CGFloat {
        measure()
        return total
    }

    // MARK: - following

    /// Put the newest words back under your eyes.
    func follow() {
        scroll = 0
        following = true
        needsDisplay = true
    }

    /// The pane says the agent is working, or that it has stopped. The
    /// paper redraws either way: the row appearing and the row going are
    /// both changes a person is meant to see.
    func beat(working: Bool) {
        if self.working != working {
            self.working = working
            measure()
        }
        needsDisplay = true
    }

    func refont() {
        measured = 0
        proseCache = [:]
        measure()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let room = max(0, total - bounds.height)
        scroll = min(room, max(0, scroll + event.scrollingDeltaY))
        following = scroll <= 0.5
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        // The rail first: it is the one target that must never be missed.
        if at.x >= railRect.minX - 4, let turn = turn(near: at) {
            jump(to: turn)
            return
        }
        measure()
        let from = max(0, total - scroll - bounds.height)
        // Talk coordinates run from the oldest at the top; the view is
        // unflipped, so a point's talk coordinate is measured down from
        // the top of the view.
        let spot = from + (bounds.height - at.y)
        // Option-click puts the thing under the pointer on the pasteboard —
        // the whole of what the agent said, not the line that happens to be
        // under the pointer, because a line of a wrapped paragraph is not
        // something anybody wants alone.
        if event.modifierFlags.contains(.option) {
            if let item = item(at: spot) {
                copied?(item.text)
            }
            return
        }
        for i in items.indices {
            let item = items[i]
            guard spot >= item.top, spot <= item.top + item.height else { continue }
            if item.folded {
                if openedGroups.contains(item.fold) {
                    openedGroups.remove(item.fold)
                } else {
                    openedGroups.insert(item.fold)
                }
                measured = 0
                measure()
                needsDisplay = true
                return
            }
            if case .tool = item.kind, item.fold < 0 || openedGroups.contains(item.fold) {
                if openedTools.contains(i) { openedTools.remove(i) } else { openedTools.insert(i) }
                measured = 0
                measure()
                needsDisplay = true
                return
            }
        }
    }

    /// The row a talk coordinate lands in, if it lands in one at all.
    func item(at spot: CGFloat) -> Item? {
        items.first { spot >= $0.top && spot <= $0.top + $0.height }
    }

    /// True while the newest words are under your eyes.
    var isFollowing: Bool { following }
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
        // The window of the model the agent is on: the catalog's word for
        // it, or the number its own name carries. A row that says nothing
        // leaves the ring off rather than inventing a denominator.
        let row = rows.first { !$0.head && $0.value == current }
        contextWindow = row?.window ?? AgentModels.window(of: current) ?? 0
        needsDisplay = true
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

    /// What the agent has spent of its window, and how big the window is.
    /// Both come from the agent's own records: the count from the
    /// transcript, the window from its catalog or the model's own name.
    /// Zero means nothing knows, and then there is no ring to draw.
    private(set) var contextUsed = 0
    private(set) var contextWindow = 0
    /// True while the agent is mid-work — the dot in the footer.
    private(set) var working = false

    /// What the pane learned on its last look: whether the agent is
    /// working, what it has spent, and what it has to spend. Redraws only
    /// when something of it changed, so a quiet agent costs no frames.
    func beat(working: Bool, used: Int) {
        let changed = self.working != working || contextUsed != used
        self.working = working
        contextUsed = used
        if changed { needsDisplay = true }
    }

    /// The ring's share of the footer, and where it sits.
    private static let ring: CGFloat = 13
    private var ringBox: NSRect {
        let box = self.box
        return NSRect(x: box.maxX - 10 - Self.ring, y: box.minY + (Self.footHeight - Self.ring) / 2,
                      width: Self.ring, height: Self.ring)
    }

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

        // The context ring, at the footer's right: how much of the window
        // this run has spent. Drawn only when both numbers are known — a
        // ring with no denominator would be a decoration pretending to be
        // a measurement.
        var right = box.maxX - 10
        if contextWindow > 0, contextUsed > 0 {
            drawRing()
            right = ringBox.minX - 6
        }
        // The working dot, left of everything else: the footer is the one
        // part of the composer that is always on screen, so the answer to
        // "is it still going?" belongs here and not only under the talk.
        if working {
            right -= 9
            TerminalFieldPanel.word.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: NSRect(x: right, y: box.minY + Self.footHeight / 2 - 2.5,
                                        width: 5, height: 5)).fill()
        }

        // What the keys do, beside it: a chat whose only affordances are a
        // chip and a line would leave return and escape for a person to
        // guess.
        let keys = "⏎ send   ⇧⏎ newline   esc close"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: TerminalFieldPanel.word.withAlphaComponent(0.26),
        ]
        let said = (keys as NSString).size(withAttributes: attrs)
        let keyX = max(box.minX + 10, right - said.width)
        (keys as NSString).draw(
            at: NSPoint(x: keyX, y: box.minY + (Self.footHeight - said.height) / 2),
            withAttributes: attrs
        )
    }

    /// How full the window is: an arc, the count, and the percentage. The
    /// arc alone would make a person read a length to know how bad it is,
    /// so the colour carries it too — the terminal's own ink until the
    /// window is nearly full, then a warning, then an error.
    private func drawRing() {
        let room = ringBox
        let centre = NSPoint(x: room.midX, y: room.midY)
        let radius = Self.ring / 2 - 1.5
        TerminalFieldPanel.word.withAlphaComponent(0.16).setStroke()
        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1.5
        track.stroke()

        if let fraction = ContextMeter.fraction(used: contextUsed, window: contextWindow) {
            let colour = ContextMeter.tint(fraction, ink: TerminalFieldPanel.word)
            colour.setStroke()
            let arc = NSBezierPath()
            // From the top, clockwise, the way a clock reads: a person
            // looking at a ring already knows where "more" goes.
            arc.appendArc(withCenter: centre, radius: radius,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 1.5
            arc.stroke()
            // The percentage, in the middle: the ring says roughly, the
            // number says exactly, and both fit in a footer this size.
            let words = ContextMeter.percent(used: contextUsed, window: contextWindow)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .medium),
                .foregroundColor: colour,
            ]
            let size = (words as NSString).size(withAttributes: attrs)
            (words as NSString).draw(
                at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2),
                withAttributes: attrs
            )
        }
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

// MARK: - the switch

/// The switch in the pane's corner: Terminal on one side, Chat on the
/// other, the one in use lit. Only present while an agent that can be read
/// as a conversation is in the terminal — a switch offering a view of
/// nothing would be a switch to nowhere.
///
/// Two named halves rather than one word and a dot: the chip used to say
/// only which agent was in here, and a person had to press it to find out
/// what it did. A switch that names both places says what it is before it
/// is pressed.
@MainActor
final class TerminalChatSwitch: NSView {
    /// The two sides, in the order they are drawn.
    enum Side: Int {
        case screen, talk

        var title: String {
            switch self {
            case .screen: return "Terminal"
            case .talk: return "Chat"
            }
        }
    }

    private(set) var agent = ""
    private(set) var showing = false

    /// Which side was pressed: the talk's, or the screen's. A press on the
    /// side already in use is still said, so the pane can bring its
    /// keyboard back to where the hand expects it.
    var asked: ((Bool) -> Void)?

    private var face = NSFont.systemFont(ofSize: 10, weight: .medium)
    private var widths: (screen: CGFloat, talk: CGFloat) = (0, 0)

    static let height: CGFloat = 20
    static let inset: CGFloat = 10
    private static let pad: CGFloat = 7
    private static let gap: CGFloat = 3

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        remeasure()
    }

    required init?(coder: NSCoder) { nil }

    /// The size it wants: both halves, their pads, and the room between
    /// them.
    var wanted: NSSize {
        NSSize(
            width: ceil(widths.screen + widths.talk) + Self.pad * 4 + Self.gap,
            height: Self.height
        )
    }

    /// Says which agent is in here — kept for the corner's own record —
    /// and which side is lit. Returns whether anything changed, so a
    /// caller only redraws when it did.
    func say(_ agent: String, showing: Bool) -> Bool {
        guard self.agent != agent || self.showing != showing else { return false }
        self.agent = agent
        self.showing = showing
        remeasure()
        needsDisplay = true
        return true
    }

    private func remeasure() {
        func width(_ words: String) -> CGFloat {
            ceil((words as NSString).size(withAttributes: [.font: face as Any]).width)
        }
        widths = (width(Side.screen.title), width(Side.talk.title))
    }

    /// Where each side sits, in `bounds` coordinates.
    private func box(_ side: Side) -> NSRect {
        let screen = NSRect(
            x: 1, y: 1, width: widths.screen + Self.pad * 2, height: bounds.height - 2
        )
        let talk = NSRect(
            x: screen.maxX + Self.gap, y: 1,
            width: widths.talk + Self.pad * 2, height: bounds.height - 2
        )
        return side == .screen ? screen : talk
    }

    /// Only the switch itself takes a click: the frame around it must stay
    /// the terminal's, or a corner would stop being part of the pane.
    ///
    /// The point arrives in the *superview's* space — the terminal's,
    /// where the switch sits in a corner a screen away from its own origin
    /// — so it is `frame`, not `bounds`, that says whether it landed.
    /// Asked against `bounds`, no click ever did: the switch drew itself
    /// perfectly and was pure scenery, which is how it was found (by
    /// clicking one on a live pane and watching nothing happen).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        // The left half is the screen and the right half is the talk; a
        // press in the gap between them belongs to whichever half it is
        // nearer, so there is no dead stripe in the middle of a switch.
        asked?(at.x >= box(.talk).minX - Self.gap / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The dock's plate, in its small size: the same ground, the same
        // hairline, the terminal's ink.
        let ground = TerminalChatView.ground
        ground.withAlphaComponent(DockBox.ground).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        TerminalFieldPanel.word.withAlphaComponent(0.16).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        edge.stroke()

        // The lit half gets a raised ground of its own: a switch has to say
        // which way it stands before a hand reaches for it.
        let lit: Side = showing ? .talk : .screen
        let raised = box(lit)
        TerminalFieldPanel.word.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: raised, xRadius: 4, yRadius: 4).fill()
        // A hairline round the raised half: against a dark ground the
        // raised fill alone is a shade, and a switch has to be read at a
        // glance from across the pane.
        TerminalFieldPanel.word.withAlphaComponent(0.10).setStroke()
        let rim = NSBezierPath(roundedRect: raised.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        rim.lineWidth = 1
        rim.stroke()

        for side in [Side.screen, .talk] {
            let ink = side == lit
                ? TerminalFieldPanel.word.withAlphaComponent(0.98)
                : TerminalFieldPanel.word.withAlphaComponent(0.45)
            let attrs: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: ink]
            let words = side.title as NSString
            let size = words.size(withAttributes: attrs)
            let box = box(side)
            words.draw(
                at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                withAttributes: attrs
            )
        }
    }
}
