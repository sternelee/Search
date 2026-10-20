import SwiftUI
import AppKit

// The agent's answer, drawn as the model wrote it. The model speaks
// markdown — headings, lists, code blocks, bold, links — and the
// answer held to one plain paragraph was a page of hashes and stars
// to read through. Here the words are read the way they were written:
// blocks first (a heading, a list, a code block, a paragraph), then
// the inline marks the system itself knows how to read — bold,
// italic, code, links — parsed by Foundation, not by hand, so the
// model's own dialect is the one shown.
//
// What is never rendered: a link followed without a look. A tap on
// one is a tap on any link in the browser — it opens the way the
// page's own links open, through Browser.open, never through the
// model's words alone (see MarkdownText.link).

// MARK: - the blocks

/// What a run of the answer is: one paragraph, one heading, one list
/// (its items kept whole — nested bullets are the model's own words,
/// shown as written), one code block.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case bullet
        case code(language: String?)
    }

    let id = UUID()
    let kind: Kind
    /// The block's own words: the paragraph without its blank lines,
    /// the heading without its hashes, the bullet without its dash,
    /// the code block exactly as written, fences and all.
    let words: String
}

/// The answer in blocks: split on the blank lines, then each block
/// named by how it opens. A code block is kept whole — the words
/// inside it are the point of it, hashes and stars included — and
/// a list is split to its items, each a block of its own.
func markdownBlocks(of text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var code: (language: String?, lines: [String])? = nil
    var paragraph: [String] = []

    func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(MarkdownBlock(kind: .paragraph, words: paragraph.joined(separator: "\n")))
        paragraph = []
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A fence opens and closes a code block; what's between is
        // kept as written, and nothing inside it is read as marks.
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            if let open = code {
                blocks.append(MarkdownBlock(kind: .code(language: open.language),
                                            words: open.lines.joined(separator: "\n")))
                code = nil
            } else {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
            }
            continue
        }
        if code != nil {
            code!.lines.append(line)
            continue
        }
        // A list item is a line of its own; a blank line ends the
        // paragraph in the making.
        if trimmed.isEmpty {
            flushParagraph()
            continue
        }
        if isBullet(trimmed) {
            flushParagraph()
            blocks.append(MarkdownBlock(kind: .bullet, words: unbullet(trimmed)))
            continue
        }
        // A heading: one to six hashes and a space.
        if let heading = headingLevel(of: trimmed) {
            flushParagraph()
            blocks.append(MarkdownBlock(kind: .heading(level: heading.level),
                                        words: heading.words))
            continue
        }
        paragraph.append(line)
    }
    // A code block left open by an answer that stopped short is
    // still shown — the words it held are the words that came.
    if let open = code {
        blocks.append(MarkdownBlock(kind: .code(language: open.language),
                                    words: open.lines.joined(separator: "\n")))
    }
    flushParagraph()
    return blocks
}

/// A bullet, the model's way: a dash, a star, or a number with a dot.
private func isBullet(_ line: String) -> Bool {
    let patterns = ["- ", "* ", "+ "]
    for pattern in patterns where line.hasPrefix(pattern) { return true }
    let digits = line.prefix { $0.isNumber }
    return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ")
}

/// The words under the bullet's mark: the dash or the number, off.
private func unbullet(_ line: String) -> String {
    for pattern in ["- ", "* ", "+ "] where line.hasPrefix(pattern) {
        return String(line.dropFirst(pattern.count))
    }
    let digits = line.prefix { $0.isNumber }
    return String(line.dropFirst(digits.count + 2))
}

/// A heading's level and its words: the hashes, off.
private func headingLevel(of line: String) -> (level: Int, words: String)? {
    guard line.hasPrefix("#") else { return nil }
    let hashes = line.prefix { $0 == "#" }
    let level = hashes.count
    guard level >= 1, level <= 6 else { return nil }
    let rest = String(line.dropFirst(level))
    guard rest.hasPrefix(" ") else { return nil }
    return (level, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
}

// MARK: - the inline marks

/// One paragraph's words with its inline marks read: Foundation's own
/// parser is handed the paragraph, its results left with this app's
/// font and colors — a link underlined as a link is anywhere here,
/// code in the mono face, bold and italic as written.
///
/// Failure of the read is not the end of the words: a paragraph the
/// parser declines is shown exactly as written (see try? below —
/// the base style stands in).
func markdownInline(_ text: String, size: CGFloat, weight: Font.Weight = .regular,
                    color: Color = Palette.ink) -> AttributedString {
    let plain = attributed(font: .system(size: size, weight: weight), color: color)
    guard var read = try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    ) else { return plain(text) }
    // Every run takes the app's own style; the model's marks are
    // which words are emphasized, not how — bold is semibold, italic
    // keeps its lean, code goes mono, a link is underlined ink.
    for run in read.runs {
        let range = run.range
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.code) {
            read[range].font = .system(size: size * 0.94, weight: weight, design: .monospaced)
        } else if intent.contains(.stronglyEmphasized) {
            read[range].font = .system(size: size, weight: .semibold)
        } else {
            read[range].font = .system(size: size, weight: weight)
        }
        read[range].foregroundColor = color
        if run.link != nil {
            read[range].underlineStyle = .single
            read[range].foregroundColor = Palette.ink
        }
    }
    return read
}

/// The paragraph, plain: for the parser's failure, and for code
/// blocks, whose words are shown as written.
func attributed(font: Font, color: Color) -> (String) -> AttributedString {
    { text in
        var line = AttributedString(text)
        line.font = font
        line.foregroundColor = color
        return line
    }
}

// MARK: - the view

/// The agent's answer, shown: blocks stacked, each drawn its own
/// way — a heading heavier, a list item with its bullet, a code
/// block in the mono face on a wash of its own, a paragraph as
/// paragraphs are. A link's tap opens it the browser's way.
struct MarkdownText: View {
    /// What a tapped link does: the browser's own open, passed in by
    /// the panel or the tab that holds this answer.
    let open: (URL) -> Void
    let text: String
    var size: CGFloat = 13
    var color: Color = Palette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let blocks = markdownBlocks(of: text)
            if blocks.isEmpty {
                Text(attributedText(""))
            }
            ForEach(blocks) { block in
                switch block.kind {
                case .paragraph:
                    Text(markdownInline(block.words, size: size, color: color))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in openLink(url) })
                case .heading(let level):
                    Text(markdownInline(block.words,
                                        size: size + CGFloat(max(0, 6 - level)) * 0.5,
                                        weight: level <= 2 ? .semibold : .medium,
                                        color: color))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in openLink(url) })
                case .bullet:
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.system(size: size)).foregroundStyle(Palette.faint)
                        Text(markdownInline(block.words, size: size, color: color))
                            .fixedSize(horizontal: false, vertical: true)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in openLink(url) })
                    }
                case .code:
                    // A code block: as written, in the mono face, on a
                    // wash of its own — no marks read inside it.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(block.words)
                            .font(.system(size: size * 0.94, design: .monospaced))
                            .foregroundStyle(color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(10)
                    .background(Palette.wash.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    /// The link, opened the browser's way — never by the words alone.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        open(url)
        return .handled
    }

    private func attributedText(_ words: String) -> AttributedString {
        attributed(font: .system(size: size), color: color)(words)
    }
}
