import AppKit
import XCTest
@testable import Search

@MainActor
final class BotsTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "bots-tests-\(getpid())", 1)
        super.setUp()
    }
    private func store() throws -> (Bots, BotPersistence) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bots-\(UUID().uuidString)")
        let disk = BotPersistence(folder: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (Bots(disk: disk), disk)
    }

    func testOneProfileHasIndependentDurableConversations() throws {
        let (bots, disk) = try store()
        let profile = BotProfile(name: "Research", provider: .ollama, model: "test")
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let first = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        let second = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        first.runtime.draft = "first draft"
        second.runtime.draft = "second draft"
        first.runtime.restore(events: [Bot.Event(kind: .answer, words: "only first", act: nil)],
                              messages: [AIMessage(role: .user, text: "first question")], cards: nil)
        first.runtime.runState = .running
        bots.save(first)
        bots.save(second)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.profileID, second.profileID)
        XCTAssertTrue(second.runtime.events.isEmpty)
        let recovered = Bots(disk: disk)
        recovered.configure(browser.prefs, browser: browser)
        let held = try XCTUnwrap(recovered.session(first.id))
        XCTAssertEqual(held.runtime.draft, "first draft")
        XCTAssertEqual(held.runtime.events.first?.words, "only first")
        XCTAssertEqual(held.runtime.runState, .interrupted)
        XCTAssertNil(held.runtime.pending)
        XCTAssertFalse(held.runtime.busy)
        XCTAssertTrue(held.context.selected.isEmpty, "restoring history grants no tab access")
        XCTAssertEqual(recovered.session(second.id)?.runtime.draft, "second draft")
    }

    func testCapabilitiesAreEnforcedAndCanBeRevoked() throws {
        let (bots, _) = try store()
        var profile = BotProfile(name: "Reader", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let session = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        XCTAssertFalse(session.runtime.allows("run"))
        profile.permissions.commands = true
        XCTAssertTrue(bots.put(profile))
        session.runtime.apply(profile)
        XCTAssertTrue(session.runtime.allows("run"))
        profile.permissions.commands = false
        XCTAssertTrue(bots.put(profile))
        XCTAssertFalse(session.runtime.allows("run"), "a run's old grant cannot override a revocation")
        XCTAssertFalse(session.runtime.allows("tool", target: "other · write"))
        XCTAssertFalse(session.runtime.allows("skill", target: "other"))
    }

    /// The protocol is one list for every Bot; what this Bot hasn't been
    /// given is named after it, so the model doesn't spend a turn on a line
    /// that will be refused and end it.
    func testWhatABotIsNotAllowedIsStruckOutOfWhatItIsTold() throws {
        let bare = BotProfile(name: "Reader", provider: .ollama)
        let said = Bot.withheld(bare.permissions)
        for line in ["run", "copy", "history", "later", "tool", "skill"] {
            XCTAssertTrue(said.contains(line), "\(line) should be named as not this Bot's")
        }
        XCTAssertFalse(said.contains("act"), "the browser itself is allowed by default")
        XCTAssertFalse(said.contains("note"), "a Bot keeps thoughts unless that is turned off")

        var noMemory = BotProfile(name: "Forgetful", provider: .ollama)
        noMemory.permissions.memory = false
        XCTAssertTrue(Bot.withheld(noMemory.permissions).contains("note"))

        // The page's own lines go with the page: a Bot that may not touch it
        // may not work one, nor set a task that opens one.
        var noPage = BotProfile(name: "Deskbound", provider: .ollama)
        noPage.permissions.browser = false
        noPage.permissions.scheduling = true
        let pageSaid = Bot.withheld(noPage.permissions)
        for line in ["act", "read", "goto", "wait", "console", "full", "close", "later"] {
            XCTAssertTrue(pageSaid.contains(line), "\(line) needs the page, which this Bot hasn't")
        }

        var whole = BotProfile(name: "Whole", provider: .ollama)
        whole.permissions = BotPermissions(browser: true, commands: true, clipboard: true,
                                           history: true, memory: true, scheduling: true)
        whole.permissions.tools = ["server · read"]
        whole.permissions.skills = ["house-rules"]
        let everything = Bot.withheld(whole.permissions)
        XCTAssertEqual(everything, "", "a Bot given all of it is told nothing is missing")

        var noTools = whole
        noTools.permissions.tools = []
        XCTAssertTrue(Bot.withheld(noTools.permissions).contains("tool"), "no tools chosen is still none")

        // A legacy panel, with no Bot behind it, is told the whole shape.
        XCTAssertEqual(Bot.withheld(nil), "")
    }

    /// A window moved to another Space is not a conversation with nothing
    /// attached: the pages it was handed are that window's, and the model
    /// is told so rather than shown an empty listing.
    func testAnAskWhileARunWaitsItsTurnIsToldSoRatherThanQueuedOverIt() throws {
        let (bots, _) = try store()
        let profile = BotProfile(name: "Line", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let session = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        let bot = session.runtime
        bot.runState = .queued
        XCTAssertTrue(bot.occupied, "a run in the line means the conversation is taken")
        XCTAssertFalse(bot.busy, "but there is nothing in hand to stop")
        bot.draft = "something else"
        bot.submit()
        XCTAssertEqual(bot.trouble, Bot.queuedSays)
        XCTAssertEqual(bot.runState, .queued, "the run in the line is left where it was")
    }

    func testAConversationWhoseWindowMovedElsewhereIsToldSo() throws {
        let (bots, _) = try store()
        let profile = BotProfile(name: "Reader", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let session = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        XCTAssertFalse(session.context.elsewhere(browser), "the window it was handed is its own Space")
        browser.spaceID = UUID()
        XCTAssertTrue(session.context.elsewhere(browser))
        XCTAssertTrue(session.runtime.tabListing.contains("another Space"), session.runtime.tabListing)
        browser.spaceID = session.context.space
        XCTAssertFalse(session.runtime.tabListing.contains("another Space"))
    }

    func testPendingApprovalsAndClearingBelongToOneConversation() throws {
        let (bots, _) = try store()
        let profile = BotProfile(name: "Assistant", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let a = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        let b = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        a.runtime.pending = Bot.Pending(act: Bot.Act(verb: "fill", target: "@1", text: "a"))
        b.runtime.pending = Bot.Pending(act: Bot.Act(verb: "fill", target: "@1", text: "b"))
        let held = b.runtime.pending?.id
        bots.remember("only this Bot", profileID: profile.id)
        a.runtime.clear()
        XCTAssertEqual(b.runtime.pending?.id, held)
        XCTAssertEqual(b.runtime.pending?.act.text, "b")
        XCTAssertEqual(bots.profile(profile.id)?.notes.first?.words, "only this Bot")
    }

    func testPaneNavigationDoesNotOwnTheRuntime() throws {
        var layout = BotWorkspaceLayout()
        let ids = (0..<5).map { _ in UUID() }
        layout.open(ids[0])
        XCTAssertEqual(layout.panes, [ids[0]])
        XCTAssertEqual(layout.focused, ids[0])
        // One conversation at a time: opening another puts it where the last
        // one was, and the navigator is how you go back.
        layout.open(ids[1])
        XCTAssertEqual(layout.panes, [ids[1]])
        XCTAssertEqual(layout.focused, ids[1])
        layout.open(ids[1])
        XCTAssertEqual(layout.panes, [ids[1]])
        layout.close(ids[1])
        XCTAssertTrue(layout.panes.isEmpty)
        XCTAssertNil(layout.focused)
        layout.open(ids[2])
        XCTAssertEqual(layout.panes, [ids[2]])
    }

    func testTheDoorIsASwitchAndFullScreenGoesWithThePanel() throws {
        let (bots, _) = try store()
        let profile = BotProfile(name: "Assistant", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let session = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        browser.show(session)
        XCTAssertTrue(browser.botsShowing)
        XCTAssertEqual(browser.botWorkspace.panes, [session.id])
        browser.botsFull = true
        browser.toggleBots()
        XCTAssertFalse(browser.botsShowing)
        XCTAssertFalse(browser.botsFull, "the panel away takes full screen with it")
        browser.toggleBots()
        XCTAssertTrue(browser.botsShowing)
        XCTAssertFalse(browser.botsFull, "and comes back beside the page, not filling it")
        XCTAssertEqual(browser.botWorkspace.panes, [session.id])
        browser.closeBotPane(session.id)
        XCTAssertFalse(browser.botsShowing, "the last conversation closed is the panel closed")
        XCTAssertFalse(browser.botsFull)
    }

    func testQueueCancellationAndLocalModelBudgetAreIndependent() {
        let queue = BotRunQueue(limit: 2)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var started: [String] = []
        queue.enqueue(a, local: true) { started.append("a") }
        queue.enqueue(b, local: true) { started.append("b") }
        queue.enqueue(c, local: false) { started.append("c") }
        XCTAssertEqual(started, ["a", "c"])
        queue.release(b)
        queue.enqueue(d, local: false) { started.append("d") }
        queue.release(a)
        XCTAssertEqual(started, ["a", "c", "d"])
        queue.release(c)
        queue.release(d)
        XCTAssertFalse(started.contains("b"))
    }

    func testPageLeasesSerializeOnePageButNotOthers() {
        let leases = BotPageLeases()
        let page = UUID(), other = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        var started: [String] = []
        leases.acquire(page, owner: a) { started.append("a") }
        leases.acquire(page, owner: b) { started.append("b") }
        leases.acquire(other, owner: c) { started.append("c") }
        XCTAssertEqual(started, ["a", "c"])
        leases.release(a)
        XCTAssertEqual(started, ["a", "c", "b"])
        leases.release(b)
        leases.release(c)
    }

    func testSessionFilesArePrivateAndDeletedSessionsStayGone() throws {
        let (bots, disk) = try store()
        let profile = BotProfile(name: "Assistant", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let session = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        let file = disk.folder.appendingPathComponent("session-\(session.id.uuidString).json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        session.runtime.draft = "late write"
        bots.save(session, background: true)
        bots.delete(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(bots.session(session.id))
    }

    func testPrivateConversationNeverWritesHistoryOrMovesToCloud() throws {
        let (bots, disk) = try store()
        var profile = BotProfile(name: "Local", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        browser.newShyTab()
        let tab = try XCTUnwrap(browser.active)
        let session = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser, tabs: [tab]))
        session.runtime.draft = "private words"
        bots.save(session)
        let file = disk.folder.appendingPathComponent("session-\(session.id.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        session.context.bind(browser: browser, tabs: [])
        profile.provider = .openAI
        XCTAssertTrue(bots.put(profile))
        session.runtime.submit()
        XCTAssertEqual(session.runtime.runState, .failed)
        XCTAssertTrue(session.runtime.trouble?.contains("private") == true)
    }

    func testCorruptIndexIsQuarantinedAndNotOverwritten() throws {
        let (bots, disk) = try store()
        _ = bots
        try FileManager.default.createDirectory(at: disk.folder, withIntermediateDirectories: true)
        let file = disk.folder.appendingPathComponent("index.json")
        try Data("not json".utf8).write(to: file)
        let recovered = Bots(disk: disk)
        XCTAssertNotNil(recovered.error)
        XCTAssertFalse(recovered.put(BotProfile()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: disk.folder.path).contains { $0.contains("unreadable") })
    }

    func testContextDoesNotFollowFrontWindowOrReplaceClosedPages() throws {
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        let a = first.benchOpen(URL(string: "about:blank")!)
        let b = second.benchOpen(URL(string: "about:blank")!)
        let context = BotContext(browser: first, tabs: [a])
        let was = Front.shared.browser
        defer { Front.shared.set(was) }
        Front.shared.set(second)
        XCTAssertTrue(context.page(for: .ollama) === a)
        XCTAssertNil(context.find("tab-\(b.id.uuidString.lowercased())", provider: .ollama))
        first.close(a)
        XCTAssertNil(context.page(for: .ollama), "a closed target must never fall back to the foreground page")
    }

    func testConfigurationEditsDoNotEraseNewMemory() throws {
        let (bots, _) = try store()
        var stale = BotProfile(name: "Assistant", provider: .ollama)
        XCTAssertTrue(bots.put(stale))
        bots.remember("a thought arriving while setup is open", profileID: stale.id)
        stale.name = "Renamed"
        XCTAssertTrue(bots.put(stale))
        XCTAssertEqual(bots.profile(stale.id)?.notes.count, 1)
        XCTAssertEqual(bots.profile(stale.id)?.name, "Renamed")
    }

    func testThoughtsAreNotStoredAndRestoredApprovalsDoNotRun() throws {
        let (bots, disk) = try store()
        let profile = BotProfile(name: "Assistant", provider: .ollama)
        XCTAssertTrue(bots.put(profile))
        let browser = Browser(record: WindowRecord())
        let session = try XCTUnwrap(bots.create(profileID: profile.id, browser: browser))
        session.runtime.restore(events: [
            Bot.Event(kind: .think, words: "raw thought not for disk", act: nil),
            Bot.Event(kind: .answer, words: "the durable answer", act: nil),
        ], messages: [], cards: nil)
        session.runtime.pending = Bot.Pending(act: Bot.Act(verb: "run", target: "", text: "must not replay"))
        bots.save(session)
        let bytes = try Data(contentsOf: disk.folder.appendingPathComponent("session-\(session.id.uuidString).json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("raw thought"))
        let recovered = Bots(disk: disk)
        recovered.configure(browser.prefs, browser: browser)
        let runtime = try XCTUnwrap(recovered.session(session.id)?.runtime)
        XCTAssertEqual(runtime.runState, .interrupted)
        XCTAssertNil(runtime.pending)
        XCTAssertNil(runtime.runID)
        XCTAssertFalse(runtime.busy)
    }
}
