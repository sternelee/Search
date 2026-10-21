import Foundation

// The paper of a terminal: cells, a cursor, a stretch of the screen the
// program calls its scroll region, and the scrollback the lines roll into
// when they leave the top. Everything a program writes becomes this — rows
// of characters and the ink they wear — and everything that draws the
// terminal reads this. The parser feeds it; the Metal view (see
// TerminalDraw) walks it. Nothing here knows about either one.
//
// Rows are named two ways. A screen row is its place on the screen now, 0
// at the top. A *place* is where a row sits in the scrollback as a whole,
// counting every row ever pushed off the top: `place(y)` never goes
// backwards, so a command's block (see `Block`) keeps its identity while
// the screen scrolls away under it.

/// What a character wears. `plain` is whatever the light of the window
/// says; the rest are named by the shell.
enum Paint: Equatable {
    case plain
    case ansi(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// The ink of one character: two paints and the few ways a cell can differ
/// from the words alone.
struct Ink: Equatable {
    var foreground: Paint = .plain
    var background: Paint = .plain
    var bold = false
    var faint = false
    var italic = false
    var underline = false
    /// SGR 21 — double — and SGR 4:3, curly, land here as styles; 4:4 is
    /// dotted, 4:5 dashed, 4:1 straight. Styles other than straight and
    /// curly are not told apart on screen — every terminal draws them a
    /// little differently, so the two that carry the style's weight (the
    /// line, and the doubled one) are the ones drawn; the rest answer the
    /// pen honestly, so a program that asks what it set gets back what it
    /// set, which is a fuller truth than the screen's.
    var curl = false
    var strike = false
    var blink = false
    var inverse = false
    var hidden = false
    /// SGR 58;5;n / 58;2;r;g;b: the line's own colour, which without one
    /// is the ink of the words it runs under. Also the colour of a
    /// strike-through, which no other terminal of the kind draws at all.
    var line: Paint = .plain

    static let plain = Ink()
}

/// One square of the screen: what it says, and what it is said with. A wide
/// character takes the square after it too; that one carries no character
/// of its own.
struct Cell: Equatable {
    var char: Character = " "
    var wide = false
    var ink: Ink = .plain
    /// The link this square belongs to, as an index into the screen's own
    /// table, or zero for none — which is what almost every square there
    /// has ever been. A hyperlink is the one thing here that does not
    /// belong in the square: it is a string, and the same string is laid
    /// over every square of the words it covers. So the string is kept
    /// once and the square carries its number, and a screen with no
    /// hyperlinks on it pays two bytes a square for the privilege of not
    /// knowing about them.
    var link: UInt16 = 0

    init(char: Character = " ", wide: Bool = false, ink: Ink = .plain, link: UInt16 = 0) {
        self.char = char
        self.wide = wide
        self.ink = ink
        self.link = link
    }
}

/// One line of the screen, as wide as the screen is.
struct Row: Equatable {
    var cells: [Cell]

    init(width: Int) {
        cells = Array(repeating: Cell(), count: max(1, width))
    }

    /// What the line says, trimmed of its padding at the end — the spaces
    /// a line starts with are the line's, not padding; a prompt's dent
    /// matters.
    var text: String {
        let said = String(cells.map(\.char))
        return String(said.reversed().drop { $0 == " " }.reversed())
    }
}

/// A command the shell ran, bounded by the marks it prints around itself
/// (OSC 133; see TerminalParse). Rows are by their place, so a block that
/// has rolled into the scrollback is still one piece.
struct Block: Equatable {
    enum State: Equatable { case prompt, running, done }
    var first: Int
    var last: Int?
    var state: State = .prompt
    var began: Date?
    var ended: Date?
    var exit: Int32?
}

/// Which mouse the program asked to hear, if any. The names are what the
/// modes do: click is press and release, drag adds motion with a button
/// down, motion adds motion without one.
enum MouseMode: Equatable {
    case off, click, drag, motion

    /// The mode number that asks for this, zero for the mouse that was
    /// never asked for. The same number is both the one a program sets and
    /// the one DECRQM is answered with, so it is written here once rather
    /// than in each of the two switches that read it.
    var mode: Int {
        switch self {
        case .click: return 1000
        case .drag: return 1002
        case .motion: return 1003
        case .off: return 0
        }
    }

    init?(mode: Int) {
        switch mode {
        case 1000: self = .click
        case 1002: self = .drag
        case 1003: self = .motion
        default: return nil
        }
    }
}

/// The screen's modes as one small word: what a frame has to know to draw
/// it, and what the keyboard and the hand have to know to talk to it.
/// Carried with the damage rather than read off the screen, so a keystroke
/// or a click never reaches into a screen the lane may be writing — the
/// reason a program that only sets a mode, and draws nothing, still gets
/// its frame (see Damage.moved).
struct Modes: Equatable {
    var mouse = MouseMode.off
    var mouseFormat = MouseReport.Format.legacy // 1006, 1015, 1016: how the pointer is written
    var applicationCursor = false // DECCKM: the arrows speak SS3, not CSI
    var applicationKeypad = false // DECKPAM
    var focus = false             // 1004: the program wants to hear the keyboard come and go
    var sync = false              // 2026: the program is holding the screen while it composes
    var visible = true            // DECTCEM: whether the caret is there at all
    /// DECSCNM (DECSET ?5): the whole screen is reversed. Part of the word
    /// and not of the cells: it turns over what every square says without
    /// touching any of them — the mark of a thing that belongs in a frame,
    /// not in a record, and the reason the word carries it here.
    var reversed = false
}

/// What feeding the screen changed, for whoever draws it: the rows by
/// their place, whether anything scrolled, and whether the whole thing was
/// turned over — scrollback dropped, the alternate screen swapped, or the
/// grid resized — which makes positions held before it stale. Taken, not
/// watched: whoever draws drains it (see `take`).
struct Damage: Equatable {
    var rows: Set<Int> = []
    var scrolled = false
    var overturned = false
    var blocks = false
    /// A change that is not in the cells: the caret moved, or a mode the
    /// frame or the keyboard reads was set. A frame is owed for it — the
    /// caret is drawn where it now is, the arrows take the form the
    /// program just asked for — but not one cell has to be said again,
    /// which is what makes it worth naming apart from `rows`.
    var moved = false

    var empty: Bool { rows.isEmpty && !scrolled && !overturned && !blocks && !moved }

    /// Adds another report to this one: what a view owes a frame across a
    /// burst of readings. The fields are listed once, here, rather than at
    /// each place that accumulates — a field added to `Damage` and not to
    /// this merge would be damage nobody ever draws.
    mutating func merge(_ other: Damage) {
        rows.formUnion(other.rows)
        scrolled = scrolled || other.scrolled
        overturned = overturned || other.overturned
        blocks = blocks || other.blocks
        moved = moved || other.moved
    }

    static let everything = Damage(rows: [], scrolled: true, overturned: true, blocks: true, moved: true)
}

final class Screen {
    /// The screen proper. Row 0 at the top.
    private(set) var rows: [Row]
    /// Rows that have left the top, oldest first, never more than
    /// `backLimit` of them.
    private(set) var back: [Row] = []
    /// The place of `back.first` — how many rows have left the top since
    /// the beginning, so places never repeat or go backwards.
    private(set) var backBase = 0
    /// The scrollback's whole limit, in rows. A tenth of a million is a
    /// few hundred megabytes of text at worst and nothing at best; enough
    /// to grep a build's log by eye after it has gone by.
    var backLimit = 100_000

    private(set) var width: Int
    private(set) var height: Int

    // The cursor. `x` is the column, `y` the row, both from zero, in the
    // scroll region when origin mode is on.
    private(set) var x = 0
    private(set) var y = 0
    /// Set when a character was put in the last column: the cursor waits
    //  there, and the *next* character is what wraps (DECAWM).
    var pendingWrap = false

    /// The scroll region, top and bottom, both inclusive, both by row.
    private(set) var top = 0
    private(set) var bottom: Int

    /// The pen characters are written with (SGR).
    var ink: Ink = .plain

    /// The hyperlink characters are written with (OSC 8), as an index into
    /// `links`, or zero for none. Like the ink it is a pen setting: it
    /// lasts until the program changes it, so a link laid over several
    /// writes covers all of them.
    private var linkNow: UInt16 = 0

    /// Every hyperlink this screen has seen, interned: the same address
    /// written a thousand times over a thousand rows is one string here
    /// and a thousand copies of one small number in the squares. Index
    /// zero is the "no link" the squares start at, so the table is read
    /// from one — `links[cell.link - 1]`.
    ///
    /// Nothing takes an entry away again: a square in the scrollback may
    /// still be pointing at it, and there is no count of who else is. The
    /// table is capped instead — past it, a new address is dropped rather
    /// than kept, which costs a link nobody can click and cannot grow a
    /// session's memory without end.
    private(set) var links: [String] = []

    /// Where an address already in `links` sits, so that writing the same
    /// one again is a lookup rather than a walk of the table. `ls
    /// --hyperlink` writes an address per file, and a long listing would
    /// otherwise cost a scan of every address before it, for every file —
    /// on the queue that reads the program's output.
    private var linkAt: [String: UInt16] = [:]

    /// The most addresses a screen keeps. `ls --hyperlink` writes one per
    /// file, so this is a directory listing's worth of them and then some.
    private static let linkLimit = 16_384

    /// OSC 8: everything written from here on is part of this address, or
    /// of no address at all when it is nil or empty — which is how a
    /// program ends a link.
    func link(_ target: String?) {
        guard let target, !target.isEmpty else {
            linkNow = 0
            return
        }
        if let at = linkAt[target] {
            linkNow = at
            return
        }
        guard links.count < Screen.linkLimit else {
            linkNow = 0
            return
        }
        links.append(target)
        linkNow = UInt16(links.count)
        linkAt[target] = linkNow
    }

    /// The address a square belongs to, if it belongs to one.
    func link(of square: Cell) -> String? {
        let at = Int(square.link) - 1
        return at >= 0 && at < links.count ? links[at] : nil
    }

    /// A square in the pen's own terms: the character, the ink and the
    /// link in force. The one place a cell is made, so that a pen setting
    /// added later cannot be forgotten in one of the erasures.
    private func square(_ char: Character, wide: Bool = false) -> Cell {
        Cell(char: char, wide: wide, ink: ink, link: linkNow)
    }

    // The modes a program sets, each the terminal's own name for it. The
    // ones a frame, the keyboard or the hand acts on say so when they
    // change: a program that only sets a mode draws nothing, and would
    // otherwise get no frame in which to hear that it had.
    var wraparound = true         // DECAWM, on by default
    var origin = false            // DECOM
    var visible = true {          // DECTCEM
        didSet { if visible != oldValue { damage.moved = true } }
    }
    var reverseVideo = false {    // DECSCNM
        didSet { if reverseVideo != oldValue { damage.moved = true } }
    }
    var insert = false            // IRM
    var applicationCursor = false {  // DECCKM
        didSet { if applicationCursor != oldValue { damage.moved = true } }
    }
    var applicationKeypad = false {  // DECKPAM
        didSet { if applicationKeypad != oldValue { damage.moved = true } }
    }
    var mouse = MouseMode.off {
        didSet { if mouse != oldValue { damage.moved = true } }
    }
    /// How the pointer is written when it is reported: the old byte
    /// encoding, SGR, urxvt's, or SGR counting pixels (1006, 1015, 1016).
    /// One at a time, because the modes replace each other — a program
    /// that sets 1016 after 1006 wants pixels, not both.
    var mouseFormat = MouseReport.Format.legacy {
        didSet { if mouseFormat != oldValue { damage.moved = true } }
    }
    var bracketedPaste = false {  // 2004
        didSet { if bracketedPaste != oldValue { damage.moved = true } }
    }
    var focusReporting = false {  // 1004
        didSet { if focusReporting != oldValue { damage.moved = true } }
    }
    var syncOutput = false {      // 2026: synchronized output
        didSet { if syncOutput != oldValue { damage.moved = true } }
    }
    /// The colour the program gave the caret (OSC 12), or `.plain` for the
    /// theme's own. The shape of the caret is the person's setting and
    /// stays one; the colour is the program's, which is the division that
    /// matters — vim paints the caret to say which mode it is in, and only
    /// vim knows which.
    var cursorInk: Paint = .plain {
        didSet { if cursorInk != oldValue { damage.moved = true } }
    }

    /// The modes as one small word, for whoever has to act on them with no
    /// screen in hand (see Modes).
    var modes: Modes {
        Modes(
            mouse: mouse, mouseFormat: mouseFormat, applicationCursor: applicationCursor,
            applicationKeypad: applicationKeypad,
            focus: focusReporting, sync: syncOutput, visible: visible, reversed: reverseVideo
        )
    }

    /// The alternate screen: the rows of the main one are kept here while
    /// it shows. The alternate has no scrollback — lines that leave its
    /// top are gone.
    private(set) var alternate = false
    private var kept: (rows: [Row], x: Int, y: Int, ink: Ink, link: UInt16)?

    /// What has changed since it was last taken.
    private(set) var damage = Damage()

    init(width: Int = 80, height: Int = 24) {
        self.width = max(1, width)
        self.height = max(1, height)
        rows = Array(repeating: Row(width: self.width), count: self.height)
        bottom = self.height - 1
    }

    /// The place of a screen row: where it sits in the scrollback as a
    /// whole, counting every row that has ever left the top.
    func place(_ row: Int) -> Int { backBase + back.count + row }

    /// The caret is somewhere else: a frame is owed for it, though not one
    /// cell has changed. Every way of moving the cursor without writing
    /// says this, or a program that only repositions is drawn nowhere it
    /// has gone — a cursor-motion sequence on an idle screen used to leave
    /// the drawing exactly as it was.
    private func caretMoved() { damage.moved = true }

    // MARK: Writing

    /// Put a character where the cursor is, wrapping and scrolling as the
    /// modes say. A wide character takes the square after it; at the edge
    /// both clip rather than wrap halfway.
    func put(_ char: Character, wide: Bool) {
        if pendingWrap, wraparound {
            pendingWrap = false
            x = 0
            lineFeed()
        }
        guard y < height, x < width else { return }
        var row = rows[y]
        if insert {
            row.cells.insert(square(" "), at: min(x, width - 1))
            row.cells.removeLast()
        }
        row.cells[x] = square(char, wide: wide)
        if wide, x + 1 < width {
            row.cells[x + 1] = square(" ")
            x += 1
        }
        rows[y] = row
        if x + 1 < width {
            x += 1
        } else {
            pendingWrap = true
        }
        damage.rows.insert(place(y))
    }

    /// The carriage return: back to the first column.
    func carriageReturn() {
        x = 0
        pendingWrap = false
        caretMoved()
    }

    /// The line feed: down a row, scrolling the region if the cursor is at
    /// its bottom, and never past the screen's last row.
    func lineFeed() {
        pendingWrap = false
        if y == bottom {
            scrollUp(1)
        } else if y < height - 1 {
            y += 1
        }
        caretMoved()
    }

    /// ESC M: up a row, scrolling the region down if the cursor is at its
    /// top — the line feed the other way.
    func reverseFeed() {
        if y == top {
            scrollDown(1)
        } else if y > 0 {
            y -= 1
        }
        caretMoved()
    }

    func backspace() {
        pendingWrap = false
        if x > 0 { x -= 1 }
        caretMoved()
    }

    /// The tab stops, every eighth column to start with (HTS sets one,
    /// TBC takes them away; see TerminalParse).
    private(set) var tabStops: Set<Int> = Set(stride(from: 8, to: 1024, by: 8))

    /// A tab stop at the cursor.
    func setTabStop() { tabStops.insert(x) }

    /// The tab stop at this column, if there.
    func clearTabStop(at column: Int) { tabStops.remove(column) }

    /// All of them, however they got there.
    func clearTabStops() { tabStops.removeAll() }

    /// To the next tab stop, or the last column if there is none closer.
    func tab() {
        pendingWrap = false
        // The first stop past the cursor — a set's order is nobody's,
        // so the first one that fits is the smallest one there is.
        if let next = tabStops.filter({ $0 > x }).min(), next < width {
            x = next
        } else {
            x = width - 1
        }
        caretMoved()
    }

    // MARK: Moving

    /// Where the cursor is asked to be, in one column and one row, both
    /// from zero. In origin mode both are within the scroll region, and
    /// neither may leave it; otherwise neither may leave the screen.
    func move(to column: Int, row: Int) {
        pendingWrap = false
        let left = origin ? top : 0
        let below = origin ? bottom : height - 1
        y = min(max(row, left), below)
        x = min(max(column, 0), width - 1)
        caretMoved()
    }

    /// Up and down stop at the edge of the scroll region from inside it,
    /// and at the edge of the screen from below it.
    func moveUp(_ steps: Int) {
        pendingWrap = false
        let edge = y >= top ? top : 0
        y = max(y - steps, edge)
        caretMoved()
    }

    func moveDown(_ steps: Int) {
        pendingWrap = false
        let edge = y <= bottom ? bottom : height - 1
        y = min(y + steps, edge)
        caretMoved()
    }

    func moveForward(_ steps: Int) {
        pendingWrap = false
        x = min(x + steps, width - 1)
        caretMoved()
    }

    func moveBack(_ steps: Int) {
        pendingWrap = false
        x = max(x - steps, 0)
        caretMoved()
    }

    /// The scroll region the program asked for. Both inclusive, both
    /// clamped to the screen, the cursor going home — as the sequence says.
    func setRegion(top: Int, bottom: Int) {
        let above = min(max(top, 0), height - 1)
        let below = min(max(bottom, above), height - 1)
        self.top = above
        self.bottom = below
        move(to: 0, row: origin ? above : 0)
    }

    // MARK: Erasing and rearranging

    /// ED: erase the screen from where the cursor is. 0 to the end, 1
    /// from the beginning, 2 both, 3 the scrollback as well — and the
    /// cursor, whatever is erased, stays where it is.
    func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseRow(0)
            if y + 1 < height {
                for row in (y + 1)..<height { rows[row] = Row(width: width); damage.rows.insert(place(row)) }
            }
        case 1:
            eraseRow(1)
            if y > 0 {
                for row in 0..<y { rows[row] = Row(width: width); damage.rows.insert(place(row)) }
            }
        case 2:
            rows = Array(repeating: Row(width: width), count: height)
            for row in 0..<height { damage.rows.insert(place(row)) }
        case 3:
            backBase += back.count
            back = []
            damage.overturned = true
        default:
            break
        }
    }

    /// EL: erase the cursor's row. 0 to the end of it, 1 from its
    /// beginning, 2 all of it.
    func eraseRow(_ mode: Int) {
        guard y < height else { return }
        var row = rows[y]
        switch mode {
        case 0:
            for column in x..<width { row.cells[column] = square(" ") }
        case 1:
            for column in 0...min(x, width - 1) { row.cells[column] = square(" ") }
        default:
            row.cells = Array(repeating: square(" "), count: width)
        }
        rows[y] = row
        damage.rows.insert(place(y))
    }

    /// ECH: erase this many squares from the cursor, without moving it.
    func eraseChars(_ count: Int) {
        guard y < height else { return }
        var row = rows[y]
        for column in x..<min(x + count, width) { row.cells[column] = square(" ") }
        rows[y] = row
        damage.rows.insert(place(y))
    }

    /// IL and DL: rows put in or taken out at the cursor, inside the
    /// scroll region; outside it, nothing happens.
    func insertRows(_ count: Int) {
        guard y >= top, y <= bottom else { return }
        let blank = Array(repeating: Row(width: width), count: min(count, bottom - y + 1))
        let rest = rows[y...min(bottom, height - 1)]
        rows.replaceSubrange(y...min(bottom, height - 1), with: blank + rest.dropLast(blank.count))
        for row in y...bottom { damage.rows.insert(place(row)) }
    }

    func deleteRows(_ count: Int) {
        guard y >= top, y <= bottom else { return }
        let gone = min(count, bottom - y + 1)
        let blank = Array(repeating: Row(width: width), count: gone)
        let rest = rows[(y + gone)...min(bottom, height - 1)]
        rows.replaceSubrange(y...min(bottom, height - 1), with: rest + blank)
        for row in y...bottom { damage.rows.insert(place(row)) }
    }

    /// ICH and DCH: squares put in or taken out at the cursor, the rest of
    /// the row sliding to or away from it.
    func insertChars(_ count: Int) {
        guard y < height, x < width else { return }
        var row = rows[y]
        let slide = min(count, width - x)
        row.cells.removeLast(slide)
        row.cells.insert(contentsOf: Array(repeating: square(" "), count: slide), at: x)
        rows[y] = row
        damage.rows.insert(place(y))
    }

    func deleteChars(_ count: Int) {
        guard y < height, x < width else { return }
        var row = rows[y]
        let slide = min(count, width - x)
        row.cells.removeSubrange(x..<(x + slide))
        row.cells.append(contentsOf: Array(repeating: square(" "), count: slide))
        rows[y] = row
        damage.rows.insert(place(y))
    }

    /// The scrollback holds its limit; rows that fall out of it are gone,
    /// and the blocks that were in them go with them. Called by the scroll
    /// that pushed them out, and by Settings when the limit itself is
    /// lowered under a terminal already running.
    func trim() {
        guard back.count > backLimit else { return }
        let extra = back.count - backLimit
        back.removeFirst(extra)
        backBase += extra
        blocks.removeAll { block in
            (block.last ?? block.first) < backBase
        }
        damage.blocks = true
    }

    /// SU and SD: the scroll region moved up or down a row at a time.
    /// Only from the top of the screen does a row leaving the top go to
    /// the scrollback; the alternate screen keeps none.
    func scrollUp(_ count: Int) {
        let gone = min(count, bottom - top + 1)
        if top == 0, !alternate {
            back.append(contentsOf: rows[0..<gone])
            trim()
            damage.scrolled = true
        }
        let blank = Array(repeating: Row(width: width), count: gone)
        let rest = top + gone <= bottom ? Array(rows[(top + gone)...bottom]) : []
        rows.replaceSubrange(top...bottom, with: rest + blank)
        for row in top...bottom { damage.rows.insert(place(row)) }
    }

    func scrollDown(_ count: Int) {
        let gone = min(count, bottom - top + 1)
        let blank = Array(repeating: Row(width: width), count: gone)
        let rest = bottom - gone >= top ? Array(rows[top...(bottom - gone)]) : []
        rows.replaceSubrange(top...bottom, with: blank + rest)
        for row in top...bottom { damage.rows.insert(place(row)) }
    }

    // MARK: Saving, keeping, resetting

    /// ESC 7 and CSI s: the cursor and the pen, kept for the restore.
    private var saved: (x: Int, y: Int, ink: Ink, link: UInt16, origin: Bool)?
    func saveCursor() {
        saved = (x: x, y: y, ink: ink, link: linkNow, origin: origin)
    }

    /// ESC 8 and CSI u: the cursor and the pen as they were kept, or home
    /// if they never were.
    func restoreCursor() {
        guard let saved else {
            move(to: 0, row: origin ? top : 0)
            return
        }
        x = min(saved.x, width - 1)
        y = min(saved.y, height - 1)
        ink = saved.ink
        linkNow = saved.link
        origin = saved.origin
        pendingWrap = false
        caretMoved()
    }

    /// To the alternate screen (47, 1047, 1049): the main one's rows are
    /// kept, the cursor and the pen too under 1049, and the alternate is
    /// blank. There is no scrollback in it — a line that leaves its top is
    /// gone, which is what a program like vim wants.
    func enterAlternate() {
        guard !alternate else { return }
        kept = (rows: rows, x: x, y: y, ink: ink, link: linkNow)
        rows = Array(repeating: Row(width: width), count: height)
        alternate = true
        x = 0
        y = 0
        linkNow = 0
        pendingWrap = false
        damage.overturned = true
    }

    /// Back to the main screen: its rows come back — rebuilt to the size
    /// the screen is now, for a resize may have come and gone while the
    /// alternate showed.
    func exitAlternate() {
        guard alternate, let kept else { return }
        rows = kept.rows.map { row -> Row in
            var row = row
            row.cells = Array(row.cells.prefix(width)) + Array(repeating: Cell(), count: max(0, width - row.cells.count))
            return row
        }
        rows += Array(repeating: Row(width: width), count: max(0, height - rows.count))
        rows.removeLast(max(0, rows.count - height))
        x = min(kept.x, width - 1)
        y = min(kept.y, height - 1)
        ink = kept.ink
        linkNow = kept.link
        alternate = false
        pendingWrap = false
        self.kept = nil
        damage.overturned = true
    }

    /// ESC # 8: the alignment pattern — every square filled with E, the
    /// screen the terminals were lined up by. Nothing in a real program
    /// sends it, and nothing fixes a screen faster when one does.
    func fillPattern() {
        for row in 0..<height {
            rows[row].cells = Array(repeating: Cell(char: "E"), count: width)
            damage.rows.insert(place(row))
        }
        x = 0
        y = 0
    }

    /// ESC c: everything as it was at the first.
    func reset() {
        rows = Array(repeating: Row(width: width), count: height)
        x = 0
        y = 0
        ink = .plain
        cursorInk = .plain
        linkNow = 0
        links.removeAll()
        linkAt.removeAll()
        top = 0
        bottom = height - 1
        wraparound = true
        origin = false
        visible = true
        reverseVideo = false
        insert = false
        pendingWrap = false
        tabStops = Set(stride(from: 8, to: 1024, by: 8))
        blocks.removeAll()
        damage.overturned = true
        damage.blocks = true
    }

    // MARK: Resizing

    /// A new size: the rows kept as they are, cut or padded to the new
    /// width, the last rows dropped or blank ones added at the bottom, the
    /// scroll region given back the whole screen, the cursor kept inside.
    /// (Lines are not reflowed — the shells a person runs retype what they
    /// need on a resize, and reflowing a scrollback is a project of its
    /// own, not a first version's.)
    func resize(width: Int, height: Int) {
        let width = max(1, width), height = max(1, height)
        guard width != self.width || height != self.height else { return }
        rows = rows.map { row in
            var row = row
            row.cells = Array(row.cells.prefix(width)) + Array(repeating: Cell(), count: max(0, width - row.cells.count))
            return row
        }
        // The main screen kept for the alternate is left as it was; it is
        // rebuilt on the way back (see `exitAlternate`).
        rows += Array(repeating: Row(width: width), count: max(0, height - rows.count))
        rows.removeLast(max(0, rows.count - height))
        self.width = width
        self.height = height
        top = 0
        bottom = height - 1
        x = min(x, width - 1)
        y = min(y, height - 1)
        pendingWrap = false
        damage = .everything
    }

    // MARK: Blocks

    /// The commands the shell has marked out, oldest first, by place.
    private(set) var blocks: [Block] = []

    /// OSC 133;A: a prompt has started — the block of the command that is
    /// coming. It begins on the row the cursor is on.
    func markPrompt() {
        blocks.append(Block(first: place(y), began: Date()))
        damage.blocks = true
    }

    /// OSC 133;B then C: the prompt is done and the command is running.
    func markCommand() {
        guard let index = blocks.indices.last else { return }
        blocks[index].state = .running
        damage.blocks = true
    }

    /// OSC 133;D: the command is done, with its exit code if the shell
    /// said one. The block ends on the row the cursor is on.
    func markEnd(exit: Int32?) {
        guard let index = blocks.indices.last else { return }
        blocks[index].last = place(y)
        blocks[index].state = .done
        blocks[index].ended = Date()
        blocks[index].exit = exit
        damage.blocks = true
    }

    // MARK: Damage

    /// What has changed since it was last taken, and a clean slate after.
    func take() -> Damage {
        let taken = damage
        damage = Damage()
        return taken
    }
}
