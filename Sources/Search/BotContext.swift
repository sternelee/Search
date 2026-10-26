import Foundation

/// Explicit window/Space and user-selected pages. Changing the front window
/// or opening an unrelated tab cannot broaden a conversation's access.
@MainActor
final class BotContext {
    weak var browser: Browser?
    private(set) var space: UUID
    private(set) var selected: Set<UUID>
    var primary: UUID?

    init(browser: Browser, tabs: [Tab] = []) {
        self.browser = browser
        space = browser.spaceID
        selected = Set(tabs.map(\.id))
        primary = tabs.first?.id
    }

    func bind(browser: Browser, tabs: [Tab]) {
        self.browser = browser
        space = browser.spaceID
        selected = Set(tabs.map(\.id))
        primary = tabs.first?.id
    }

    func tabs(for provider: AIProvider) -> [Tab] {
        guard let browser, !browser.shut, browser.spaceID == space else { return [] }
        return browser.tabs.filter {
            selected.contains($0.id) && !$0.chat
                && (Store.testing || !$0.bench)
                && (provider.isLocal || !$0.shy)
                && (provider.isLocal || $0.built?.configuration.websiteDataStore.isPersistent != false)
        }
    }

    func page(for provider: AIProvider) -> Tab? {
        tabs(for: provider).first { $0.id == primary }
    }

    func find(_ alias: String, provider: AIProvider) -> Tab? {
        if alias == "this" { return page(for: provider) }
        return tabs(for: provider).first { "tab-\($0.id.uuidString.lowercased())" == alias.lowercased() }
    }

    func listing(provider: AIProvider) -> String {
        tabs(for: provider).map {
            "tab-\($0.id.uuidString.lowercased()) · \($0.address?.absoluteString ?? "") · \($0.title)"
        }.joined(separator: "\n")
    }

    var privatePages: Bool {
        browser?.tabs.contains {
            selected.contains($0.id) && ($0.shy || $0.built?.configuration.websiteDataStore.isPersistent == false)
        } ?? false
    }

    /// A conversation moved to another window keeps the pages it was given
    /// only while that window is in the same Space: another Space's pages
    /// are not the pages it was handed (see BotContext.tabs). So the person
    /// is told, once, where it went — a silent empty listing reads as the
    /// Bot having forgotten what it was told.
    func elsewhere(_ browser: Browser) -> Bool {
        !browser.shut && browser.spaceID != space
    }
}

/// Snapshot-to-action ownership, independent of which chat pane is visible.
/// A run owns only one page at once, avoiding cross-page lock deadlocks.
@MainActor
final class BotPageLeases {
    static let shared = BotPageLeases()
    private var owners: [UUID: UUID] = [:]
    private struct Waiting {
        let page: UUID
        let owner: UUID
        let ready: () -> Void
    }
    private var waiting: [Waiting] = []

    func owns(_ page: UUID, owner: UUID) -> Bool { owners[page] == owner }

    func acquire(_ page: UUID, owner: UUID, ready: @escaping () -> Void) {
        if owns(page, owner: owner) { ready(); return }
        release(owner)
        if owners[page] == nil {
            owners[page] = owner
            ready()
        } else {
            waiting.append(Waiting(page: page, owner: owner, ready: ready))
        }
    }

    func release(_ owner: UUID) {
        waiting.removeAll { $0.owner == owner }
        owners = owners.filter { $0.value != owner }
        var callbacks: [() -> Void] = []
        for item in waiting where owners[item.page] == nil {
            owners[item.page] = item.owner
            callbacks.append(item.ready)
        }
        waiting.removeAll { owners[$0.page] == $0.owner }
        callbacks.forEach { $0() }
    }
}
