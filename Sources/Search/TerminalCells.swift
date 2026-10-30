import Foundation

// The bookkeeping behind the damage-driven cell cache: whether the rows a
// slot of the ring was written from are still the rows a frame is about to
// draw.
//
// Nothing here knows about Metal — a slot is a number, and the buffer it
// names lives with the renderer (see TerminalDraw) — and almost nothing
// here knows about damage. A screen row is an `Array` of squares, and an
// Array is copied when it is written to: so a row this holds is a row
// nobody can have written, and the address of its squares is a name for the
// words in it. A frame asks, row by row, whether the row it is about to
// draw is one this slot already has, and converts only the ones that are
// not. A row that was written in place is a row whose name has changed, so
// it is the names, and not the screen's report of what it wrote, that keep
// a frame honest — which is the point of doing it this way: a report that
// arrives late, or not at all, can cost a frame's worth of work but can
// never leave a stale row on the screen.
//
// The ring exists because a frame is encoded while the one before it is
// still on the GPU: a frame reads the cells of its own slot, so the next
// frame has to write somewhere else, and a slot is only written again once
// the frame that read it has completed (see TerminalDraw's `take`).
//
// A scroll is the case all of this is worth having for. The screen moved a
// row at a time, so every place has different words on it and a screen's
// report says every row changed — but the rows themselves only moved. The
// records move with them, and the band the scroll uncovered is all that has
// to be converted.

struct TerminalCells {
    /// One slot of the ring, as far as the cache is concerned.
    struct Slot: Equatable {
        /// The place the slot's first row was at when it was last written,
        /// or nil for a slot nothing has been written into yet.
        var top: Int?
        /// The shape it was written at. Either changing — a resize, a new
        /// face whose cell measures differently — leaves nothing of it
        /// worth keeping.
        var columns = 0
        /// The rows it was written from, held. Holding them is not
        /// bookkeeping for its own sake: an Array is copied when it is
        /// written to, so a row held here cannot be written *through*.
        /// That is what makes the address of its squares a name for the
        /// words, and what keeps a buffer that has been let go from being
        /// handed out again under another row's name.
        var held: [Row] = []

        /// The names of the held rows, as `plan` compares them.
        var names: [UInt] { TerminalCells.names(of: held) }
    }

    /// What a slot has to do to hold what the frame is drawing.
    struct Plan: Equatable {
        /// Convert every row: nothing in there can be kept.
        var whole = false
        /// The rows the slot keeps have to move this far along it —
        /// negative is toward its start, zero is not at all — because the
        /// frame moved the other way up the screen.
        var shift = 0
        /// The rows to convert, as bands, low row first: the band a shift
        /// uncovered, and any row the shift would have carried the wrong
        /// words to.
        var ranges: [Range<Int>] = []

        /// Whether the slot already says what the frame does.
        var nothing: Bool { !whole && shift == 0 && ranges.isEmpty }
    }

    private var slots: [Slot]

    init(ring: Int) {
        slots = Array(repeating: Slot(), count: max(1, ring))
    }

    var count: Int { slots.count }

    /// What one slot is holding, for a test or an assertion.
    func slot(_ index: Int) -> Slot { slots[index] }

    /// What the slot at `index` has to do to hold a frame whose first row is
    /// the place `top`, `columns` wide, made of these rows.
    ///
    /// A row is the very row this slot was written from — the same squares
    /// at the same address, held here so that nobody could have written them
    /// — then its records are already in the slot and want nothing. A row
    /// the frame moved is the same row at another index, so its records move
    /// with it. Anything else is a row this slot has not got, and is
    /// converted from the frame.
    func plan(_ index: Int, rows: [Row], top: Int, columns: Int, overturned: Bool) -> Plan {
        let lines = rows.count
        guard columns > 0, lines > 0 else { return Plan(whole: true) }
        let was = slots[index]
        // Nothing written yet, a different shape, or a screen turned over —
        // the alternate screen, a resize, a dropped scrollback — where what
        // a slot holds was not written from a frame like this one.
        guard !overturned, let old = was.top, was.columns == columns,
              was.held.count == lines
        else { return Plan(whole: true) }

        let delta = top - old
        // A frame that moved further than the slot is long has nothing left
        // in it with a row to move.
        if abs(delta) >= lines { return Plan(whole: true) }

        let here = TerminalCells.names(of: rows)
        let there = was.names
        // The band the move leaves without a source, and the rows the move
        // would carry the wrong words to: a row written in place is not the
        // row that moved into its place, and nothing but its name says so.
        var again = Set<Int>()
        if delta > 0 { again.formUnion((lines - delta)..<lines) }
        else if delta < 0 { again.formUnion(0..<(-delta)) }
        for row in 0..<lines {
            let source = row + delta
            guard source >= 0, source < lines else { continue }
            if here[row] != there[source] { again.insert(row) }
        }
        return Plan(shift: delta, ranges: TerminalCells.bands(of: again.sorted()))
    }

    /// A slot has been filled: its first row is at this place, in this
    /// shape, out of these rows.
    mutating func written(_ index: Int, top: Int, columns: Int, held: [Row]) {
        slots[index] = Slot(top: top, columns: columns, held: held)
    }

    /// Nothing any slot holds is to be trusted again: every row is converted
    /// from the frame afresh. Not for anything the *screen* did — the names
    /// catch all of that — but for what the records carry that the screen
    /// never saw: the colours of a theme that has just been changed, the
    /// slot in the atlas a glyph is cut to, the size a cell is at.
    mutating func forget() {
        slots = Array(repeating: Slot(), count: slots.count)
    }

    /// The addresses of the squares of each row, as numbers: what a row is
    /// called while it is held (see `Slot.held`). Every square array is
    /// non-empty — a row is as wide as the screen, and the screen is at
    /// least one square — so no name is zero and none is nil.
    private static func names(of rows: [Row]) -> [UInt] {
        rows.map { row in
            row.cells.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
    }

    /// Adjacent row numbers, as the contiguous ranges a copy wants them in.
    /// Empty in, empty out; the rest comes back sorted, deduplicated and
    /// merged, so the band a shift uncovered and a row rewritten beside it
    /// are one conversion rather than two.
    static func bands(of rows: [Int]) -> [Range<Int>] {
        guard !rows.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var low = 0
        var high = 0
        for row in Set(rows).sorted() {
            if row == high {
                high = row + 1
                continue
            }
            if high > low { ranges.append(low..<high) }
            low = row
            high = row + 1
        }
        if high > low { ranges.append(low..<high) }
        return ranges
    }
}
