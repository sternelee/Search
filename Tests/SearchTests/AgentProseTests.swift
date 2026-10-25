import AppKit
import XCTest

@testable import Search

/// Markdown, as far as an agent's answer uses it: the parse, the inline
/// marks, and the fact that the blocks reach the paper as blocks.
@MainActor
final class AgentProseTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private func style() -> Prose.Style {
        Prose.Style(face: TerminalLook.face(size: 12), base: 12, ink: .white)
    }

    // MARK: - the parse

    func testHeadingsParagraphsAndRules() {
        let blocks = Prose.blocks("""
        # The dock

        The plate is drawn from a paced clock, and
        the words wrap where they always did.

        ## Why

        ---
        """)
        XCTAssertEqual(blocks.map(\.kind), ["h1", "para", "h2", "rule"])
        XCTAssertEqual(blocks[0], .head(1, "The dock"))
        XCTAssertEqual(blocks[1], .para("The plate is drawn from a paced clock, and the words wrap where they always did."))
        XCTAssertEqual(blocks[2], .head(2, "Why"))
        XCTAssertEqual(blocks[3], .rule)
    }

    func testAClosingRunOfHashesIsDecoration() {
        XCTAssertEqual(Prose.blocks("## Why ##"), [.head(2, "Why")])
        // No space after the hashes is not a heading at all.
        XCTAssertEqual(Prose.blocks("#nope"), [.para("#nope")])
        XCTAssertEqual(Prose.blocks("####### seven"), [.para("####### seven")])
    }

    func testAFenceSwallowsEverythingVerbatim() {
        let blocks = Prose.blocks("""
        Here is the fix:

        ```swift
        let air = 4 * unit   // **not** markdown
        - and this is not a list
        ```

        Done.
        """)
        XCTAssertEqual(blocks.map(\.kind), ["para", "code", "para"])
        XCTAssertEqual(blocks[1], .code("swift", ["let air = 4 * unit   // **not** markdown",
                                                  "- and this is not a list"]))
        // A fence with no language, and one that never closes.
        XCTAssertEqual(Prose.blocks("```\nplain\n```"), [.code(nil, ["plain"])])
        XCTAssertEqual(Prose.blocks("~~~\nx\n~~~"), [.code(nil, ["x"])])
        XCTAssertEqual(Prose.blocks("```\nunclosed"), [.code(nil, ["unclosed"])])
    }

    func testListsKeepTheirMarkersAndTheirDepth() {
        let blocks = Prose.blocks("""
        Plan:

        - read the dock
          - then the plate
        - run the tests
        1. first
        2) second

        After.
        """)
        XCTAssertEqual(blocks.map(\.kind), ["para", "list", "list", "para"])
        XCTAssertEqual(blocks[1], .list([
            Prose.Item(depth: 0, marker: "•", text: "read the dock"),
            Prose.Item(depth: 1, marker: "•", text: "then the plate"),
            Prose.Item(depth: 0, marker: "•", text: "run the tests"),
        ]))
        XCTAssertEqual(blocks[2], .list([
            Prose.Item(depth: 0, marker: "1.", text: "first"),
            Prose.Item(depth: 0, marker: "2.", text: "second"),
        ]))
    }

    func testALineUnderAnItemIsThatItemStillTalking() {
        let blocks = Prose.blocks("""
        - read the dock,
          which draws from a paced clock
        """)
        XCTAssertEqual(blocks, [.list([
            Prose.Item(depth: 0, marker: "•", text: "read the dock, which draws from a paced clock"),
        ])])
    }

    func testADateIsNotTheTenthItem() {
        XCTAssertEqual(Prose.blocks("2026.10.25 is a date"), [.para("2026.10.25 is a date")])
        XCTAssertEqual(Prose.blocks("10. tenth"), [.list([Prose.Item(depth: 0, marker: "10.", text: "tenth")])])
    }

    func testQuotesAndTheirLines() {
        let blocks = Prose.blocks("""
        > why does the dock flicker?
        > it only flashes once
        """)
        XCTAssertEqual(blocks, [.quote(["why does the dock flicker?", "it only flashes once"])])
    }

    func testAMinusInsideAWordIsNotARule() {
        XCTAssertEqual(Prose.blocks("a - b"), [.para("a - b")])
        XCTAssertEqual(Prose.blocks("--"), [.para("--")])
        XCTAssertEqual(Prose.blocks("- - -"), [.rule])
        XCTAssertEqual(Prose.blocks("***"), [.rule])
    }

    // MARK: - the inline marks

    private func said(_ words: String) -> NSAttributedString {
        Prose.runs(words, style())
    }

    private func traits(_ text: NSAttributedString, at needle: String) -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) is not in \(text.string)")
        return text.attributes(at: range.location, effectiveRange: nil)
    }

    func testTheMarkersComeOutAndTheWordsStay() {
        XCTAssertEqual(said("a **bold** and a `code` and an *aside*").string,
                       "a bold and a code and an aside")
        XCTAssertEqual(said("see [the plan](https://example.com/x) now").string, "see the plan now")
        XCTAssertEqual(said("![a screenshot](/tmp/x.png)").string, "a screenshot")
        XCTAssertEqual(said("~~gone~~").string, "gone")
        // An escaped mark is a mark, not a mark.
        XCTAssertEqual(said(#"a \*literal\* star"#).string, "a *literal* star")
    }

    func testEachMarkBecomesItsOwnTrait() {
        let text = said("plain **heavy** `mono` *slanted* [linked](http://x) ~~struck~~")

        XCTAssertNil(traits(text, at: "plain")[.strokeWidth])
        XCTAssertNotNil(traits(text, at: "heavy")[.strokeWidth], "bold is stroked: the face has no bold of its own")
        XCTAssertNotNil(traits(text, at: "mono")[.backgroundColor])
        XCTAssertNotNil(traits(text, at: "slanted")[.obliqueness])
        XCTAssertNotNil(traits(text, at: "linked")[.underlineStyle])
        XCTAssertNotNil(traits(text, at: "struck")[.strikethroughStyle])

        // And the marks do not leak into the words around them.
        XCTAssertNil(traits(text, at: "plain")[.obliqueness])
        XCTAssertNil(traits(text, at: "linked")[.strikethroughStyle])
    }

    func testBoldAroundCodeIsStillCode() {
        let text = said("**run `swift test` now**")
        XCTAssertEqual(text.string, "run swift test now")
        XCTAssertNotNil(traits(text, at: "swift")[.backgroundColor])
        XCTAssertNotNil(traits(text, at: "swift")[.strokeWidth], "the outer bold still reaches it")
    }

    func testAnUnclosedMarkIsJustCharacters() {
        XCTAssertEqual(said("2 * 3 = 6").string, "2 * 3 = 6")
        XCTAssertEqual(said("a `b").string, "a `b")
        XCTAssertEqual(said("snake_case_name").string, "snake_case_name")
    }

    // MARK: - the blocks, laid out

    func testACodeBlockGetsABandAndABarAndAHeadingGetsHeight() {
        let blocks = Prose.blocks("""
        ## Why

        The plate is drawn from a paced clock.

        ```swift
        let air = 4 * unit
        ```
        """)
        let pieces = Prose.pieces(blocks, width: 400, style: style())
        XCTAssertEqual(pieces.map(\.block.kind), ["h2", "para", "code"])

        let head = pieces[0]
        let para = pieces[1]
        let code = pieces[2]
        XCTAssertGreaterThan(head.height, para.height, "a heading is set bigger than its body")
        XCTAssertTrue(code.band, "code sits on a ground")
        XCTAssertTrue(code.bar)
        XCTAssertEqual(code.inset, 10)
        XCTAssertFalse(para.band)
        XCTAssertGreaterThan(code.height, 0)
        XCTAssertEqual(pieces.map(\.before), [0, 6, 6], "a heading opens a section above itself, and its body follows close")
    }

    func testTheHeightFollowsTheWordsNotTheLineCount() {
        let short = Prose.pieces(Prose.blocks("one line"), width: 400, style: style())
        let long = Prose.pieces(Prose.blocks(String(repeating: "word ", count: 120)), width: 400, style: style())
        XCTAssertGreaterThan(long[0].height, short[0].height * 3, "a paragraph that wraps takes more paper")
    }

    func testAListItemHangsUnderItsOwnWords() {
        let blocks = Prose.blocks("- " + String(repeating: "word ", count: 60))
        let pieces = Prose.pieces(blocks, width: 300, style: style())
        let para = pieces[0].text
        let style = para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent, 0)
        XCTAssertEqual(style?.headIndent, 16, "the wrapped lines sit under the words, not under the bullet")
    }

    func testADeeperItemSitsFurtherIn() {
        let blocks = Prose.blocks("- one\n  - two")
        let pieces = Prose.pieces(blocks, width: 300, style: style())
        let text = pieces[0].text.string as NSString
        let second = text.range(of: "• two")
        let style = pieces[0].text.attribute(.paragraphStyle, at: second.location,
                                            effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent, 16)
        XCTAssertEqual(style?.headIndent, 32)
    }

    // MARK: - on the paper

    private func paper(_ words: String, height: CGFloat = 620) -> TerminalChatPaper {
        var log = ChatLog(agent: .claude)
        let line = #"{"type":"assistant","timestamp":"2026-10-25T13:02:19.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(words.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\""))"}]}}"#
        log.read(Data((line + "\n").utf8))
        XCTAssertEqual(log.turns.count, 1, "the answer should have parsed")

        let plate = TerminalChatView()
        plate.frame = NSRect(x: 0, y: 0, width: 560, height: height)
        plate.take(log)
        plate.paper.follow()
        plate.layoutSubtreeIfNeeded()
        return plate.paper
    }

    private func ink(_ paper: TerminalChatPaper) -> NSBitmapImageRep {
        paper.layoutSubtreeIfNeeded()
        let rep = paper.bitmapImageRepForCachingDisplay(in: paper.bounds)!
        paper.cacheDisplay(in: paper.bounds, to: rep)
        return rep
    }

    /// The last column of the paper that has ink on it.
    private func rightmost(_ paper: TerminalChatPaper) -> Int {
        let rep = ink(paper)
        let ground = rep.colorAt(x: 0, y: 0)!
        for px in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: px, y: y) else { continue }
                let delta = abs(color.redComponent - ground.redComponent)
                    + abs(color.greenComponent - ground.greenComponent)
                    + abs(color.blueComponent - ground.blueComponent)
                if delta > 0.06 { return px }
            }
        }
        return 0
    }

    /// The marks are instructions, not characters: bolding a word does not
    /// make the line any longer, because the `**` is never drawn.
    func testTheMarkersAreNotDrawnAsCharacters() {
        let plain = paper("the dock hugs the grid floor")
        let heavy = paper("the **dock** hugs the grid floor")
        XCTAssertEqual(heavy.written, plain.written, accuracy: 0.5)
        XCTAssertEqual(rightmost(heavy), rightmost(plain), accuracy: 6,
                       "the four markers would push the line right if they were drawn")
    }

    /// A code block's ground is a band across the column — the thing that
    /// says "this is what it will run", not prose.
    func testACodeBlockPaintsAGroundAcrossTheColumn() {
        let page = paper("""
        Run this:

        ```
        swift test --filter TerminalDockTests
        ```
        """)
        let rep = ink(page)
        let ground = rep.colorAt(x: 0, y: 0)!
        // Find a row where the ground differs from the paper's own, and
        // check it runs most of the way across.
        var widest = 0
        for y in 0..<rep.pixelsHigh {
            var run = 0
            for px in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: px, y: y) else { continue }
                let delta = abs(color.redComponent - ground.redComponent)
                    + abs(color.greenComponent - ground.greenComponent)
                    + abs(color.blueComponent - ground.blueComponent)
                if delta > 0.02 { run += 1 }
            }
            widest = max(widest, run)
        }
        XCTAssertGreaterThan(widest, Int(page.bounds.width * 0.6),
                             "the band should run across the column")
    }
}
