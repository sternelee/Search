import AppKit
import SwiftUI
import XCTest
@testable import Search

// A tab that runs a shell is held everywhere a page's tab is held: the bar,
// the split, the session. What differs is the page itself — never built —
// and the shell, started with its view and nowhere else (Tab.console).
@MainActor
final class TerminalTabTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "terminal-tab-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// A terminal tab never builds a web view — not when asked to reload,
    /// go back or forward, or zoom — and starts its shell with its view.
    func testTerminalTabRunsShellInsteadOfPage() throws {
        let browser = Browser(record: WindowRecord())
        let tab = Tab(bench: true, terminal: true)
        XCTAssertTrue(tab.isTerminal)
        XCTAssertNil(tab.built, "a terminal tab must not build a page")

        // Page commands decline rather than building a page to act on.
        tab.reload()
        tab.back()
        tab.forward()
        tab.magnify(to: 2)
        XCTAssertNil(tab.built)

        // The console is the shell, started with the view.
        let console = try XCTUnwrap(tab.console)
        XCTAssertNotNil(tab.shell)
        XCTAssertTrue(tab.console === console, "the console is built once")

        // A shell never sleeps: it is a live process (Browser.awake guards
        // it by tab.isTerminal), and closing the tab ends it.
        XCTAssertEqual(browser.awake(because: tab), "a live shell")
        tab.close()
        XCTAssertNil(tab.madeShell)
        // The shell is asked to end; give the process a moment to be reaped.
        let ended = expectation(description: "shell ended")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ended.fulfill() }
        wait(for: [ended], timeout: 5)
    }

    /// A page's tab is untouched by the terminal wiring: no console, not a
    /// terminal, and the page commands still build a page.
    func testPageTabUnchanged() {
        let tab = Tab(bench: true)
        XCTAssertFalse(tab.isTerminal)
        XCTAssertNil(tab.console)
        XCTAssertFalse(tab.hasPage, "a blank page's tab has no page yet")
        XCTAssertNil(tab.built)
        tab.close()
    }

    /// A terminal tab splits like any other: the pane takes the console,
    /// and the page is never built.
    func testTerminalTabSplits() throws {
        let tab = Tab(bench: true, terminal: true)
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        // A slot shows its page once it is in a window (Stage.settle), so
        // the stage is put in one first, as it always is.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = stage
        stage.show([tab], split: nil, focused: tab.id)
        stage.layoutSubtreeIfNeeded()
        // The console lands in a slot (StageView), as a page does — and it
        // is the room the panes are in now, one level deeper than the
        // terminal itself: the slot holds the room, the room holds panes.
        let console = try XCTUnwrap(
            stage.subviews.flatMap { $0.subviews }.compactMap { $0 as? TerminalSplits }.first)
        XCTAssertTrue(console.superview is StageView, "the console is held by a slot, as a page is")
        XCTAssertTrue(console.superview?.superview === stage)
        let pane = try XCTUnwrap(console.focusedView)
        XCTAssertTrue(pane.superview === console, "the terminal is a pane in the room")
        XCTAssertNil(tab.built)
        tab.close()
    }

    /// A window around a room, as a real one holds it: the frame to lay
    /// out in and the responder chain to arrive in.
    private func window(holding room: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = room
        window.orderFrontRegardless()
        room.layoutSubtreeIfNeeded()
        return window
    }

    /// The tab's shell is the pane the keys are in: splitting makes a new
    /// one and the keys go to it, and moving the keys moves what the tab
    /// calls its shell. Closing the tab closes whatever panes it holds.
    func testTheTabsShellIsThePaneTheKeysAreIn() throws {
        let tab = Tab(bench: true, terminal: true)
        let console = try XCTUnwrap(tab.console)
        // A room to split: the console is a view, and it needs its frame.
        let window = window(holding: console)

        let first = try XCTUnwrap(tab.shell)
        XCTAssertTrue(console.split(across: .horizontal))
        XCTAssertEqual(console.paneCount, 2)
        XCTAssertFalse(tab.shell === first, "the pane that was made took the keys")

        console.moveFocus(.left)
        XCTAssertTrue(tab.shell === first, "and the keys moved back to the pane that was there")

        tab.close()
        XCTAssertNil(tab.madeShell, "the room and every shell in it went with the tab")
        window.orderOut(nil)
    }

    /// The session holds a shell wherever it stood: written with the
    /// terminal mark, read back as a shell in the same place.
    func testSessionEntryCarriesTerminal() throws {
        let entry = Session.Entry(url: "", title: "zsh", terminal: true)
        let data = try JSONEncoder().encode(entry)
        let read = try JSONDecoder().decode(Session.Entry.self, from: data)
        XCTAssertEqual(read.terminal, true)

        // An entry from before terminals is not one, and reads unchanged.
        let old = Session.Entry(url: "https://example.com", title: "Example")
        let again = try JSONDecoder().decode(
            Session.Entry.self,
            from: JSONEncoder().encode(old))
        XCTAssertNil(again.terminal)
        let fromBefore = try JSONDecoder().decode(
            Session.Entry.self,
            from: Data("{\"url\":\"https://example.com\",\"title\":\"Example\"}".utf8))
        XCTAssertNil(fromBefore.terminal)
    }

    /// The address field's own command line reaches a terminal: "term",
    /// whole and alone (Settings › General › Address bar commands).
    func testTermAddressCommand() {
        let browser = Browser(record: WindowRecord())
        browser.prefs.commandBar = true
        XCTAssertEqual(AddressCommand.matching("term", in: browser), .newTerminal)
        XCTAssertEqual(AddressCommand.matching("terminal", in: browser), .newTerminal)
        XCTAssertEqual(AddressCommand.matching("new terminal", in: browser), .newTerminal)
        // A near miss is still a search.
        XCTAssertNil(AddressCommand.matching("terms", in: browser))
        XCTAssertNil(AddressCommand.matching("term paper", in: browser))
    }

    /// A shell that announces something while nobody is looking at it is a
    /// Mac notification (OSC 9 / OSC 777 — see Terminal, Notifications); a
    /// test run keeps what it would have posted, for the bench.
    func testNoticeFromAnUnseenTerminalIsKeptForTheBench() {
        let browser = Browser(record: WindowRecord())
        let tab = Tab(bench: true, terminal: true)
        browser.prepare(tab)

        let before = SiteNotifications.shared.recorded.count
        tab.onNotice?(.note(title: "job done", body: "build finished"))
        let kept = SiteNotifications.shared.recorded.last
        XCTAssertEqual(SiteNotifications.shared.recorded.count, before + 1)
        XCTAssertEqual(kept?["kind"], "terminal")
        XCTAssertEqual(kept?["title"], "job done")
        XCTAssertEqual(kept?["body"], "build finished")

        tab.close()
    }

    /// A shell that ends takes its pane with it: the room closes over the
    /// pane whose shell exited, on its own and with no asking (there is
    /// nothing left to end), and the tab is kept for its last pane — which
    /// ⌘W then takes, as a one-pane terminal always did.
    func testAShellThatEndsTakesItsPaneAndThenTheTab() throws {
        let browser = Browser(record: WindowRecord())
        browser.newTerminal()
        let tab = try XCTUnwrap(browser.active)
        let console = try XCTUnwrap(tab.console)
        let window = window(holding: console)

        browser.splitTerminal(across: .horizontal)
        XCTAssertEqual(browser.terminalPanes, 2, "⌘D grew the room to two panes")

        tab.shell?.stop()
        let gone = expectation(description: "the pane's shell reaped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { gone.fulfill() }
        wait(for: [gone], timeout: 5)

        XCTAssertEqual(browser.terminalPanes, 1, "the pane whose shell ended closed, and the room closed over it")
        XCTAssertTrue(browser.tabs.contains { $0 === tab }, "the tab is kept for its last pane")

        browser.closeFront()
        XCTAssertFalse(browser.tabs.contains { $0 === tab }, "the last pane went with the tab")
        window.orderOut(nil)
    }

    /// A terminal of one pane goes when its shell does — an `exit` typed
    /// is the terminal closed, as a terminal window closes with its shell.
    func testTheTabGoesWhenItsOnlyShellDoes() throws {
        let browser = Browser(record: WindowRecord())
        browser.newTerminal()
        let tab = try XCTUnwrap(browser.active)
        _ = try XCTUnwrap(tab.console)

        tab.shell?.stop()
        let gone = expectation(description: "the shell left, and the tab with it")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { gone.fulfill() }
        wait(for: [gone], timeout: 5)

        XCTAssertFalse(browser.tabs.contains { $0 === tab }, "the tab closed with its shell")
    }

    /// A terminal of one pane closes like any tab: the room never had
    /// sides, so ⌘W takes the whole thing.
    func testCloseFrontClosesAOnePaneTerminalOutright() throws {
        let browser = Browser(record: WindowRecord())
        browser.newTerminal()
        let tab = try XCTUnwrap(browser.active)
        _ = try XCTUnwrap(tab.console)
        XCTAssertEqual(browser.terminalPanes, 1)

        browser.closeFront()
        XCTAssertFalse(browser.tabs.contains { $0 === tab }, "with no second pane, the tab itself went")
    }

    /// The room's commands are offered only where there is a room: on a
    /// page they decline — and build nothing to decline with.
    func testTheRoomsCommandsLeaveAPageAlone() {
        let browser = Browser(record: WindowRecord())
        browser.newTab()
        XCTAssertEqual(browser.active?.isTerminal, false)

        browser.splitTerminal(across: .horizontal)
        browser.splitTerminal(across: .vertical)
        browser.moveTerminalFocus(.left)
        browser.nudgeTerminalDivider(.up)
        browser.zoomTerminalPane()
        browser.evenTerminalPanes()

        XCTAssertEqual(browser.terminalPanes, 0)
        XCTAssertNil(browser.active?.built, "no page was built to decline with")
        XCTAssertEqual(browser.tabs.count, 1)
    }

    /// ⌘D, two meanings told apart by the tab: the Duplicate command itself
    /// grows the room on a terminal — the menu equivalent and the key taker
    /// come back to Browser.duplicate with it.
    func testTheDuplicateCommandSplitsATerminalInstead() throws {
        let browser = Browser(record: WindowRecord())
        browser.newTerminal()
        let tab = try XCTUnwrap(browser.active)
        let console = try XCTUnwrap(tab.console)
        let window = window(holding: console)

        let duplicate = try XCTUnwrap(Command.all.first { $0.id == "tabs.duplicate" })
        duplicate.run(browser)
        XCTAssertEqual(browser.terminalPanes, 2, "⌘D on a terminal grows the room, not a copy of the tab")
        XCTAssertNil(tab.built, "and still no page was built")

        tab.close()
        window.orderOut(nil)
    }
}
