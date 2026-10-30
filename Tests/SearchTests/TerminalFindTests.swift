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

/// The panel hangs off the end of the frame the setting names (see
/// TerminalLook.findPlace): Top puts it over the top corner, Bottom over
/// the bottom one, and a panel opened after the setting changed follows it.
@MainActor
final class TerminalFindPlaceTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "find-place-\(getpid())", 1)
        super.setUp()
    }

    private func pane() -> TerminalView {
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c", "sleep 10"]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        // Out of sight when the test ends, not closed: a window this test put
        // on screen is still visible to every other suite's teardown, which
        // asserts that nothing is.
        addTeardownBlock { window.orderOut(nil) }
        return view
    }

    func testThePanelHangsWhereTheSettingSays() throws {
        let was = TerminalLook.findPlace
        defer { TerminalLook.findPlace = was }

        TerminalLook.findPlace = .top
        let up = pane()
        up.openFind()
        let panel = try XCTUnwrap(up.findPanel, "the panel is in the frame")
        XCTAssertEqual(
            panel.frame.maxY, up.bounds.height - FieldBox.edge, accuracy: 1,
            "Top hangs off the frame's top corner"
        )

        TerminalLook.findPlace = .bottom
        let down = pane()
        down.openFind()
        let other = try XCTUnwrap(down.findPanel)
        XCTAssertEqual(
            other.frame.minY, FieldBox.farEdge, accuracy: 1,
            "Bottom hangs off the frame's bottom corner"
        )
    }
}
