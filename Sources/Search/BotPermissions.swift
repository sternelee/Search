import Foundation

/// Role instructions never grant authority. Both the run's frozen grants and
/// the current profile must allow an operation before it reaches a tool.
struct BotPermissions: Codable, Equatable {
    var browser = true
    var commands = false
    var clipboard = false
    var history = false
    var memory = true
    var scheduling = false
    var tools: Set<String> = []
    var skills: Set<String> = []

    func allows(_ verb: String, target: String = "") -> Bool {
        switch verb {
        case "run": return commands
        case "copy": return clipboard
        case "history": return history
        case "note": return memory
        case "later": return scheduling && browser
        case "tool": return tools.contains(target)
        case "skill": return skills.contains(target)
        case "say", "answer", "human", "ui": return true
        default: return browser
        }
    }
}

struct BotProfile: Codable, Identifiable, Equatable {
    /// The faces a Bot can wear, offered instead of a field someone has to
    /// know the name of a symbol to fill in.
    static let avatars = ["sparkles", "magnifyingglass", "book", "globe",
                          "terminal", "wand.and.stars", "brain.head.profile", "text.bubble"]
    var id = UUID()
    var name = "New Bot"
    var avatar = "sparkles"
    var role = ""
    var provider: AIProvider?
    var model = ""
    var thinking = BotThinking.off
    var steps = 12
    var permissions = BotPermissions()
    var pinned = false
    var archived = false
    var deleted = false
    var notes: [Bot.Thought] = []
    var updated = Date()
}

enum BotRunState: String, Codable {
    case idle, queued, running, waitingApproval, waitingHuman
    case completed, failed, cancelled, interrupted

    var active: Bool { [.queued, .running, .waitingApproval].contains(self) }
}

/// One run per conversation; a small global budget, with one slot for the
/// built-in model. Cancelling a queued run never starts it later.
@MainActor
final class BotRunQueue {
    static let shared = BotRunQueue()
    private struct Waiting {
        let id: UUID
        let local: Bool
        let start: () -> Void
    }
    private var waiting: [Waiting] = []
    private var running: [UUID: Bool] = [:]
    let limit: Int

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func enqueue(_ id: UUID, local: Bool, start: @escaping () -> Void) {
        guard running[id] == nil, !waiting.contains(where: { $0.id == id }) else { return }
        waiting.append(Waiting(id: id, local: local, start: start))
        drain()
    }

    func release(_ id: UUID) {
        waiting.removeAll { $0.id == id }
        running[id] = nil
        drain()
    }

    private func drain() {
        while running.count < limit,
              let index = waiting.firstIndex(where: { !$0.local || !running.values.contains(true) }) {
            let next = waiting.remove(at: index)
            running[next.id] = next.local
            next.start()
        }
    }
}
