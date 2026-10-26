import XCTest
@testable import Search

// The reply as it comes, shown word by word (see Bot.Loop.wordsStanding):
// a model asked for one JSON line answers in that line — and sometimes
// wraps it in a fence, which is how it was posted and not something to
// read. What the person is shown while the reply is still arriving is the
// words, never the protocol around them.

@MainActor
final class DraftTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "draft-\(getpid())", 1)
        super.setUp()
    }

    func testPlainWordsAreShownAsWritten() {
        XCTAssertEqual(Loop.wordsStanding(in: "The page says hello"), "The page says hello")
        // Leading space and newlines go by: the words are what's read.
        XCTAssertEqual(Loop.wordsStanding(in: "\n\n  The page says hello"), "The page says hello")
    }

    func testASayIsShownWhileItsLineIsStillComing() {
        // Half a line, mid-string: the words said so far are the words
        // shown — the line's closing is not waited on to start reading.
        XCTAssertEqual(Loop.wordsStanding(in: #"{"say": "He"#), "He")
        // An escaped quote inside the string is a quote, not its end.
        XCTAssertEqual(Loop.wordsStanding(in: "{\"say\": \"Hello \\\"wor"), "Hello \"wor")
    }

    func testAnAnswerIsShownToo() {
        XCTAssertEqual(Loop.wordsStanding(in: #"{"answer": "It worked"#), "It worked")
    }

    func testALineWithNothingToShowYetShowsNothing() {
        // The brace, the key, the colon — the value not begun.
        XCTAssertEqual(Loop.wordsStanding(in: "{"), "")
        XCTAssertEqual(Loop.wordsStanding(in: #"{"say":"#), "")
        XCTAssertEqual(Loop.wordsStanding(in: #"{"act": {"verb": "click"#), "")
    }

    func testAFencedLineIsShownWithoutItsFence() {
        // The fence and the language word over it are how the line was
        // posted, not words: what's inside is what the person reads.
        XCTAssertEqual(
            Loop.wordsStanding(in: "```json\n{\"say\": \"Looking at it"),
            "Looking at it"
        )
        // Closed, or not yet closed — the words inside are the words.
        XCTAssertEqual(
            Loop.wordsStanding(in: "```json\n{\"say\": \"Done\"}\n```"),
            "Done"
        )
        XCTAssertEqual(Loop.wordsStanding(in: "~~~\n{\"answer\": \"3 rows\""), "3 rows")
    }

    func testAFencedReplyInPlainWordsIsShownToo() {
        // A model that answers in a fence of plain words — no JSON at all:
        // its words are shown, and the fence is not.
        XCTAssertEqual(Loop.wordsStanding(in: "```\nThe page says hello"), "The page says hello")
        XCTAssertEqual(Loop.wordsStanding(in: "```\nthe first line\nthe second"), "the first line\nthe second")
    }

    func testTheFenceAloneShowsNothing() {
        // The backticks have come and the language over them hasn't: there
        // is nothing inside yet to read.
        XCTAssertEqual(Loop.wordsStanding(in: "```"), "")
        XCTAssertEqual(Loop.wordsStanding(in: "```json"), "")
    }
}
