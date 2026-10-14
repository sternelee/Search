import XCTest
@testable import Search

// The search of a terminal's scrollback (see TerminalFind). The matches
// themselves are pure — rows of the grid, a needle — and that is what is
// checked here: the places, the width, the case, the repeat.
@MainActor
final class TerminalFindTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "terminal-find-\(getpid())", 1)
        super.setUp()
    }

    /// Rows with a needle's places in them.
    private func rows(_ text: String) -> [Row] {
        let screen = Screen(width: 20, height: 5)
        let parser = Parser(screen: screen)
        parser.feed(Array(text.utf8))
        return screen.rows
    }

    func testMatchesArePlacesWidthsAndCases() {
        let rows = rows("hello world\r\nHELLO again\r\nnothing here")
        let hits = TerminalView.matches(for: "hello", in: rows)
        XCTAssertEqual(hits.map { [$0.row, $0.col, $0.len] }, [
            [0, 0, 5],
            [1, 0, 5],
        ], "case-blind, row and column by cells")
    }

    func testMatchesRepeatAlongARow() {
        let rows = rows("ab ab ab")
        let hits = TerminalView.matches(for: "ab", in: rows)
        XCTAssertEqual(hits.map { [$0.row, $0.col, $0.len] }, [
            [0, 0, 2],
            [0, 3, 2],
            [0, 6, 2],
        ])
    }

    func testNoNeedleNoMatches() {
        let rows = rows("anything at all")
        XCTAssertTrue(TerminalView.matches(for: "", in: rows).isEmpty, "no needle, no search")
        XCTAssertTrue(TerminalView.matches(for: "absent", in: rows).isEmpty)
    }
}
