import XCTest
@testable import Search

// The answer told apart from the thinking that came before it, as each way of
// writing a stream says it (see AIClient.piece): the answer's deltas, and a
// thinking model's thoughts — OpenAI's reasoning, Anthropic's thinking, Gemini's
// thought parts — each come back as their own kind of piece, and nothing else
// comes back at all.

final class AIPieceTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "aipiece-\(getpid())", 1)
        super.setUp()
    }

    // MARK: - OpenAI's way of writing it

    func testOpenAIAnswerContent() {
        let json: [String: Any] = ["choices": [["delta": ["content": "Hello"]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .answer)
        XCTAssertEqual(piece?.words, "Hello")
    }

    func testOpenAIReasoningIsThought() {
        let json: [String: Any] = ["choices": [["delta": ["reasoning": "Thinking it over"]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .thought)
        XCTAssertEqual(piece?.words, "Thinking it over")
    }

    func testOpenAIReasoningContentIsThought() {
        // The same thoughts under the older name some gateways use.
        let json: [String: Any] = ["choices": [["delta": ["reasoning_content": "Still thinking"]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .thought)
        XCTAssertEqual(piece?.words, "Still thinking")
    }

    func testOpenAIThinkingIsThought() {
        // A gateway in front of a model that thinks can name the field
        // `thinking`, the name the model's own API uses.
        let json: [String: Any] = ["choices": [["delta": ["thinking": "Thinking it over"]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .thought)
        XCTAssertEqual(piece?.words, "Thinking it over")
    }

    func testOpenAIReasoningDetailsIsThought() {
        // OpenRouter's list of reasoning details, the text of each joined.
        let details: [[String: Any]] = [
            ["type": "reasoning.text", "text": "Thinking"],
            ["type": "reasoning.text", "text": " it over"],
        ]
        let json: [String: Any] = ["choices": [["delta": ["reasoning_details": details]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .thought)
        XCTAssertEqual(piece?.words, "Thinking it over")
    }

    func testOpenAIEmptyContentBesideReasoningIsThought() {
        // One delta holding an empty answer and the thought: the thought is
        // the thing said, not the empty answer.
        let json: [String: Any] = ["choices": [["delta": ["content": "", "reasoning": "Thinking it over"]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .thought)
        XCTAssertEqual(piece?.words, "Thinking it over")
    }

    func testOpenAISpaceContentStaysAnswer() {
        // A single space is a word of the answer, not an empty delta.
        let json: [String: Any] = ["choices": [["delta": ["content": " "]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .answer)
        XCTAssertEqual(piece?.words, " ")
    }

    func testOpenAIAnswerBeatsReasoning() {
        // One delta holding both the thought and its answer: the answer is
        // what is returned (a gateway that writes them together).
        let json: [String: Any] = ["choices": [["delta": ["content": "Hello", "reasoning": "Thinking"]]]]
        let piece = AIClient.piece(.openAI, json)
        XCTAssertEqual(piece?.kind, .answer)
        XCTAssertEqual(piece?.words, "Hello")
    }

    func testOpenAIEmptyDeltaIsNothing() {
        let json: [String: Any] = ["choices": [["delta": ["role": "assistant"]]]]
        XCTAssertNil(AIClient.piece(.openAI, json))
    }

    // MARK: - Anthropic's way of writing it

    func testAnthropicTextDeltaIsAnswer() {
        let json: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": "Hello"],
        ]
        let piece = AIClient.piece(.anthropic, json)
        XCTAssertEqual(piece?.kind, .answer)
        XCTAssertEqual(piece?.words, "Hello")
    }

    func testAnthropicThinkingDeltaIsThought() {
        let json: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "thinking_delta", "thinking": "Thinking it over"],
        ]
        let piece = AIClient.piece(.anthropic, json)
        XCTAssertEqual(piece?.kind, .thought)
        XCTAssertEqual(piece?.words, "Thinking it over")
    }

    func testAnthropicOtherEventsAreNothing() {
        let json: [String: Any] = ["type": "message_start", "message": ["model": "one"]]
        XCTAssertNil(AIClient.piece(.anthropic, json))
    }

    // MARK: - Gemini's way of writing it

    func testGeminiPlainPartsAreAnswer() {
        let json: [String: Any] = [
            "candidates": [["content": ["parts": [["text": "Hello"], ["text": " there"]]]]],
        ]
        let piece = AIClient.piece(.gemini, json)
        XCTAssertEqual(piece?.kind, .answer)
        XCTAssertEqual(piece?.words, "Hello there")
    }

    func testGeminiThoughtPartsAreThought() {
        let json: [String: Any] = [
            "candidates": [["content": ["parts": [["text": "Thinking it over", "thought": true]]]]],
        ]
        let piece = AIClient.piece(.gemini, json)
        XCTAssertEqual(piece?.kind, .thought)
        XCTAssertEqual(piece?.words, "Thinking it over")
    }

    func testGeminiMixedPartsAnswerFirst() {
        // One event holding both: a thought and its answer — the answer is
        // the thing returned; a thought the same event holds goes by (the
        // two come in their own events, one at a time, when they come).
        let json: [String: Any] = [
            "candidates": [["content": ["parts": [
                ["text": "Thinking", "thought": true],
                ["text": "Hello"],
            ]]]],
        ]
        let piece = AIClient.piece(.gemini, json)
        XCTAssertEqual(piece?.kind, .answer)
        XCTAssertEqual(piece?.words, "Hello")
    }

    func testGeminiNoPartsIsNothing() {
        let json: [String: Any] = ["candidates": [["content": ["parts": []]]]]
        XCTAssertNil(AIClient.piece(.gemini, json))
    }
}
