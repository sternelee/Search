import XCTest
@testable import Search

/// An address named for a provider in Settings (AI.swift, AIClient.allowed):
/// which of them are addresses at all, when one is used, and which host a key
/// is kept for once one is.
@MainActor
final class AIAddressTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AIProvider.mock = nil
        Store.settings.removeObject(forKey: AIProvider.addressesKey)
    }

    override func tearDown() {
        Store.settings.removeObject(forKey: AIProvider.addressesKey)
        AIKeys.forget(.openAI)
        super.tearDown()
    }

    private func name(_ address: String, for provider: AIProvider) {
        Store.settings.set([provider.rawValue: address], forKey: AIProvider.addressesKey)
    }

    func testAnAddressIsReadOnlyWhenItIsWhole() {
        XCTAssertEqual(AIProvider.address("https://relay.example/v1")?.host(), "relay.example")
        // Spaces around it, typed or pasted, are not part of it.
        XCTAssertEqual(AIProvider.address("  http://127.0.0.1:8080/v1  ")?.host(), "127.0.0.1")
        // http as well as https: named by hand, and it may be on this Mac.
        XCTAssertEqual(AIProvider.address("http://127.0.0.1:8080/v1")?.scheme, "http")
        for nothing in ["", "   ", "relay.example", "ftp://relay.example/v1", "https://", "https://user:pw@relay.example/v1"] {
            XCTAssertNil(AIProvider.address(nothing), "\"\(nothing)\" is not an address to send a key to")
        }
    }

    func testOnlyTheTwoThatTakeAnAddressOfTheirOwn() {
        XCTAssertTrue(AIProvider.openAI.takesAnotherAddress)
        XCTAssertTrue(AIProvider.anthropic.takesAnotherAddress)
        for provider in [AIProvider.gemini, .openRouter, .thisMac, .ollama, .lmStudio] {
            XCTAssertFalse(provider.takesAnotherAddress)
            // A name left in the file for one of them is not used either.
            name("https://relay.example/v1", for: provider)
            XCTAssertEqual(provider.base.host(), provider.own.host())
        }
    }

    func testANamedAddressIsWhereRequestsGo() {
        XCTAssertEqual(AIProvider.openAI.host, "api.openai.com")
        name("https://relay.example/v1", for: .openAI)
        XCTAssertEqual(AIProvider.openAI.host, "relay.example")
        XCTAssertEqual(AIProvider.openAI.base.absoluteString, "https://relay.example/v1")
        // Half an address typed on the way to a whole one changes nothing.
        name("https://relay.exam", for: .openAI)
        XCTAssertEqual(AIProvider.openAI.host, "relay.exam")
        name("relay.example", for: .openAI)
        XCTAssertEqual(AIProvider.openAI.host, "api.openai.com")
        // And taking it back leaves the provider where it was.
        name("", for: .openAI)
        XCTAssertEqual(AIProvider.openAI.host, "api.openai.com")
    }

    func testAllowedFollowsTheAddressNamed() {
        let own = URL(string: "https://api.openai.com/v1/chat/completions")!
        XCTAssertTrue(AIClient.allowed(own, for: .openAI))
        // The provider's own address is never asked over plain http.
        XCTAssertFalse(AIClient.allowed(URL(string: "http://api.openai.com/v1/chat/completions")!, for: .openAI))

        name("http://127.0.0.1:8080/v1", for: .openAI)
        XCTAssertTrue(AIClient.allowed(URL(string: "http://127.0.0.1:8080/v1/chat/completions")!, for: .openAI))
        // Named for another host, or named at all, the provider's own is not.
        XCTAssertFalse(AIClient.allowed(own, for: .openAI))
        XCTAssertFalse(AIClient.allowed(URL(string: "http://127.0.0.1:9090/v1/chat/completions")!, for: .openAI))

        // A key in the address is refused, so no key is ever in one.
        name("http://user:pw@127.0.0.1:8080/v1", for: .openAI)
        XCTAssertFalse(AIClient.allowed(URL(string: "http://127.0.0.1:8080/v1/chat/completions")!, for: .openAI))

        // A provider with no address of its own is still https only.
        XCTAssertFalse(AIClient.allowed(URL(string: "http://generativelanguage.googleapis.com/v1beta/models")!, for: .gemini))
    }

    func testAKeyIsKeptForTheHostItWasSavedUnder() {
        // A test run keeps keys in memory (see AIKeys.save), which is enough
        // to see which host a key belongs to.
        XCTAssertEqual(AIKeys.save("sk-one", for: .openAI), .kept)
        XCTAssertEqual(AIKeys.key(for: .openAI), "sk-one")
        // Naming an address moves the host, and the key does not follow it:
        // what was pasted for one host is never sent to another.
        name("https://relay.example/v1", for: .openAI)
        XCTAssertNil(AIKeys.key(for: .openAI))
        XCTAssertEqual(AIKeys.save("sk-two", for: .openAI), .kept)
        XCTAssertEqual(AIKeys.key(for: .openAI), "sk-two")
        // And back to the provider's own, where the first is still kept.
        name("", for: .openAI)
        XCTAssertEqual(AIKeys.key(for: .openAI), "sk-one")
    }
}
