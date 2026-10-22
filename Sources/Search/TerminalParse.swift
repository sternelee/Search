import Foundation

// Turns the bytes a program writes into what they mean: characters put on
// the screen, the cursor moved, the pen changed, and the few things a
// terminal is expected to answer (where the cursor is, what it is). The
// sequences are the ones every program uses — the set xterm named and the
// decades since kept — and nothing more: a sequence this doesn't know is
// swallowed whole, counted, and never misread as the start of another.
//
// What it reads, it writes into a Screen (see TerminalGrid). What it can't
// write into a screen — the window's title, where the shell is, a
// notification a program asks for — it says aloud, to whoever cares; and
// what it must answer, it hands back to be written to the program.

/// What a program said that the screen itself can't hold.
enum Notice: Equatable {
    /// OSC 0 and 2: the window's title, the tab's name.
    case title(String)
    /// OSC 7: where the shell is, always on this Mac (the host is dropped).
    case cwd(URL)
    /// OSC 9 and 777: a notification, with its title if it brought one.
    case note(title: String, body: String)
    /// BEL.
    case bell
    /// OSC 7784: what the shell's line editor said its line is now, for a
    /// terminal that stands in for the prompt with a dock of its own
    /// (see TerminalDock). The marks the shell prints around its commands
    /// still arrive by the screen; this is the mirror of the line being
    /// edited, which the screen holds underneath the veil.
    case dock(Dock)
}

/// The shell's line, as its editor reported it (OSC 7784): the text, the
/// caret's column counted in characters, the suggestion ghosted after the
/// text — or the editor giving up on keeping the mirror, which is what a
/// line too long or wrapped does (the grid takes the input back).
enum Dock: Equatable {
    case line(text: String, cursor: Int, suggestion: String)
    case off
}

final class Parser {
    private let screen: Screen

    /// What the program said that the screen can't hold.
    var say: ((Notice) -> Void)?
    /// What the terminal must write back: where the cursor is, what it is.
    var reply: ((String) -> Void)?
    /// What the program put on the clipboard (OSC 52). Taken out of here
    /// rather than set from here, because the clipboard is the app's and
    /// this is a parser's: it is handed the text and told nothing else.
    var copied: ((String) -> Void)?

    /// Every sequence fed that was swallowed whole — the honest count of
    /// how much this doesn't know, for whoever is curious.
    private(set) var swallowed = 0

    private var last: (char: Character, wide: Bool)?

    init(screen: Screen) {
        self.screen = screen
    }

    // MARK: Feeding

    private enum State {
        /// Waiting for whatever comes.
        case ground
        /// After ESC, waiting to be told what it began.
        case esc
        /// After ESC ( or ) or #: a single character says what they meant.
        case slot(Character)
        /// Inside CSI: parameters, a private marker, then the final byte.
        case csi
        /// Inside OSC, until BEL or ST ends it.
        case osc
        /// An ESC inside OSC: a \\ ends it, anything else cancels it.
        case oscEsc
        /// Inside a string sequence (DCS, SOS, PM, APC), skipped until ST.
        case skip
        /// An ESC inside one.
        case skipEsc
    }

    private var state: State = .ground

    // The pieces of a control sequence, taken apart as they arrive.
    private var params: [Int] = []
    /// The places a colon sat, as indices of the parameters they sat
    /// before: the one mark a sub-parameter leaves on the sequence it
    /// was spoken in. Colons and semicolons both end a parameter, so a
    /// colon is a semicolon as far as the counting sequences are
    /// concerned — and is, everywhere but SGR's styles.
    private var colons: Set<Int> = []
    private var param = 0
    private var empty = true
    private var marker: Character?
    private var inter: Character?
    private var payload: [UInt8] = []

    // The character sets: four of them, one in use at a time, each either
    // the letters as they are or the DEC line-drawing set. A program
    // designates into G0–G3 (ESC ( ) * +) and shifts between them — SI and
    // SO for the first two, ESC n and ESC o for the other two, which only
    // ever mattered to the programs that drew boxes in the corner of a
    // screen full of them.
    private var g0 = false
    private var g1 = false
    private var g2 = false
    private var g3 = false
    private var graphic = 0

    // A UTF-8 character, taken apart as its bytes arrive.
    private var pending: [UInt8] = []

    func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes {
            switch state {
            case .ground:
                ground(byte)
            case .esc:
                escape(byte)
            case .slot(let what):
                slot(byte, what: what)
            case .csi:
                sequence(byte)
            case .osc:
                operating(byte)
            case .oscEsc:
                if byte == 0x5C { sayOperating(payload) }
                state = .ground
            case .skip:
                if byte == 0x1B { state = .skipEsc }
                else if byte == 0x18 || byte == 0x1A { state = .ground }
            case .skipEsc:
                state = byte == 0x5C ? .ground : (byte == 0x18 || byte == 0x1A ? .ground : .skip)
            }
        }
    }

    // MARK: The ground

    private func ground(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            state = .esc
        case 0x00...0x1F:
            execute(byte)
        case 0x20...0x7E:
            print(Character(UnicodeScalar(byte)))
        default:
            utf8(byte)
        }
    }

    /// The C0 controls, which run wherever they land — in the ground or
    /// in the middle of a control sequence.
    private func execute(_ byte: UInt8) {
        switch byte {
        case 0x07: say?(.bell)
        case 0x08: screen.backspace()
        case 0x09: screen.tab()
        case 0x0A, 0x0B, 0x0C: screen.lineFeed()
        case 0x0D: screen.carriageReturn()
        case 0x0E: graphic = 1     // SO: G1
        case 0x0F: graphic = 0     // SI: G0
        default: break
        }
    }

    // MARK: Characters

    /// A byte in the printable range or a UTF-8 sequence's worth, drawn
    /// with the character set in force and put on the screen with the
    /// width it takes there.
    private func print(_ char: Character) {
        // This runs once per character the program prints, so it picks the
        // set in force without building anything: `graphic` is one of the
        // four SI, SO, LS2 and LS3 name, and cannot be anything else.
        let on: Bool
        switch graphic {
        case 1: on = g1
        case 2: on = g2
        case 3: on = g3
        default: on = g0
        }
        let drawn = on ? Parser.drawing[char] ?? char : char
        let wide = Parser.isWide(drawn)
        screen.put(drawn, wide: wide)
        last = (drawn, wide)
    }

    private func utf8(_ byte: UInt8) {
        pending.append(byte)
        // Complete the moment the bytes say one whole character; drop the
        // lot as a replacement character once four bytes can't be one.
        if let text = String(bytes: pending, encoding: .utf8) {
            pending = []
            for char in text { print(char) }
        } else if pending.count >= 4 {
            pending = []
            print("\u{FFFD}")
        }
    }

    /// The range of a wide character: the scripts a full square, and the
    /// blocks of pictures the terminals drew double from the start.
    static func isWide(_ char: Character) -> Bool {
        let scalars = char.unicodeScalars
        guard let scalar = scalars.first else { return false }
        // A sequence that asks for emoji presentation is wide, and so is a
        // cluster that rides on a wide base — a letter with a combining
        // mark is still its base's square. What is judged is the first.
        if scalars.contains(where: { $0.value == 0xFE0F }) { return true }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F000...0x1FAFF, 0x1FC00...0x1FFFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// The DEC line-drawing set, ESC ( 0: the corners and crossings that
    /// made a box on the screens that had no graphics for anything else.
    private static let drawing: [Character: Character] = [
        "`": "◆", "a": "▒", "b": "␉", "c": "␌", "d": "␍", "e": "␊",
        "f": "°", "g": "±", "h": "␤", "i": "␋", "j": "┘", "k": "┐",
        "l": "┌", "m": "└", "n": "┼", "o": "⎺", "p": "⎻", "q": "─",
        "r": "⎼", "s": "⎽", "t": "├", "u": "┤", "v": "┴", "w": "┬",
        "x": "│", "y": "≤", "z": "≥", "{": "π", "|": "≠", "}": "£", "~": "·",
    ]

    /// The input dock's escaped text, as the script wrote it (see
    /// TerminalShell): `\\` for a backslash, `\\n` and the rest for the
    /// controls that would break the payload, `\\x3b` for a semicolon,
    /// which would otherwise end the field. Read back one escape at a
    /// time; anything the script never writes is passed through as it
    /// stands, which is the honest reading of a stranger's text.
    static func docked(_ escaped: String) -> String {
        var said = ""
        var marks = escaped.makeIterator()
        while let letter = marks.next() {
            guard letter == "\\", let follow = marks.next() else {
                said.append(letter)
                continue
            }
            switch follow {
            case "\\": said.append("\\")
            case "n": said.append("\n")
            case "r": said.append("\r")
            case "t": said.append("\t")
            case "e": said.append("\u{1b}")
            case "a": said.append("\u{07}")
            case "x":
                // `\\x3b` is a semicolon in hiding; the `x` is consumed
                // here and the `3b` follows it through the loop below.
                // The two marks are drawn before the test so that the
                // else branch can give them back: an `x` that promised
                // hex and didn't deliver must not eat its neighbours.
                let three = marks.next()
                let be = marks.next()
                if three == "3", be == "b" {
                    said.append(";")
                } else {
                    said.append(follow)
                    if let three { said.append(three) }
                    if let be { said.append(be) }
                }
            default: said.append(follow)
            }
        }
        return said
    }

    /// An X11 colour spec, as much of one as a terminal is ever sent:
    /// `rgb:RR/GG/BB` (and `rgba:`, whose alpha nothing here can show) and
    /// `#RRGGBB`. The digits are hex and may number one per channel or four
    /// — a spec may say the colour at any precision it likes — so each is
    /// scaled to a byte by what its own width can hold.
    private static func colour(_ spec: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        var parts: [Substring] = []
        if spec.hasPrefix("#") {
            let hex = spec.dropFirst()
            guard hex.count % 3 == 0 else { return nil }
            let each = hex.count / 3
            guard each > 0 else { return nil }
            let digits = Array(hex)
            for channel in 0..<3 {
                parts.append(Substring(String(digits[(channel * each)..<((channel + 1) * each)])))
            }
        } else if spec.hasPrefix("rgb"), let colon = spec.firstIndex(of: ":") {
            parts = spec[spec.index(after: colon)...].split(separator: "/", omittingEmptySubsequences: false)
            // `rgba:` says a fourth thing this cannot show — nothing here is
            // translucent — and it is dropped rather than refused, so a
            // program that names its colours that way still gets them.
            if parts.count == 4 { parts.removeLast() }
        } else {
            return nil
        }
        guard parts.count == 3 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 4, let value = UInt32(part, radix: 16) else { return nil }
            let most = (1 << (4 * part.count)) - 1
            bytes.append(UInt8((value * 255 + UInt32(most / 2)) / UInt32(most)))
        }
        return (bytes[0], bytes[1], bytes[2])
    }

    // MARK: After ESC

    private func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case 0x5B: // [
            params = []
            colons = []
            param = 0
            empty = true
            marker = nil
            inter = nil
            state = .csi
        case 0x5D: // ]
            payload = []
            state = .osc
        case 0x50, 0x58, 0x5E, 0x5F: // P X ^ _
            state = .skip
        case 0x28, 0x29, 0x2A, 0x2B, 0x23: // ( ) * + #
            state = .slot(Character(UnicodeScalar(byte)))
        case 0x6E: graphic = 2                // n: LS2, the set G2 holds
        case 0x6F: graphic = 3                // o: LS3
        case 0x37: screen.saveCursor()        // 7
        case 0x38: screen.restoreCursor()     // 8
        case 0x44: screen.lineFeed()          // D
        case 0x45:                              // E
            screen.carriageReturn()
            screen.lineFeed()
        case 0x4D: screen.reverseFeed()        // M
        case 0x48: screen.setTabStop()         // H
        case 0x63: screen.reset()              // c
        case 0x3D: screen.applicationKeypad = true   // =
        case 0x3E: screen.applicationKeypad = false  // >
        case 0x5A: reply?("\u{1b}[?62;22c")   // Z
        default:
            swallowed += 1
        }
    }

    /// The single character after ESC ( or ) or #: which character set, or
    /// the screen filled with E for the alignment test.
    private func slot(_ byte: UInt8, what: Character) {
        state = .ground
        let char = Character(UnicodeScalar(byte))
        switch what {
        case "(":
            g0 = char == "0"
        case ")":
            g1 = char == "0"
        case "*":
            g2 = char == "0"
        case "+":
            g3 = char == "0"
        case "#":
            if char == "8" { screen.fillPattern() }
        default:
            break
        }
    }

    // MARK: CSI

    private func sequence(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            state = .esc
        case 0x18, 0x1A:
            state = .ground
        case 0x00...0x1F:
            // The controls run inside a control sequence too; the sequence
            // goes on afterwards, none the wiser.
            execute(byte)
        case 0x30...0x39: // 0-9
            param = param * 10 + Int(byte - 0x30)
            empty = false
        case 0x3B, 0x3A: // ; :
            // A colon is a sub-parameter's semicolon (SGR speaks them),
            // and it marks the parameter it ends nothing but the one
            // place it was spoken — see `colons`.
            if byte == 0x3A { colons.insert(params.count) }
            params.append(empty ? -1 : min(param, 999_999))
            param = 0
            empty = true
        case 0x3C...0x3F: // < = > ?
            if params.isEmpty, param == 0, empty, marker == nil, inter == nil {
                marker = Character(UnicodeScalar(byte))
            } else {
                swallowed += 1
            }
        case 0x20...0x2F: // space through /
            inter = Character(UnicodeScalar(byte))
        case 0x40...0x7E:
            // The final byte lands with the last parameter still in hand —
            // a lone parameter never meets a semicolon on its way.
            params.append(empty ? -1 : min(param, 999_999))
            state = .ground
            run(Character(UnicodeScalar(byte)))
        default:
            break
        }
    }

    /// The parameter at this place, or the default when the sequence
    /// didn't bring one. Every count in these sequences is from one,
    /// and every parameter missing is its default.
    private func n(_ place: Int, _ alone: Int) -> Int {
        // A parameter under the default is not nothing — the default is
        // for the missing, not a floor for the given.
        place < params.count && params[place] > 0 ? params[place] : alone
    }

    /// The first sub-parameter of the parameter at this place, if the
    /// sequence spoke one with a colon. SGR's sub-parameters carry a
    /// parameter's style, not another parameter: 4:3 is "underlined,
    /// and the style of it is curly", so a colon cannot be the semicolon
    /// it reads as in the counting sequences. The colon is kept as a mark
    /// on the parameter that follows it, which is the only place it
    /// differs from one — the two forms never mix in one number, so a
    /// program that says 4:3 says it alone, and one that says 38;5;n says
    /// no colon anywhere.
    private func colon(_ place: Int) -> Int? {
        let next = place + 1
        guard colons.contains(place), next < params.count, params[next] > 0 else { return nil }
        return params[next]
    }

    private func run(_ final: Character) {
        // The ones with an intermediate byte: the cursor's style and shape,
        // and the mode question a program asks before it dares to set one.
        if let inter {
            switch (inter, final) {
            case ("$", "p"):
                // DECRQM: is this mode set? Asked with `?` for the private
                // modes and without for the ANSI ones, answered in the same
                // form — and answered for the ones this terminal has not
                // got too, with a zero, which is what makes the question
                // worth asking at all.
                for what in params where what >= 0 { answer(what, private: marker == "?") }
            case ("$", "y"):
                break               // DECRPM: an answer, never a question we asked
            case (_, "m"):
                break               // the cursor's style or shape, kept by the screen
            default:
                swallowed += 1
            }
            return
        }
        switch final {
        case "A": screen.moveUp(n(0, 1))
        case "B": screen.moveDown(n(0, 1))
        case "C": screen.moveForward(n(0, 1))
        case "D": screen.moveBack(n(0, 1))
        case "E": // the next line: down, and back to the first column
            screen.moveDown(n(0, 1))
            screen.carriageReturn()
        case "F": // the line above, the same way
            screen.moveUp(n(0, 1))
            screen.carriageReturn()
        case "G", "`": screen.move(to: n(0, 1) - 1, row: screen.y)
        case "d": screen.move(to: screen.x, row: n(0, 1) - 1)
        case "H", "f": screen.move(to: n(1, 1) - 1, row: n(0, 1) - 1)
        case "J": screen.eraseDisplay(n(0, 0))
        case "K": screen.eraseRow(n(0, 0))
        case "L": screen.insertRows(n(0, 1))
        case "M": screen.deleteRows(n(0, 1))
        case "@": screen.insertChars(n(0, 1))
        case "P": screen.deleteChars(n(0, 1))
        case "X": screen.eraseChars(n(0, 1))
        case "S": screen.scrollUp(n(0, 1))
        case "T": screen.scrollDown(n(0, 1))
        case "r": screen.setRegion(top: n(0, 1) - 1, bottom: n(1, screen.height) - 1)
        case "s":
            if marker == nil { screen.saveCursor() } else { swallowed += 1 }
        case "u":
            // `CSI u` gives the cursor back; `CSI ? u` is a program asking
            // about a keyboard protocol this terminal does not have, and
            // answering nothing at all is how it finds that out — a
            // program that gets an answer believes it.
            if marker == nil { screen.restoreCursor() } else { swallowed += 1 }
        case "g":
            // TBC: 0 the stop at the cursor, 3 every one there is.
            switch n(0, 0) {
            case 0: screen.clearTabStop(at: screen.x)
            case 3: screen.clearTabStops()
            default: break
            }
        case "b": // REP: the last character again, this many times
            if let last {
                for _ in 0..<n(0, 1) { screen.put(last.char, wide: last.wide) }
            }
        case "m":
            if marker == "?" { swallowed += 1 } else { style() }
        case "h", "l":
            // DECSET and DECRST when the marker says private; the modes
            // without it are few (IRM, and LNM, which the screen holds as
            // the wraparound every terminal has).
            if marker == "?" { modes(final == "h") }
            else if params.first == 4 { screen.insert = final == "h" }
        case "n":
            if params.first == 5 { reply?("\u{1b}[0n") }
            if params.first == 6 { reply?("\u{1b}[\(screen.y + 1);\(screen.x + 1)R") }
        case "c":
            // What the terminal is, when asked. An xterm of the age every
            // program alive already knows how to talk to.
            if marker == ">" { swallowed += 1 } else { reply?("\u{1b}[?62;22c") }
        default:
            swallowed += 1
        }
    }

    /// DECRQM's answer, for one mode: the number, then whether it is set.
    /// One is set, two is not, and zero is a mode this terminal has never
    /// heard of — the three answers xterm gives, and the only ones a
    /// program that asks can do anything with. The private modes are
    /// answered in the private form, the ANSI ones in the plain.
    private func answer(_ what: Int, private isPrivate: Bool) {
        let state: Int
        if isPrivate {
            switch what {
            case 1: state = screen.applicationCursor ? 1 : 2
            case 5: state = screen.reverseVideo ? 1 : 2
            case 6: state = screen.origin ? 1 : 2
            case 7: state = screen.wraparound ? 1 : 2
            case 25: state = screen.visible ? 1 : 2
            case 47, 1047, 1048, 1049: state = screen.alternate ? 1 : 2
            case 1000, 1002, 1003: state = screen.mouse.mode == what ? 1 : 2
            case 1004: state = screen.focusReporting ? 1 : 2
            case 1006, 1015, 1016: state = screen.mouseFormat.mode == what ? 1 : 2
            case 2004: state = screen.bracketedPaste ? 1 : 2
            case 2026: state = screen.syncOutput ? 1 : 2
            default: state = 0
            }
        } else {
            switch what {
            case 4: state = screen.insert ? 1 : 2
            default: state = 0
            }
        }
        reply?("\u{1b}[\(isPrivate ? "?" : "")\(what);\(state)$y")
    }

    // MARK: SGR

    /// The pen: what the next characters are written with. Nothing is
    /// ever reset by parts — 0 puts the whole pen back, and the colors
    /// name their places (30–37 the foreground's eight, 90–97 their bright
    /// ones, 38 with 5 or 2 whichever of the 256 or the thousands, and the
    /// forties the same for the back).
    private func style() {
        var ink = screen.ink
        var place = 0
        while place < params.count {
            let what = params[place] < 0 ? 0 : params[place]
            switch what {
            case 0: ink = .plain
            case 1: ink.bold = true
            case 2: ink.faint = true
            case 3: ink.italic = true
            case 4:
                // 4:style — the style of the line, spoken as a
                // sub-parameter. 3 is curly, the one style that carries a
                // different weight on screen; 4 is dotted, 5 dashed, and
                // neither of them is drawn apart from the straight one —
                // but both answer for themselves (see DECRQM's cousin in
                // Ink.curl), because a program that asks what it set is
                // owed the truth, not the screen's shorthand for it.
                ink.underline = true
                ink.curl = colon(place) == 3
            case 5: ink.blink = true
            case 7: ink.inverse = true
            case 8: ink.hidden = true
            case 9: ink.strike = true
            case 21: ink.underline = true; ink.curl = false
            case 22: ink.bold = false; ink.faint = false
            case 23: ink.italic = false
            case 24: ink.underline = false; ink.curl = false
            case 25: ink.blink = false
            case 27: ink.inverse = false
            case 28: ink.hidden = false
            case 29: ink.strike = false
            case 30...37: ink.foreground = .ansi(UInt8(what - 30))
            case 39: ink.foreground = .plain
            case 40...47: ink.background = .ansi(UInt8(what - 40))
            case 49: ink.background = .plain
            case 90...97: ink.foreground = .ansi(UInt8(what - 90 + 8))
            case 100...107: ink.background = .ansi(UInt8(what - 100 + 8))
            case 38, 48, 58:
                // 38;5;n the 256, 38;2;r;g;b the color itself, and 58 — the
                // same two forms — the color of the line under the words,
                // which without one is the ink of the words it runs under.
                let count = place + 2 < params.count ? params[place + 1] : -1
                if count == 5, place + 3 <= params.count, params[place + 2] >= 0 {
                    let paint = Paint.ansi(UInt8(params[place + 2]))
                    if what == 38 { ink.foreground = paint }
                    else if what == 48 { ink.background = paint }
                    else { ink.line = paint }
                    place += 2
                } else if count == 2, place + 5 <= params.count,
                          params[place + 2] >= 0, params[place + 3] >= 0, params[place + 4] >= 0 {
                    let paint = Paint.rgb(UInt8(params[place + 2]),
                                          UInt8(min(params[place + 3], 255)),
                                          UInt8(min(params[place + 4], 255)))
                    if what == 38 { ink.foreground = paint }
                    else if what == 48 { ink.background = paint }
                    else { ink.line = paint }
                    place += 4
                } else {
                    place = params.count
                }
            case 59: ink.line = .plain
            default: break
            }
            place += 1
        }
        screen.ink = ink
    }

    // MARK: The private modes

    /// DECSET and DECRST, one parameter at a time. The ones that matter
    /// to the screen go to it; the rest are counted and swallowed.
    private func modes(_ on: Bool) {
        for what in params where what >= 0 {
            switch what {
            case 1: screen.applicationCursor = on
            case 3: // DECCOLM, without the column count it once meant
                if on {
                    screen.eraseDisplay(2)
                    screen.move(to: 0, row: 0)
                }
            case 5: screen.reverseVideo = on
            case 6:
                screen.origin = on
                screen.move(to: 0, row: on ? screen.top : 0)
            case 7: screen.wraparound = on
            case 25: screen.visible = on
            case 47, 1047:
                // 47 leaves the cursor alone; 1047 erases the alternate on
                // the way back — a courtesy the difference of which no
                // program has ever taken.
                on ? screen.enterAlternate() : screen.exitAlternate()
            case 1048: on ? screen.saveCursor() : screen.restoreCursor()
            case 1049:
                // The one everything uses: the cursor kept on the way in,
                // given back on the way out.
                if on {
                    screen.saveCursor()
                    screen.enterAlternate()
                } else {
                    screen.exitAlternate()
                    screen.restoreCursor()
                }
            case 1000, 1002, 1003: screen.mouse = on ? MouseMode(mode: what) ?? .off : .off
            case 1004: screen.focusReporting = on
            // The three encodings, each replacing the one before it: a
            // program that wants SGR and then asks for pixels has not
            // asked for two encodings, it has changed its mind about one.
            case 1006, 1015, 1016: screen.mouseFormat = on ? MouseReport.Format(mode: what) ?? .legacy : .legacy
            case 2004: screen.bracketedPaste = on
            case 2026: screen.syncOutput = on
            default: swallowed += 1
            }
        }
    }

    // MARK: OSC

    private func operating(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL, the ending half the shells still use
            state = .ground
            sayOperating(payload)
        case 0x1B:
            state = .oscEsc
        case 0x18, 0x1A:
            state = .ground
        default:
            payload.append(byte)
        }
    }

    /// An OSC payload, taken apart by what its number says it is. The
    /// ones this doesn't know — hyperlinks, the clipboard, everything a
    /// single terminal invented and the world half-joined — are counted
    /// and swallowed.
    private func sayOperating(_ payload: [UInt8]) {
        guard let text = String(bytes: payload, encoding: .utf8) else { return }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let number = Int(parts.first ?? "") else {
            swallowed += 1
            return
        }
        switch number {
        case 0, 2:
            guard parts.count > 1 else { break }
            say?(.title(parts[1]))
        case 7:
            // file://host/path — the host dropped, the path the shell's.
            guard parts.count > 1, parts[1].hasPrefix("file://") else { break }
            let rest = parts[1].dropFirst("file://".count).drop { $0 != "/" }
            if let path = String(rest).removingPercentEncoding, path.hasPrefix("/") {
                say?(.cwd(URL(fileURLWithPath: path)))
            }
        case 8:
            // 8;params;address — everything written from here on belongs
            // to that address, until a program ends it by leaving the
            // address empty. The params hold an id, for a link split over
            // several runs; it is not kept, because a click already knows
            // two runs are one link by their being the same address, and
            // nothing else here reads it.
            guard parts.count > 2 else { break }
            screen.link(parts[2...].joined(separator: ";"))
        case 9:
            // 9;body, or 9;title;body.
            guard parts.count > 1 else { break }
            if parts.count > 2 {
                say?(.note(title: parts[1], body: parts[2...].joined(separator: ";")))
            } else {
                say?(.note(title: "Terminal", body: parts[1]))
            }
        case 777:
            // 777;notify;title;body — the one iTerm took from rxvt.
            guard parts.count > 3 else { break }
            say?(.note(title: parts[2], body: parts[3...].joined(separator: ";")))
        case 12:
            // 12;spec — the colour of the caret. A program that sets one
            // has a reason: vim paints the caret to say which mode it is
            // in, and this is the only way it can say it.
            guard parts.count > 1, let named = Parser.colour(parts[1]) else { break }
            screen.cursorInk = .rgb(named.red, named.green, named.blue)
        case 112:
            screen.cursorInk = .plain
        case 52:
            // 52;selection;payload — the clipboard, with the payload
            // base64 because an escape sequence has no room for arbitrary
            // bytes. A payload of "?" is the program asking to read it
            // back, and it is answered with an empty selection rather than
            // with what is on the clipboard: a program that can read the
            // clipboard can read whatever was last copied into it from
            // anywhere on the machine, which is not something a program
            // gets to do by printing an escape sequence.
            guard parts.count > 2 else { break }
            let payload = parts[2...].joined(separator: ";")
            guard payload != "?" else {
                reply?("\u{1b}]52;\(parts[1]);\u{07}")
                return
            }
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
                  let text = String(data: data, encoding: .utf8)
            else {
                swallowed += 1
                return
            }
            copied?(text)
        case 133:
            // The shell's own marks (A a prompt, B the prompt's end, C the
            // command running, D done, with the exit when it says one).
            guard parts.count > 1 else { break }
            switch parts[1] {
            case "A": screen.markPrompt()
            case "B": break
            case "C": screen.markCommand()
            case "D": screen.markEnd(exit: parts.count > 2 ? Int32(parts[2]) : nil)
            default: break
            }
        case 7784:
            // The input dock's own report (see TerminalShell, where the
            // script that prints it lives, and TerminalDock, where it is
            // answered). `buf;<cursor>;<text>;<suggestion>` — the text and
            // the suggestion escaped, because a semicolon would end the
            // field they sit in — or `off`, when the line grew past what a
            // mirror can hold and the grid takes the input back. The parts
            // past the text are joined back the way they came, which cannot
            // happen (the script escapes its semicolons) but costs nothing
            // to promise.
            guard parts.count > 1 else { break }
            if parts[1] == "off" {
                say?(.dock(.off))
                break
            }
            guard parts.count > 3 else { break }
            say?(.dock(.line(
                text: Parser.docked(parts[3]),
                cursor: Int(parts[2]) ?? 0,
                suggestion: Parser.docked(
                    parts.count > 4 ? parts[4...].joined(separator: ";") : ""
                )
            )))
        default:
            swallowed += 1
        }
    }
}
