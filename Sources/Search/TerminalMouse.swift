import Foundation

// The pointer's side of the terminal: how a click, a drag and a wheel
// notch become the bytes a program reads.
//
// Three encodings, because a program picks one. The old one — X10's, and
// the 1000/1002/1003 family that grew out of it — writes `ESC [ M` and
// then three bytes with 32 added to each. SGR (1006) writes the numbers
// out in decimal between `ESC [ <` and `M` or `m`. urxvt's (1015) writes
// them in decimal too, but with no `<` and no `m`, and xterm keeps it only
// for the programs that ask for it by name and says it is no improvement
// on SGR. And 1016 is SGR's encoding carrying pixel coordinates rather
// than cells.
//
// They are not merely two spellings. The old one has one byte per field,
// so a column past 223 overflows into the field after it and the click
// lands somewhere else entirely; and its release code is "3", which says
// that whatever was held came up but not which button it was — two
// buttons at once, and a program holding a drag through a release, are
// both unsayable in it. That is why SGR was invented, and why anything
// that wants precision asks for it.
//
// Nothing here touches a view, an event or a screen: this is the
// arithmetic, and the view is where the arithmetic is applied.

enum MouseReport {
    // MARK: - how the numbers are written, and what they count

    /// The mouse encoding a program has switched on, one at a time: 1006,
    /// 1015 and 1016 each replace whatever was on, which is how a program
    /// that sets a second one means it. 1005 — the other extended
    /// encoding, the one that pushes big coordinates through UTF-8 — is
    /// deliberately not one of these: a program that asks for it gets the
    /// plain encoding, which is what it got before any of them existed.
    enum Format: Equatable {
        /// `ESC [ M` and three bytes with 32 added: the one an untouched
        /// terminal is in, and the only one a terminal without these modes
        /// ever speaks.
        case legacy
        /// 1006: the numbers in decimal between `ESC [ <` and `M`, or `m`
        /// when a button came up — so a release still says which button.
        case sgr
        /// 1015, urxvt's: the same decimal numbers without the `<`, ending
        /// in `M` always, and with a release that is a code rather than a
        /// letter — so it fixes the byte fields and nothing else.
        case urxvt
        /// 1016: SGR's encoding, counting pixels rather than cells — the
        /// sub-cell place of the pointer, which is what a program drawing
        /// with it in a picture wants and all a cell coordinate cannot say.
        case sgrPixels

        /// Whether the numbers are pixels rather than cells. What the
        /// encodings below do with them is the same either way; this is
        /// the caller's side of it.
        var pixels: Bool { self == .sgrPixels }

        /// The mode number that asks for this encoding, zero for the one
        /// an untouched terminal is in. Written once (see MouseMode.mode):
        /// DECSET asks with it and DECRQM is answered with it.
        var mode: Int {
            switch self {
            case .sgr: return 1006
            case .urxvt: return 1015
            case .sgrPixels: return 1016
            case .legacy: return 0
            }
        }

        init?(mode: Int) {
            switch mode {
            case 1006: self = .sgr
            case 1015: self = .urxvt
            case 1016: self = .sgrPixels
            default: return nil
            }
        }
    }

    // MARK: - the pieces

    /// The button, in the numbering the protocol counts in. AppKit says 1
    /// for the right button and 2 for the middle one, and the protocol —
    /// grown out of the three-button mice of the eighties — says 1 for the
    /// middle and 2 for the right.
    static func number(for button: Int) -> Int {
        switch button {
        case 0: return 0
        case 1: return 2
        case 2: return 1
        default: return button
        }
    }

    /// The modifiers, as the protocol adds them to the code: four for
    /// shift, eight for option, sixteen for control. Option is in here
    /// even though the view keeps it out of every report — it is the way
    /// back to the selection — because a report made with it from
    /// anywhere else should still carry the right bits.
    static func held(shift: Bool = false, option: Bool = false, control: Bool = false) -> Int {
        (shift ? 4 : 0) + (option ? 8 : 0) + (control ? 16 : 0)
    }

    /// The code the protocol gives a button that is not one: what a move
    /// with nothing held is made of.
    static let noButton = 3
    /// Added to the code when the pointer moved rather than a button moved.
    static let motion = 32

    // MARK: - the events

    /// A wheel notch, which the protocol has as buttons 4 and 5 — up, then
    /// down. A wheel has no release, so it is always a press.
    static func wheel(up: Bool, column: Int, row: Int, held: Int = 0, format: Format) -> [UInt8] {
        bytes(button: up ? 64 : 65, column: column, row: row, held: held, format: format)
    }

    /// One event, as the program asked to have it.
    ///
    /// `column` and `row` are counted from zero, whichever unit they are
    /// in; both of the ones that count from one add it here, so that no
    /// caller has to remember which of the two conventions it is in.
    static func bytes(
        button: Int, column: Int, row: Int, held: Int = 0,
        dragging: Bool = false, release: Bool = false, format: Format
    ) -> [UInt8] {
        let column = column + 1, row = row + 1
        // The modifiers and the motion flag are added to whichever button
        // is named, including the "no button" a release is written with:
        // the encoding can lose which button came up, but not that shift
        // was down while it did.
        let flags = held + (dragging ? motion : 0)
        let code = button + flags
        let up = (release ? noButton : button) + flags
        switch format {
        case .sgr, .sgrPixels:
            return Array("\u{1b}[<\(code);\(column);\(row)\(release ? "m" : "M")".utf8)
        case .urxvt:
            return Array("\u{1b}[\(up);\(column);\(row)M".utf8)
        case .legacy:
            // Past 223 the field would carry into the one after it. Every
            // terminal that speaks this encoding clamps for the same
            // reason: the alternative is a click reported at the wrong
            // place, which is worse than one reported at the edge.
            return [
                0x1b, 0x5b, 0x4d,
                UInt8(32 + min(max(up, 0), 223)),
                UInt8(32 + min(max(column, 0), 223)),
                UInt8(32 + min(max(row, 0), 223)),
            ]
        }
    }

    // MARK: - where the pointer is

    /// Where the pointer is, in the unit the program asked to hear about:
    /// the cell it is over, or — for 1016 — the pixel of the frame it is
    /// on. `point` is in the frame's own terms — the corner the first cell
    /// is drawn at is `inset` in from each edge, and y counts down from the
    /// top, the way the rows do — `inset` the room the frame leaves around
    /// the grid, and the cell and the scale are what turn one into either.
    /// A view whose own y runs the other way converts before it gets here.
    ///
    /// Below the grid is clamped to the first cell and the first pixel,
    /// since the pointer can be in that room and there is nothing before
    /// it. The far side is not clamped: a program that asked for pixels
    /// asked to hear where the pointer really is, and the last pixel of the
    /// last cell is a place a cell coordinate cannot name.
    static func place(
        of point: CGPoint, inset: CGFloat, cell: CGSize, scale: CGFloat, pixels: Bool
    ) -> (column: Int, row: Int) {
        let across = point.x - inset, down = point.y - inset
        if pixels {
            return (
                max(0, Int((across * scale).rounded(.down))),
                max(0, Int((down * scale).rounded(.down)))
            )
        }
        return (
            max(0, Int((across / cell.width).rounded(.down))),
            max(0, Int((down / cell.height).rounded(.down)))
        )
    }
}
