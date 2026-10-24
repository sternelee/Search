import XCTest
@testable import Search

@MainActor
final class FindStayTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "find-stay-\(getpid())", 1)
        super.setUp()
    }

    func testThePanelStaysOpenWhereItArrived() throws {
        let was = TerminalLook.findPlace
        defer { TerminalLook.findPlace = was }
        TerminalLook.findPlace = .top
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c", "sleep 10"]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        view.openFind()
        let panel = try XCTUnwrap(view.findPanel)
        XCTAssertEqual(panel.frame.maxY, view.bounds.height - FieldBox.edge, accuracy: 1)
        // Let everything queued settle: an end-editing that closes the panel
        // fires within a turn or two of the run loop.
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(view.findPanel != nil, "the panel is still there a moment later")
        if let still = view.findPanel {
            XCTAssertEqual(still.frame.maxY, view.bounds.height - FieldBox.edge, accuracy: 1)
        }
    }
}
