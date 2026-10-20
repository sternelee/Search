import Foundation

/// One short message to a provider, and what came back: the Test row in
/// Settings › AI and the bench's `ai test` ask through here, so what a person
/// reads on the page is what a suite checks. Nothing is kept: the answer goes
/// back to whoever asked, and no further.
@MainActor
enum AITest {
    /// Asked of the model: a word back is enough to know the address, the key
    /// and the model all work together.
    static let question = "Reply with the single word: ready"
    /// Said to it, so the answer is an answer and not a greeting.
    static let system = "You are a test message from a web browser's settings."
    /// The most of an answer kept: a test needs a word, not an essay.
    static let most = 300
    /// How long a test waits before saying so: a test that hangs tells you
    /// nothing, and a person watching one is owed an answer either way.
    static let patience: TimeInterval = 30

    /// What the provider said, trimmed. Throws what the request throws —
    /// AIError.noKey when no key is kept, refusedHost for an address that
    /// isn't the provider's, unreachable when it can't be got to — so the
    /// caller can say it plainly.
    static func answer(_ provider: AIProvider, model: String, key: String?) async throws -> String {
        let messages = [AIMessage(role: .user, text: question)]
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: system, messages: messages)
            : AIClient.shared.stream(provider, model: model, system: system, messages: messages,
                                     key: key, patience: patience)
        var whole = ""
        for try await piece in stream {
            // The answer, not a thinking model's thoughts (see AIPiece).
            if piece.kind == .answer { whole += piece.words }
            if whole.count >= most { break }
        }
        return whole.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
