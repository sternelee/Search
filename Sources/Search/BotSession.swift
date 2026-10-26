import SwiftUI
import Combine

/// Durable conversation identity, distinct from a reusable Bot profile and
/// from the disposable execution loop. A view never owns its runtime.
@MainActor
final class BotSession: ObservableObject, Identifiable {
    struct Record: Codable {
        var version = 1
        var id: UUID
        var profileID: UUID
        var title: String
        var archived = false
        var updated = Date()
        var draft = ""
        var state = BotRunState.idle
        var events: [Bot.Event] = []
        var messages: [AIMessage] = []
        var cards: Data?
    }

    let id: UUID
    let profileID: UUID
    @Published var title: String
    @Published var archived: Bool
    @Published private(set) var updated: Date
    let runtime: Bot
    let context: BotContext
    private(set) var ephemeral: Bool
    private var relay: AnyCancellable?
    var changed: (() -> Void)?
    var stateChanged: (() -> Void)?
    private var lastState = ""
    private var saving: Task<Void, Never>?

    init(record: Record, profile: BotProfile, context: BotContext) {
        id = record.id
        profileID = record.profileID
        title = record.title
        archived = record.archived
        updated = record.updated
        self.context = context
        ephemeral = context.privatePages
        runtime = Bot(session: record.id, profile: profile, context: context)
        runtime.restore(events: record.events, messages: record.messages, cards: record.cards)
        runtime.draft = record.draft
        runtime.runState = record.state.active ? .interrupted : record.state
        relay = runtime.objectWillChange.sink { [weak self] _ in
            // Published sends before the mutation. Snapshot after the build's
            // changes, and coalesce streaming tokens into a single disk write.
            Task { @MainActor [weak self] in self?.scheduleSave() }
        }
    }

    func scheduleSave() {
        objectWillChange.send()
        let state = "\(runtime.runState.rawValue):\(runtime.busy):\(runtime.pending?.id.uuidString ?? "")"
        if state != lastState { lastState = state; stateChanged?() }
        updated = Date()
        saving?.cancel()
        saving = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.changed?()
        }
    }

    func snapshot() -> Record {
        if context.privatePages { ephemeral = true }
        let held = runtime.hold()
        var events = held.events.filter { $0.kind != .think }
        if let draft = runtime.drafting, !draft.words.isEmpty {
            events.append(Bot.Event(kind: .trouble, words: "Unfinished reply: " + draft.words, act: nil))
        }
        return Record(id: id, profileID: profileID, title: title, archived: archived,
                      updated: updated, draft: runtime.draft, state: runtime.runState,
                      events: Array(events.suffix(1000)), messages: held.messages,
                      cards: runtime.cardArchive)
    }

    func detach() {
        changed = nil
        stateChanged = nil
        saving?.cancel()
        relay?.cancel()
        runtime.stop()
    }
}
