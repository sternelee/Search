import XCTest
@testable import Search

/// The find panel's opening turn, and its manners afterwards.
@MainActor
final class FindOpenProbe: XCTestCase {
    private func pane() -> (TerminalView, NSWindow) {
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c", "sleep 10"]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return (view, window)
    }

    func testTheFindStaysOpenAfterCommandF() {
        let (view, window) = pane()
        view.openFind()
        XCTAssertNotNil(view.findPanel, "the panel exists the moment it opens")
        XCTAssertTrue(window.firstResponder === view.findField?.currentEditor(),
                      "the field's editor has the keyboard")
        for turn in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            XCTAssertNotNil(view.findPanel, "the panel is still there after turn \(turn)")
        }
        // Open once more is the same panel, not a second one.
        view.openFind()
        XCTAssertEqual(view.subviews.filter { $0 is TerminalFieldPanel }.count, 1)
    }

    func testLeavingTheFieldClosesTheFind() {
        let (view, window) = pane()
        view.openFind()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(view.findPanel)
        window.makeFirstResponder(view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(view.findPanel, "the keyboard back in the grid closes the find")
    }

    func testALayoutWhileThePanelIsLeavingDoesNotBringItBack() {
        let (view, _) = pane()
        view.openFind()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(view.findPanel)
        view.closeFind()
        // A layout lands while the plate is on its way out — a resize,
        // output arriving, the dock taking its rows. The home edge is
        // re-read; the close holds.
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(view.findPanel, "a layout mid-leg does not walk the panel back home")
    }
}

/// The panel's other half: what it finds, and what it says about it.
@MainActor
final class FindOpenProbeText: XCTestCase {
    private func pane() -> (TerminalView, NSWindow) {
        let terminal = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-f", "-c", "printf 'alpha\\nbeta\\nalpha\\n'; sleep 10"]))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (view, window)
    }

    func testTypingFindsAndSaysHowMany() {
        let (view, _) = pane()
        view.openFind()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let field = view.findField else { return XCTFail("no field") }
        field.stringValue = "alpha"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(view.findings.count, 2, "both alphas in the scrollback")
        XCTAssertEqual(view.finding, 0, "the first is the one stood on")
        XCTAssertEqual(view.findPanel?.count.stringValue, "1 of 2")
    }
}
