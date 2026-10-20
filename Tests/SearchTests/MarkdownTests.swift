import SwiftUI
import XCTest
@testable import Search

// The agent's answer in markdown, split to its blocks and read to its
// inline marks (see Markdown.swift): the blocks the model writes — a
// heading, a list, a code block, paragraphs — each named for what it
// is, and the marks inside a paragraph — bold, italic, code, links —
// parsed by the system's own reader, not by hand.

@MainActor
final class MarkdownTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "markdown-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - the blocks

    func testParagraphsSplitOnBlankLines() {
        let blocks = markdownBlocks(of: "One paragraph\nover two lines.\n\nAnother.")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].words, "One paragraph\nover two lines.")
        XCTAssertEqual(blocks[1].words, "Another.")
    }

    func testHeadingsAreNamedAndLevelled() {
        let blocks = markdownBlocks(of: "# A title\n\n## A smaller one\n\nWords.")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(blocks[0].words, "A title")
        XCTAssertEqual(blocks[1].kind, .heading(level: 2))
        XCTAssertEqual(blocks[1].words, "A smaller one")
        XCTAssertEqual(blocks[2].kind, .paragraph)
    }

    func testBulletsSplitToItems() {
        let blocks = markdownBlocks(of: "A list:\n\n- one\n- two\n\n* a star\n\n1. a number\n2. another")
        let kinds = blocks.map(\.kind)
        XCTAssertEqual(kinds, [.paragraph, .bullet, .bullet, .bullet, .bullet, .bullet])
        XCTAssertEqual(blocks[1].words, "one")
        XCTAssertEqual(blocks[3].words, "a star")
        XCTAssertEqual(blocks[4].words, "a number")
    }

    func testCodeBlockKeepsItsWordsWhole() {
        // A code block holds its own words: nothing inside it is read as
        // a mark — a fence inside a fence stays, a heading stays.
        let text = """
        Before.

        ```swift
        func greet() -> String {
            return "hi"   // **not bold**
        }
        ```

        After.
        """
        let blocks = markdownBlocks(of: text)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .paragraph)
        XCTAssertEqual(blocks[1].kind, .code(language: "swift"))
        XCTAssertEqual(blocks[1].words, "func greet() -> String {\n    return \"hi\"   // **not bold**\n}")
        XCTAssertEqual(blocks[2].kind, .paragraph)
    }

    func testCodeBlockOpenToTheEndStillShows() {
        // An answer that stops mid-code still shows the words it held.
        let blocks = markdownBlocks(of: "Intro:\n\n```\nlet a = 1")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1].kind, .code(language: nil))
        XCTAssertEqual(blocks[1].words, "let a = 1")
    }

    func testIndentedCodeBlocksWithoutFenceStayParagraphs() {
        // Four spaces of indent is a fenced block in books, but models
        // indent for plain reasons too: shown as a paragraph, not a
        // code block.
        let blocks = markdownBlocks(of: "    just an indented line")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    // MARK: - the inline marks

    func testBoldIsSemiBold() throws {
        let read = markdownInline("plain **bold** plain", size: 13)
        var sawBold = false
        for run in read.runs {
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                sawBold = true
                // A bold run takes the app's semibold, not the system's
                // own choice of face (see markdownInline).
                let words = String(read[run.range].characters)
                XCTAssertEqual(words, "bold")
                XCTAssertNotNil(run.font)
            }
        }
        XCTAssertTrue(sawBold, "the bold run was not found in: \(read)")
    }

    func testCodeIsMono() {
        let read = markdownInline("the `code` word", size: 13)
        var sawMono = false
        for run in read.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                sawMono = true
                let words = String(read[run.range].characters)
                XCTAssertEqual(words, "code")
            }
        }
        XCTAssertTrue(sawMono, "the code run was not found in: \(read)")
    }

    func testLinkIsUnderlinedInk() {
        let read = markdownInline("see [the docs](https://example.com) now", size: 13)
        var sawLink = false
        for run in read.runs {
            if let link = run.link {
                sawLink = true
                XCTAssertEqual(link.absoluteString, "https://example.com")
                XCTAssertEqual(run.underlineStyle, .single)
            }
        }
        XCTAssertTrue(sawLink, "the link run was not found in: \(read)")
    }

    func testUnparseableParagraphShowsAsWritten() {
        // A paragraph the reader declines is not lost: shown as written.
        let read = markdownInline("just words, no marks", size: 13)
        XCTAssertEqual(String(read.characters), "just words, no marks")
    }

    // MARK: - the view holds it all

    func testTheViewDrawsEveryKindOfBlock() throws {
        let text = """
        # The answer

        A **bold** point and [a link](https://example.com).

        - first
        - second

        ```js
        console.log("hi")
        ```
        """
        let view = MarkdownText(open: { _ in }, text: text, size: 13)
        let host = NSHostingView(rootView: view)
        host.layout()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
