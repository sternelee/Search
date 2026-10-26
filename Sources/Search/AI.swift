import Foundation
import Security

// The AI add-on: a summary of the page you're on, and questions about it,
// answered where you choose — a model on this Mac, an app on this Mac that
// runs one (Ollama, LM Studio), or a provider you have an account or a key
// with. Off until you turn it on in Settings › AI; nothing is detected,
// downloaded or sent before that, and nothing afterwards until you ask.
//
// This file: where it runs, and the keys. The requests are AIClient's, the
// page's text AIPage's.

/// Whether the AI add-on is in this build at all. Held back from 1.0.5
/// (8 Oct 2026): with it off, none of it shows or runs — no Settings page, no
/// menu items or shortcuts, no line on the welcome or What's New cards — and
/// a setting left on by a test build reads as off. The code stays; this is
/// the one line that brings it back.
enum AI {
    static let shipped = false
}

/// Where the answers come from.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    /// The model downloaded to this Mac, run by Search's own engine (AIEngine).
    case thisMac
    case anthropic, openAI, gemini, openRouter
    /// Ollama, on this Mac.
    case ollama
    /// LM Studio, on this Mac.
    case lmStudio

    var id: String { rawValue }

    var name: String {
        switch self {
        case .thisMac: return "On this Mac"
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    /// Runs on this Mac: nothing leaves it, and no key is needed.
    var isLocal: Bool { self == .thisMac || self == .ollama || self == .lmStudio }

    /// The address requests go to: the provider's own, unless another one
    /// was named for it in Settings (see named). A key is kept for this host
    /// and is never sent to any other (see AIClient.request).
    var base: URL {
        if Store.testing, let mock = AIProvider.mock { return mock.appendingPathComponent(rawValue + "/") }
        return named ?? own
    }

    /// The provider's own address, which is where requests go until another
    /// one is named for it.
    var own: URL {
        switch self {
        // Never asked over the network: the engine is a program of its own.
        case .thisMac: return URL(string: "http://127.0.0.1:1/")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/")!
        case .openAI: return URL(string: "https://api.openai.com/v1/")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/")!
        case .ollama: return URL(string: "http://127.0.0.1:11434/v1/")!
        case .lmStudio: return URL(string: "http://127.0.0.1:1234/v1/")!
        }
    }

    /// Takes an address of its own: a gateway, a relay, an account under
    /// another name. The rest are at one address, and stay there.
    var takesAnotherAddress: Bool { self == .openAI || self == .anthropic }

    /// Another address for it, where one was named in Settings and what was
    /// typed is an address. Half an address on the way to a whole one is not
    /// one, and the provider's own is used until it is.
    var named: URL? {
        guard takesAnotherAddress,
              let named = Store.settings.dictionary(forKey: AIProvider.addressesKey) as? [String: String]
        else { return nil }
        return AIProvider.address(named[rawValue] ?? "")
    }

    /// Where an address named for a provider is kept (see Preferences.setAIBase).
    static let addressesKey = "ai.base"

    /// What was typed, read as an address — nil while it is not one. https and
    /// http both: an address named by hand is the person's own choice, and a
    /// gateway of their own may well be on this Mac (see AIClient.allowed).
    /// A name and password in it are refused, so no key is ever in an address.
    static func address(_ typed: String) -> URL? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty,
              let url = URL(string: typed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    var host: String { self == .thisMac ? "this Mac" : base.host() ?? "" }

    /// A test run's stand-in for every provider: a server on this Mac that
    /// answers the way they do (bench ai-mock). Never outside a test run,
    /// and only ever on the loopback address.
    nonisolated(unsafe) static var mock: URL?

    /// Cheap and quick, for a summary; each can be changed in Settings.
    /// The local apps have no default: the list comes from the app.
    var defaultModel: String {
        switch self {
        case .thisMac: return AIEngine.model.name
        case .anthropic: return "claude-haiku-4-5"
        case .openAI: return "gpt-5.4-mini"
        case .gemini: return "gemini-3.8-flash"
        case .openRouter: return "google/gemini-3.8-flash"
        case .ollama, .lmStudio: return ""
        }
    }

    /// How requests are written.
    enum Wire { case openAI, anthropic, gemini }

    var wire: Wire {
        switch self {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        default: return .openAI
        }
    }
}

/// How hard the model thinks before it speaks: the reasoning effort sent
/// with each request, where the provider supports it. Off for providers
/// that don't think, and for the engine on this Mac (its model never does).
enum BotThinking: String, Codable, CaseIterable, Identifiable {
    case off, low, medium, high
    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
    /// The budget sent to a provider that takes one: a number of tokens the
    /// model may spend on thinking. Nil for off, where nothing is asked for.
    var budget: Int? {
        switch self {
        case .off: return nil
        case .low: return 1024
        case .medium: return 4096
        case .high: return 16384
        }
    }
    /// OpenAI's reasoning effort string, where the model takes one.
    var effort: String? {
        switch self {
        case .off: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

/// The keys, in this Mac's keychain.
///
/// This Mac's own keychain, as ordinary keychain items under a service of the
/// app's, one for each provider and the host it was given for — account
/// "provider@host" — so a key is read only for the address it was given for
/// and sent nowhere else (see AIClient.request). This Mac only, readable while
/// the person is logged in, never synced: the same place, and the same way,
/// Search keeps passwords (see Vault). A copy built from source keeps its keys
/// apart from a signed Search's, because the keychain tells the two apart by
/// their signatures; a test run keeps its own under a service of its own, so a
/// made-up key never sits where a real one does.
///
/// Where the keychain won't take one at all — locked, or ruled out by policy —
/// what's pasted is kept in memory for the run and let go when it quits, and
/// Settings says so (see `available`).
///
/// A key is read the moment a request needs it and let go with the request:
/// never in the settings file, a published value, a log line or an error.
@MainActor
enum AIKeys {
    enum Saved { case kept, unavailable, failed }

    /// One key kept for a provider, and the host it was given for.
    struct Held {
        var host: String
        /// The key's last four, to tell two apart without reading either.
        var tail: String
    }

    private static let service = "com.officecommun.search.ai"

    /// Where this run's keys are kept: a test run's under a service of its
    /// own, so a made-up key never sits where a real one does.
    private static var place: String { Store.testing ? service + ".test" : service }

    /// Keys held for no longer than this run, where the keychain wouldn't take
    /// one (see save). None while keys are being kept properly.
    private static var rehearsal: [String: String] = [:]

    /// Whether the keychain refused a key this run: what Settings says about
    /// how long a pasted key lasts.
    private static var refused = false

    private static func account(_ provider: AIProvider) -> String { "\(provider.rawValue)@\(provider.host)" }

    private static func account(_ provider: AIProvider, host: String) -> String { "\(provider.rawValue)@\(host)" }

    /// Whether a key is kept in this Mac's keychain, and past this run of this
    /// copy: true wherever the keychain takes one, which is everywhere a
    /// person is running Search; false only where it wouldn't (see save).
    static var available: Bool { !refused }

    private static func query(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: place,
         kSecAttrAccount as String: account(provider)]
    }

    static func save(_ key: String, for provider: AIProvider) -> Saved {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !provider.isLocal else { return .failed }
        guard hold(key, for: provider) else {
            // Nowhere on this Mac to keep it: held for the run, and said so.
            rehearsal[account(provider)] = key
            refused = true
            return .unavailable
        }
        rehearsal[account(provider)] = nil
        refused = false
        return .kept
    }

    /// One key into this Mac's keychain, over whatever was kept for that host
    /// before.
    private static func hold(_ key: String, for provider: AIProvider, host: String? = nil) -> Bool {
        var item = query(provider)
        if let host { item[kSecAttrAccount as String] = account(provider, host: host) }
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = "Search — \(provider.name) key"
        // The last four, to tell keys apart in Settings without reading one.
        item[kSecAttrComment as String] = String(key.suffix(4))
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The key, for the request about to go out. Nil when there is none.
    static func key(for provider: AIProvider) -> String? {
        var asked = query(provider)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        if SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess,
           let data = found as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }
        return rehearsal[account(provider)]
    }

    /// "••••1a2b" for one that is kept, without reading the key itself.
    static func hint(for provider: AIProvider) -> String? {
        var asked = query(provider)
        asked[kSecReturnAttributes as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        if SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess,
           let attributes = found as? [String: Any] {
            return "••••" + (attributes[kSecAttrComment as String] as? String ?? "")
        }
        return rehearsal[account(provider)].map { "••••" + $0.suffix(4) }
    }

    /// Every key kept for a provider, whichever address it was given for: for
    /// the row that says a key is kept for another host, and offers to bring
    /// it along (see AIAssist.key).
    static func held(for provider: AIProvider) -> [Held] {
        let asked: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: place,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var found: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess,
              let rows = found as? [[String: Any]]
        else { return [] }
        let start = provider.rawValue + "@"
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String, account.hasPrefix(start)
            else { return nil }
            return Held(host: String(account.dropFirst(start.count)),
                        tail: row[kSecAttrComment as String] as? String ?? "")
        }
    }

    /// A key kept for another host of the same provider, kept now for this
    /// one: what the row does when an address is named after the key was given
    /// for the provider's own.
    static func carry(_ provider: AIProvider, from host: String) -> Saved {
        var asked = query(provider)
        asked[kSecAttrAccount as String] = account(provider, host: host)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data, let key = String(data: data, encoding: .utf8)
        else { return .failed }
        return save(key, for: provider)
    }

    static func forget(_ provider: AIProvider) {
        rehearsal[account(provider)] = nil
        SecItemDelete(query(provider) as CFDictionary)
        refused = false
    }

    /// One key kept for a provider under an address it no longer goes to.
    static func forget(_ provider: AIProvider, host: String) {
        var asked = query(provider)
        asked[kSecAttrAccount as String] = account(provider, host: host)
        SecItemDelete(asked as CFDictionary)
    }

    static func forgetAll() {
        AIProvider.allCases.forEach { provider in
            forget(provider)
            held(for: provider).forEach { forget(provider, host: $0.host) }
        }
    }
}
