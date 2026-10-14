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
    var strike = false
    var blink = false
    var inverse = false
    var hidden = false

    static let plain = Ink()
}

/// One square of the screen: what it says, and what it is said with. A wide
/// character takes the square after it too; that one carries no character
/// of its own.
struct Cell: Equatable {
    var char: Character = " "
    var wide = false
    var ink: Ink = .plain

    init(char: Character = " ", wide: Bool = false, ink: Ink = .plain) {
        self.char = char
        self.wide = wide
        self.ink = ink
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
        let said = cells.reduce(into: "") { $0.append($1.char) }
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

    /// A gutter mark in red when the command failed — the one thing about
    /// a block a glance wants to know.
    var failed: Bool { exit.map { $0 != 0 } ?? false }
}

/// Which mouse the program asked to hear, if any. The names are what the
/// modes do: click is press and release, drag adds motion with a button
/// down, motion adds motion without one.
enum MouseMode: Equatable {
    case off, click, drag, motion
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

    var empty: Bool { rows.isEmpty && !scrolled && !overturned && !blocks }

    static let everything = Damage(rows: [], scrolled: true, overturned: true, blocks: true)
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

    // The modes a program sets, each the terminal's own name for it.
    var wraparound = true         // DECAWM, on by default
    var origin = false            // DECOM
    var visible = true            // DECTCEM
    var reverseVideo = false     // DECSCNM
    var insert = false            // IRM
    var applicationCursor = false // DECCKM
    var applicationKeypad = false // DECKPAM
    var mouse = MouseMode.off
    var mouseExact = false        // SGR mouse (1006) rather than the old character encoding
    var bracketedPaste = false    // 2004

    /// The alternate screen: the rows of the main one are kept here while
    /// it shows. The alternate has no scrollback — lines that leave its
    /// top are gone.
    private(set) var alternate = false
    private var kept: (rows: [Row], x: Int, y: Int, ink: Ink)?

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
            row.cells.insert(Cell(ink: ink), at: min(x, width - 1))
            row.cells.removeLast()
        }
        row.cells[x] = Cell(char: char, wide: wide, ink: ink)
        if wide, x + 1 < width {
            row.cells[x + 1] = Cell(ink: ink)
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
    }

    /// ESC M: up a row, scrolling the region down if the cursor is at its
    /// top — the line feed the other way.
    func reverseFeed() {
        if y == top {
            scrollDown(1)
        } else if y > 0 {
            y -= 1
        }
    }

    func backspace() {
        pendingWrap = false
        if x > 0 { x -= 1 }
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
    }

    /// Up and down stop at the edge of the scroll region from inside it,
    /// and at the edge of the screen from below it.
    func moveUp(_ steps: Int) {
        pendingWrap = false
        let edge = y >= top ? top : 0
        y = max(y - steps, edge)
    }

    func moveDown(_ steps: Int) {
        pendingWrap = false
        let edge = y <= bottom ? bottom : height - 1
        y = min(y + steps, edge)
    }

    func moveForward(_ steps: Int) {
        pendingWrap = false
        x = min(x + steps, width - 1)
    }

    func moveBack(_ steps: Int) {
        pendingWrap = false
        x = max(x - steps, 0)
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
            for column in x..<width { row.cells[column] = Cell(ink: ink) }
        case 1:
            for column in 0...min(x, width - 1) { row.cells[column] = Cell(ink: ink) }
        default:
            row.cells = Array(repeating: Cell(ink: ink), count: width)
        }
        rows[y] = row
        damage.rows.insert(place(y))
    }

    /// ECH: erase this many squares from the cursor, without moving it.
    func eraseChars(_ count: Int) {
        guard y < height else { return }
        var row = rows[y]
        for column in x..<min(x + count, width) { row.cells[column] = Cell(ink: ink) }
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
        row.cells.insert(contentsOf: Array(repeating: Cell(ink: ink), count: slide), at: x)
        rows[y] = row
        damage.rows.insert(place(y))
    }

    func deleteChars(_ count: Int) {
        guard y < height, x < width else { return }
        var row = rows[y]
        let slide = min(count, width - x)
        row.cells.removeSubrange(x..<(x + slide))
        row.cells.append(contentsOf: Array(repeating: Cell(ink: ink), count: slide))
        rows[y] = row
        damage.rows.insert(place(y))
    }

    /// SU and SD: the scroll region moved up or down a row at a time.
    /// Only from the top of the screen does a row leaving the top go to
    /// the scrollback; the alternate screen keeps none.
    func scrollUp(_ count: Int) {
        let gone = min(count, bottom - top + 1)
        if top == 0, !alternate {
            back.append(contentsOf: rows[0..<gone])
            // The scrollback holds its limit; rows that fall out of it are
            // gone, and the blocks that were in them go with them.
            if back.count > backLimit {
                let extra = back.count - backLimit
                back.removeFirst(extra)
                backBase += extra
                blocks.removeAll { block in
                    (block.last ?? block.first) < backBase
                }
                damage.blocks = true
            }
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
    private var saved: (x: Int, y: Int, ink: Ink, origin: Bool)?
    func saveCursor() {
        saved = (x: x, y: y, ink: ink, origin: origin)
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
        origin = saved.origin
        pendingWrap = false
    }

    /// To the alternate screen (47, 1047, 1049): the main one's rows are
    /// kept, the cursor and the pen too under 1049, and the alternate is
    /// blank. There is no scrollback in it — a line that leaves its top is
    /// gone, which is what a program like vim wants.
    func enterAlternate() {
        guard !alternate else { return }
        kept = (rows: rows, x: x, y: y, ink: ink)
        rows = Array(repeating: Row(width: width), count: height)
        alternate = true
        x = 0
        y = 0
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
        if kept != nil {
            // The main screen is kept as it was; it will be rebuilt on the
            // way back (see `exitAlternate`).
        }
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
        guard !blocks.isEmpty else { return }
        blocks[blocks.count - 1].state = .running
        damage.blocks = true
    }

    /// OSC 133;D: the command is done, with its exit code if the shell
    /// said one. The block ends on the row the cursor is on.
    func markEnd(exit: Int32?) {
        guard !blocks.isEmpty else { return }
        blocks[blocks.count - 1].last = place(y)
        blocks[blocks.count - 1].state = .done
        blocks[blocks.count - 1].ended = Date()
        blocks[blocks.count - 1].exit = exit
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
