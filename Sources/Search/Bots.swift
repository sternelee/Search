import SwiftUI
import Combine

@MainActor
final class Bots: ObservableObject {
    static let shared = Bots()
    private struct Index: Codable {
        var version = 1
        var profiles: [BotProfile]
        var sessions: [UUID]
        var defaultID: UUID?
    }
    @Published private(set) var profiles: [BotProfile] = []
    @Published private(set) var sessions: [BotSession] = []
    @Published private(set) var error: String?
    private(set) var defaultID: UUID?
    private let disk: BotPersistence
    private var saved: [UUID: BotSession.Record] = [:]
    private var readonly = false
    private var terminating: NSObjectProtocol?

    init(disk: BotPersistence = BotPersistence()) {
        self.disk = disk
        do {
            if let index = try disk.read(Index.self, name: "index.json") {
                guard index.version == 1 else {
                    readonly = true
                    error = "These Bots were saved by a newer version of Search."
                    return
                }
                profiles = index.profiles.map(Bots.faced)
                defaultID = index.defaultID
                for id in index.sessions {
                    do {
                        if let record = try disk.read(BotSession.Record.self, name: filename(id)) {
                            guard record.version == 1, record.id == id else {
                                readonly = true
                                self.error = "A conversation uses an unsupported format. Its index was left unchanged."
                                continue
                            }
                            saved[id] = record
                        }
                    } catch { self.error = "A conversation could not be read; its file was set aside." }
                }
            }
        } catch {
            readonly = true
            self.error = "The Bots index could not be read. It was set aside rather than overwritten."
        }
        terminating = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessions { session.runtime.stop(); self.save(session) }
            }
        }
    }

    deinit {
        if let terminating { NotificationCenter.default.removeObserver(terminating) }
    }

    func configure(_ prefs: Preferences, browser: Browser) {
        if profiles.isEmpty, !readonly {
            var profile = BotProfile(name: "General Assistant", provider: prefs.aiProvider,
                                     model: prefs.aiProvider.map { prefs.aiModel(for: $0) } ?? "",
                                     thinking: prefs.botThinking, steps: prefs.botSteps)
            profile.permissions.commands = true
            profile.permissions.clipboard = true
            profile.permissions.history = true
            profile.permissions.scheduling = true
            profile.permissions.tools = Set(MCPHub.shared.listed().map(\.qualified))
            profile.permissions.skills = Set(Skills.listed().map(\.name))
            profile.notes = Bot.notes()
            profiles = [profile]
            defaultID = profile.id
            saveIndex()
        }
        // Restored conversations do not silently regain yesterday's tab access.
        // A browser tab UUID is a live identity, not an address to reopen.
        let records = saved.values.sorted { $0.updated > $1.updated }
        for record in records where !sessions.contains(where: { $0.id == record.id }) {
            guard let profile = profile(record.profileID) else { continue }
            register(BotSession(record: record, profile: profile, context: BotContext(browser: browser)))
        }
    }

    func profile(_ id: UUID) -> BotProfile? { profiles.first { $0.id == id } }
    func session(_ id: UUID) -> BotSession? { sessions.first { $0.id == id } }

    @discardableResult
    /// A symbol the system has no glyph for draws nothing, and a row with a
    /// hole in it reads as a Bot that failed to load: whatever a file, or the
    /// field this used to be typed into, left behind, an unknown face is the
    /// default one.
    static func faced(_ profile: BotProfile) -> BotProfile {
        guard NSImage(systemSymbolName: profile.avatar, accessibilityDescription: nil) == nil
        else { return profile }
        var copy = profile
        copy.avatar = "sparkles"
        return copy
    }

    func put(_ given: BotProfile, replacingMemory: Bool = false) -> Bool {
        guard !readonly else { return false }
        var profile = given
        profile.name = String(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !profile.name.isEmpty else { return false }
        profile.role = String(profile.role.prefix(12000))
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profile.model.isEmpty || (profile.model.count <= 100
            && !["sk-", "AIza", "gsk_", "hf_"].contains(where: { profile.model.hasPrefix($0) })
            && profile.model.range(of: #"^[A-Za-z0-9._:/@\-]+$"#, options: .regularExpression) != nil) else {
            error = "Enter a model name, not a key or address."
            return false
        }
        profile.steps = min(50, max(1, profile.steps))
        profile = Bots.faced(profile)
        profile.updated = Date()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            if !replacingMemory { profile.notes = profiles[index].notes }
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if profile.archived || profile.deleted {
            sessions.filter { $0.profileID == profile.id }.forEach { $0.runtime.stop() }
        }
        if defaultID == nil || profiles.first(where: { $0.id == defaultID }).map({ $0.deleted || $0.archived }) == true {
            defaultID = profiles.first { !$0.deleted && !$0.archived }?.id
        }
        saveIndex()
        return true
    }

    func duplicate(_ profile: BotProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name += " copy"
        copy.notes = []
        copy.deleted = false
        copy.archived = false
        _ = put(copy)
    }

    @discardableResult
    func create(profileID: UUID, browser: Browser, tabs: [Tab] = [], title: String = "New conversation") -> BotSession? {
        guard !readonly, let profile = profile(profileID), !profile.deleted, !profile.archived else { return nil }
        let context = BotContext(browser: browser, tabs: tabs)
        guard !context.privatePages || profile.provider?.isLocal == true else {
            error = "Private pages can only be attached to a local model."
            return nil
        }
        let record = BotSession.Record(id: UUID(), profileID: profileID, title: title)
        let session = BotSession(record: record, profile: profile, context: context)
        register(session)
        save(session)
        return session
    }

    private func register(_ session: BotSession) {
        sessions.append(session)
        session.stateChanged = { [weak self] in self?.objectWillChange.send() }
        session.changed = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
            self.save(session, background: true)
            self.objectWillChange.send()
        }
        session.runtime.currentPermissions = { [weak self, weak session] in
            guard let session, let profile = self?.profile(session.profileID), !profile.archived, !profile.deleted else { return nil }
            return profile.permissions
        }
        session.runtime.remember = { [weak self, weak session] words in
            guard let session else { return }
            self?.remember(words, profileID: session.profileID)
        }
        session.runtime.prepare = { [weak self, weak session] in
            guard let self, let session, !session.archived,
                  let profile = self.profile(session.profileID), !profile.archived, !profile.deleted else {
                return "This Bot or conversation is archived."
            }
            guard !self.readonly else { return "The Bots store is read-only until its format can be recovered." }
            guard let provider = profile.provider else { return "Choose a provider in this Bot's setup." }
            guard !(session.ephemeral || session.context.privatePages) || provider.isLocal else { return "A conversation containing private pages must stay on a local model." }
            guard provider.isLocal || AIKeys.hint(for: provider) != nil else { return "Add this provider's key in Settings › AI." }
            if provider == .thisMac, AIEngine.shared.state != .ready { return "Install the local model in Settings › AI first." }
            session.runtime.apply(profile)
            return nil
        }
    }

    func rename(_ session: BotSession, to title: String) {
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !name.isEmpty else { return }
        session.title = name
        save(session)
        objectWillChange.send()
    }

    func archive(_ session: BotSession, _ archived: Bool) {
        session.runtime.stop()
        session.archived = archived
        save(session)
        objectWillChange.send()
    }

    func delete(_ session: BotSession) {
        session.detach()
        sessions.removeAll { $0.id == session.id }
        saved[session.id] = nil
        do { try disk.remove(name: filename(session.id)) }
        catch { self.error = "The conversation could not be removed: \(error.localizedDescription)" }
        saveIndex()
    }

    func remember(_ words: String, profileID: UUID) {
        guard var profile = profile(profileID), !profile.deleted else { return }
        profile.notes.append(Bot.Thought(words: String(words.prefix(500)), at: Date()))
        profile.notes = Array(profile.notes.suffix(100))
        _ = put(profile, replacingMemory: true)
    }

    func save(_ session: BotSession, background: Bool = false) {
        guard !readonly else { return }
        let record = session.snapshot()
        do {
            if session.ephemeral {
                saved[session.id] = nil
                try disk.remove(name: filename(session.id))
            } else {
                saved[session.id] = record
                if background {
                    let index = Index(profiles: profiles, sessions: Array(saved.keys), defaultID: defaultID)
                    try disk.writeLater(record, name: filename(session.id), index: index) { [weak self] failure in
                        guard let failure else { return }
                        Task { @MainActor [weak self] in
                            self?.error = "The conversation could not be saved: \(failure.localizedDescription)"
                        }
                    }
                    return
                }
                try disk.write(record, name: filename(session.id))
            }
            saveIndex()
        } catch { self.error = "The conversation could not be saved: \(error.localizedDescription)" }
    }

    private func saveIndex() {
        guard !readonly else { return }
        do {
            try disk.write(Index(profiles: profiles, sessions: Array(saved.keys), defaultID: defaultID), name: "index.json")
        } catch { self.error = "Bots could not be saved: \(error.localizedDescription)" }
    }

    private func filename(_ id: UUID) -> String { "session-\(id.uuidString).json" }

    var running: Int { sessions.filter { $0.runtime.busy }.count }
    var needsYou: Int {
        sessions.filter { $0.runtime.pending != nil || $0.runtime.runState == .waitingHuman }.count
    }
}

/// Display choices belong to a window; the conversations they point at do not.
///
/// One conversation is shown at a time: the navigator is how you go between
/// them, and picking another puts it where the last one was rather than
/// crowding a second beside it. A panel a hand's width beside a page has
/// room to read one conversation down its own width, not two.
struct BotWorkspaceLayout {
    private(set) var panes: [UUID] = []
    private(set) var focused: UUID?

    mutating func open(_ id: UUID) {
        if panes == [id] { focused = id; return }
        panes = [id]
        focused = id
    }

    mutating func focus(_ id: UUID) { if panes.contains(id) { focused = id } }
    mutating func close(_ id: UUID) {
        panes.removeAll { $0 == id }
        if focused == id { focused = panes.last }
    }
}

extension Browser {
    @discardableResult
    func newBotConversation(over tab: Tab? = nil) -> BotSession? {
        openBots()
        guard let id = Bots.shared.defaultID,
              let session = Bots.shared.create(profileID: id, browser: self, tabs: tab.map { [$0] } ?? []) else { return nil }
        show(session)
        return session
    }

    /// The door's own switch: the panel put away by the button that put it
    /// up, as the sidebar's door is (see BotsDoor).
    func toggleBots() {
        if botsShowing { hideBots() } else { openBots() }
    }

    /// The workspace put away: the page takes the room back and every
    /// conversation runs on. Full screen goes with it — it is a way of
    /// showing the panel, not a second thing to put away.
    func hideBots() {
        botsShowing = false
        botsFull = false
    }

    func openBots() {
        Bots.shared.configure(prefs, browser: self)
        botsShowing = true
        editing = false
        if botWorkspace.panes.isEmpty, let first = Bots.shared.sessions.first(where: { !$0.archived }) {
            botWorkspace.open(first.id)
        }
    }

    func show(_ session: BotSession) {
        openBots()
        botWorkspace.open(session.id)
    }

    func closeBotPane(_ id: UUID) {
        botWorkspace.close(id)
        if botWorkspace.panes.isEmpty { hideBots() }
    }
}
