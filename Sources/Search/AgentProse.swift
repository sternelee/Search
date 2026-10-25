import AppKit

// Markdown, as much of it as an agent's answers actually use.
//
// A coding agent writes prose: a heading to say what it is about to do, a
// numbered plan, a fenced block of the code it is about to change, a quote
// of your own words back at you, and the odd `inline code`. Drawn as one
// flat paragraph, all of that is noise — the structure is the part a
// person scans for. So an answer is parsed into blocks the way orbit-pi
// parses it, and each block is drawn as what it is.
//
// There is no dependency here and there will not be one: this is a
// line-by-line set of rules, a few hundred lines, against a document
// format whose whole promise is that plain text still reads. Tables and
// images are deliberately absent — an agent's answer is not a web page,
// and neither is worth the code.
//
// The parse is pure and can be read on its own; only the faces come from
// the terminal's own look, which is why the type is main-actor bound like
// everything else that draws.
@MainActor
enum Prose {
    // MARK: - the parse

    /// One line of a list: how deep it sits, what marks it, and what it
    /// says. The marker is kept as text rather than as a style because a
    /// numbered list's numbers are part of what was written.
    struct Item: Equatable {
        var depth: Int
        var marker: String
        var text: String
    }

    enum Block: Equatable {
        case para(String)
        case head(Int, String)
        case code(String?, [String])
        case list([Item])
        case quote([String])
        case rule

        /// What the block is, for a test or a log.
        var kind: String {
            switch self {
            case .para: return "para"
            case .head(let level, _): return "h\(level)"
            case .code: return "code"
            case .list: return "list"
            case .quote: return "quote"
            case .rule: return "rule"
            }
        }
    }

    /// The text of an answer, cut into blocks.
    ///
    /// The rules are the ones a person already knows, applied a line at a
    /// time: a fence swallows everything to its partner verbatim, a blank
    /// line ends a paragraph, and consecutive list items are one list. A
    /// line that is just more words is a soft wrap, so it joins the
    /// paragraph above it — markdown's own promise that a hard-wrapped
    /// paragraph is still one paragraph.
    static func blocks(_ text: String) -> [Block] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        var items: [Item] = []

        func flushPara() {
            guard !para.isEmpty else { return }
            out.append(.para(para.joined(separator: " ")))
            para = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            out.append(.quote(quote))
            quote = []
        }
        func flushList() {
            guard !items.isEmpty else { return }
            out.append(.list(items))
            items = []
        }
        func flushAll() {
            flushPara()
            flushQuote()
            flushList()
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]

            // A fence swallows everything to its partner, verbatim: no
            // inline marks, no list rules, nothing but the lines.
            if let language = fence(raw) {
                flushAll()
                var body: [String] = []
                i += 1
                while i < lines.count, fence(lines[i]) == nil {
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }  // the closing fence
                out.append(.code(language.isEmpty ? nil : language, body))
                continue
            }

            let bare = raw.trimmingCharacters(in: .whitespaces)

            if bare.isEmpty {
                flushAll()
                i += 1
                continue
            }

            if let (level, words) = heading(bare) {
                flushAll()
                out.append(.head(level, words))
                i += 1
                continue
            }

            if isRule(bare) {
                flushAll()
                out.append(.rule)
                i += 1
                continue
            }

            if let said = quoted(bare) {
                flushPara()
                flushList()
                quote.append(said)
                i += 1
                continue
            }

            if let item = listed(raw) {
                flushPara()
                flushQuote()
                // A bullet and a number are two lists. A change of kind is
                // a change of list, and the picture should say so.
                if let last = items.last, (last.marker == "•") != (item.marker == "•") {
                    flushList()
                }
                items.append(item)
                i += 1
                continue
            }

            // A plain line, indented further than the item above it, is
            // that item still talking — markdown's lazy continuation.
            if !items.isEmpty, let last = items.last, indent(of: raw) > 0, para.isEmpty {
                var grown = items
                grown[grown.count - 1].text = last.text + " " + bare
                items = grown
                i += 1
                continue
            }

            flushQuote()
            flushList()
            para.append(bare)
            i += 1
        }
        flushAll()
        return out
    }

    /// The language of a fence, `""` when it has none, nil when the line is
    /// not a fence at all. Both ``` and ~~~ count, three or more.
    static func fence(_ raw: String) -> String? {
        let bare = raw.trimmingCharacters(in: .whitespaces)
        for mark in ["```", "~~~"] where bare.hasPrefix(mark) {
            var count = 0
            for c in bare { if String(c) == String(mark.first!) { count += 1 } else { break } }
            guard count >= 3 else { continue }
            let rest = bare.dropFirst(count).trimmingCharacters(in: .whitespaces)
            return rest.components(separatedBy: " ").first ?? ""
        }
        return nil
    }

    private static func heading(_ bare: String) -> (Int, String)? {
        var level = 0
        var rest = Substring(bare)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " || rest.isEmpty else { return nil }
        var words = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of hashes is decoration, not content.
        while words.hasSuffix("#") { words = String(words.dropLast()) }
        return (level, words.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ bare: String) -> Bool {
        let marks = bare.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func quoted(_ bare: String) -> String? {
        guard bare.hasPrefix(">") else { return nil }
        var rest = bare.dropFirst()
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return String(rest)
    }

    private static func indent(of raw: String) -> Int {
        var room = 0
        for c in raw {
            if c == " " { room += 1 } else if c == "\t" { room += 2 } else { break }
        }
        return room
    }

    /// A list item, or nil. The marker is kept: `3.` says where you are in
    /// a plan, and a bullet that was written as `-` is still a bullet.
    private static func listed(_ raw: String) -> Item? {
        let room = indent(of: raw)
        let bare = raw.trimmingCharacters(in: .whitespaces)
        var depth = room / 2
        if depth > 4 { depth = 4 }
        guard let first = bare.first else { return nil }
        if "-*+".contains(first) {
            let rest = bare.dropFirst()
            guard rest.hasPrefix(" ") else { return nil }
            return Item(depth: depth, marker: "•", text: rest.trimmingCharacters(in: .whitespaces))
        }
        // `1.` and `1)` — up to nine digits, then a dot or a paren, then a
        // space. `2026.10.25` is a date, not the tenth item.
        var digits = ""
        var rest = Substring(bare)
        while let c = rest.first, c.isNumber, digits.count < 9 {
            digits.append(c)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let mark = rest.first, mark == "." || mark == ")",
              rest.dropFirst().hasPrefix(" ") else { return nil }
        return Item(depth: depth, marker: digits + ".",
                    text: rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    // MARK: - the inline marks

    /// What a piece of prose is drawn with. Kept as a value so the paper
    /// can hand in its own face and ink and get the same rules back.
    struct Style {
        var face: NSFont
        var base: CGFloat
        /// Full-strength ink. A row that is dimmer than another — a thought,
        /// a quote — dims through `tone`, so every mark inside it stays
        /// proportional instead of jumping back to full brightness.
        var ink: NSColor
        var tone: CGFloat = 1
    }

    private static func ink(_ style: Style, _ alpha: CGFloat) -> NSColor {
        style.ink.withAlphaComponent(style.tone * alpha)
    }

    /// One block, ready to draw: its words with the inline marks applied,
    /// how tall it is at the width it was measured for, and the room it
    /// asks for around itself.
    struct Piece {
        var block: Block
        var text: NSAttributedString
        var height: CGFloat
        var before: CGFloat
        var inset: CGFloat
        /// A ground behind the whole row, and a hairline down its left.
        var band = false
        var bar = false
    }

    /// Blocks laid out against a width: the answer, as rows.
    ///
    /// Height comes from the attributed words themselves rather than from
    /// a count of lines, because a wrapped paragraph is one block of many
    /// lines and a list item that wraps must hang under its own words.
    static func pieces(_ blocks: [Block], width: CGFloat, style: Style) -> [Piece] {
        var out: [Piece] = []
        for (n, block) in blocks.enumerated() {
            var piece = Piece(block: block, text: NSAttributedString(string: ""),
                              height: 0, before: 0, inset: 0)
            let first = n == 0
            switch block {
            case .para(let words):
                piece.text = runs(words, style, para: hang(0, 0))
                piece.before = first ? 0 : 6

            case .head(let level, let words):
                let size = style.base * headFactor(level)
                piece.text = runs(words, style, size: size, heavy: true, para: hang(0, 0))
                piece.before = first ? 0 : 13
                piece.height += 3

            case .code(_, let lines):
                piece.text = code(lines, style: style)
                piece.before = 6
                piece.inset = 10
                piece.band = true
                piece.bar = true
                piece.height += 8

            case .list(let items):
                piece.text = list(items, style: style)
                piece.before = first ? 0 : 5

            case .quote(let lines):
                piece.text = quoted(lines, style: style)
                piece.before = 6
                piece.inset = 10
                piece.bar = true

            case .rule:
                piece.before = 9
                piece.height = 1
            }

            if case .rule = block {
                out.append(piece)
                continue
            }
            piece.height += measured(piece.text, width: max(20, width - piece.inset),
                                     using: body(style, size: headSize(block, style), heavy: isHeavy(block)))
            out.append(piece)
        }
        return out
    }

    /// How much taller a heading of this level is than the body.
    static func headFactor(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.34
        case 2: return 1.20
        case 3: return 1.10
        default: return 1.0
        }
    }

    private static func headSize(_ block: Block, _ style: Style) -> CGFloat? {
        if case .head(let level, _) = block { return style.base * headFactor(level) }
        return nil
    }

    private static func isHeavy(_ block: Block) -> Bool {
        if case .head = block { return true }
        return false
    }

    /// A paragraph's indent: everything after the first line is pushed in
    /// by `hanging`, so a list item's wrapped lines sit under its words
    /// rather than under its bullet.
    static func hang(_ head: CGFloat, _ hanging: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = head
        style.headIndent = head + hanging
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1
        return style
    }

    private static func measured(_ text: NSAttributedString, width: CGFloat,
                                 using attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return (text.string as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).height
    }

    private static func body(_ style: Style, size: CGFloat? = nil,
                             heavy: Bool = false) -> [NSAttributedString.Key: Any] {
        var face = style.face
        if let size, size != style.face.pointSize {
            face = TerminalLook.face(size: size)
        }
        var traits: [NSAttributedString.Key: Any] = [
            .font: face,
            .foregroundColor: ink(style, 1),
        ]
        if heavy {
            // The terminal's face has no bold of its own and the Mac's bold
            // is a different family — which would break the column. So the
            // glyphs are stroked as well as filled: the same letterforms,
            // a shade heavier.
            traits[.strokeWidth] = -3.5
        }
        return traits
    }

    /// A run of prose with its inline marks turned into attributes and its
    /// markers taken out. One level of nesting, which is all an answer
    /// uses: `**bold with `code`**` is a code span that came out bold.
    static func runs(_ words: String, _ style: Style, size: CGFloat? = nil,
                     heavy: Bool = false, para: NSParagraphStyle? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            out.append(NSAttributedString(string: plain, attributes: body(style, size: size, heavy: heavy)))
            plain = ""
        }

        let chars = Array(words)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            // A backslash escapes the mark after it, so a line that wants a
            // literal `*` can have one.
            if c == "\\", i + 1 < chars.count {
                plain.append(chars[i + 1])
                i += 2
                continue
            }

            if c == "`", let end = index(of: "`", in: chars, from: i + 1) {
                flush()
                let code = String(chars[(i + 1)..<end])
                var traits = body(style, size: size, heavy: heavy)
                traits[.foregroundColor] = ink(style, 0.94)
                traits[.backgroundColor] = ink(style, 0.09)
                out.append(NSAttributedString(string: code, attributes: traits))
                i = end + 1
                continue
            }

            if c == "*" || c == "_" {
                let mark = String(c)
                let doubled = i + 1 < chars.count && chars[i + 1] == c
                let open = doubled ? mark + mark : mark
                // `_` only makes emphasis at a word's edge: `snake_case_name`
                // is a name, not three marks and a stray letter. `*` has no
                // such rule because `a*b` is not a word anybody writes.
                let atEdge = i == 0 || !chars[i - 1].isLetter && !chars[i - 1].isNumber
                if c == "_" && !atEdge {
                    flush()
                    out.append(NSAttributedString(string: mark, attributes: body(style, size: size, heavy: heavy)))
                    i += 1
                    continue
                }
                if let end = index(of: open, in: chars, from: i + open.count), closeIsAtAnEdge(c, chars, end + open.count) {
                    let inner = String(chars[(i + open.count)..<end])
                    flush()
                    if doubled {
                        out.append(runs(inner, style, size: size, heavy: true, para: para))
                    } else {
                        var traits = body(style, size: size, heavy: heavy)
                        traits[.obliqueness] = 0.16
                        out.append(NSAttributedString(string: inner, attributes: traits))
                    }
                    i = end + open.count
                    continue
                }
            }

            if c == "~", i + 1 < chars.count, chars[i + 1] == "~",
               let end = index(of: "~~", in: chars, from: i + 2) {
                flush()
                let inner = String(chars[(i + 2)..<end])
                var traits = body(style, size: size, heavy: heavy)
                traits[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                out.append(NSAttributedString(string: inner, attributes: traits))
                i = end + 2
                continue
            }

            // `![alt](url)` and `[text](url)` are the same thing here: the
            // words a person should read. There is nowhere to go to, and a
            // link that cannot be followed is a lie, so it is only tinted.
            if c == "[", let (label, end) = link(chars, from: i) {
                flush()
                var traits = body(style, size: size, heavy: heavy)
                traits[.foregroundColor] = ink(style, 0.94)
                traits[.underlineStyle] = NSUnderlineStyle.single.rawValue
                traits[.underlineColor] = ink(style, 0.35)
                out.append(NSAttributedString(string: label, attributes: traits))
                i = end
                continue
            }

            if c == "!", i + 1 < chars.count, chars[i + 1] == "[" {
                if let (label, end) = link(chars, from: i + 1) {
                    plain.append(label)
                    i = end
                    continue
                }
            }

            plain.append(c)
            i += 1
        }
        flush()

        if let para {
            out.addAttribute(.paragraphStyle, value: para,
                             range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    private static func index(of mark: String, in chars: [Character], from: Int) -> Int? {
        let needle = Array(mark)
        guard !needle.isEmpty, chars.count >= needle.count else { return nil }
        var i = from
        while i + needle.count <= chars.count {
            if Array(chars[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Whether the mark that closes at `at` is allowed to close there. Only
    /// `_` cares: it must end at a word's edge, or `snake_case_name` would
    /// be a name with two marks inside it.
    private static func closeIsAtAnEdge(_ mark: Character, _ chars: [Character], _ at: Int) -> Bool {
        guard mark == "_" else { return true }
        guard at < chars.count else { return true }
        return !chars[at].isLetter && !chars[at].isNumber
    }

    /// A `[label](url)` starting at `from`, and where it ends.
    private static func link(_ chars: [Character], from: Int) -> (String, Int)? {
        guard chars[from] == "[", let close = index(of: "]", in: chars, from: from + 1),
              close + 1 < chars.count, chars[close + 1] == "(",
              let end = index(of: ")", in: chars, from: close + 2) else { return nil }
        return (String(chars[(from + 1)..<close]), end + 1)
    }

    // MARK: - the blocks that are more than prose

    /// A list, one paragraph per item so each item's wrapped lines hang
    /// under that item's own words.
    private static func list(_ items: [Item], style: Style) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (n, item) in items.enumerated() {
            if n > 0 { out.append(NSAttributedString(string: "\n")) }
            let room = CGFloat(item.depth) * 16
            let marker = item.marker + " "
            let start = out.length
            out.append(runs(marker + item.text, style, para: hang(room, 16)))
            // The bullet takes no ink of its own beyond the prose, but it
            // is not part of what was said either: it is set a shade back.
            out.addAttribute(.foregroundColor, value: ink(style, 0.55),
                             range: NSRange(location: start, length: marker.count))
        }
        return out
    }

    private static func quoted(_ lines: [String], style: Style) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (n, line) in lines.enumerated() {
            if n > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(runs(line, style, para: hang(0, 0)))
            out.addAttribute(.foregroundColor, value: ink(style, 0.62),
                             range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    /// Code: the lines as they were written. Wrapped rather than clipped —
    /// a line that runs off the edge of a terminal is exactly the thing
    /// this view exists to stop doing.
    private static func code(_ lines: [String], style: Style) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (n, line) in lines.enumerated() {
            if n > 0 { out.append(NSAttributedString(string: "\n")) }
            let traits: [NSAttributedString.Key: Any] = [
                .font: style.face,
                .foregroundColor: ink(style, 0.82),
                .paragraphStyle: hang(0, 0),
            ]
            out.append(NSAttributedString(string: line.isEmpty ? " " : line, attributes: traits))
        }
        return out
    }
}
