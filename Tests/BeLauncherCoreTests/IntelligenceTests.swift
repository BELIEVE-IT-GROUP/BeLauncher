import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Bring Your Own Intelligence")
struct IntelligenceTests {

    private let local = IntelligenceProvider.named("ollama")!
    private let cloud = IntelligenceProvider.named("anthropic")!

    // MARK: - Routing

    @Test("confidential material never leaves the Mac by accident")
    func confidentialStaysLocal() throws {
        let router = ModelRouter(preferred: "anthropic")
        let chosen = try router.provider(for: .confidential, available: [cloud, local])
        #expect(chosen.id == "ollama", "it must fall back to a local model, not shrug and send it")
        #expect(chosen.isPrivate)
    }

    @Test("with no local model available, confidential work is refused rather than sent")
    func refusesRatherThanLeaks() {
        let router = ModelRouter(preferred: "anthropic")
        #expect(throws: IntelligenceError.blockedBySensitivity("Anthropic")) {
            try router.provider(for: .confidential, available: [cloud])
        }
    }

    @Test("ordinary work goes to whichever model the user preferred")
    func honoursPreference() throws {
        let router = ModelRouter(preferred: "anthropic")
        #expect(try router.provider(for: .ordinary, available: [local, cloud]).id == "anthropic")
        #expect(try router.provider(for: .personal, available: [local, cloud]).id == "anthropic")
    }

    @Test("a user who wants everything local gets everything local")
    func fullyLocalUser() throws {
        let router = ModelRouter(preferred: "ollama", localOnlyFor: Set(Sensitivity.allCases))
        for sensitivity in Sensitivity.allCases {
            #expect(try router.provider(for: sensitivity, available: [local, cloud]).isPrivate)
        }
    }

    @Test("with nothing configured it says so instead of failing obscurely")
    func nothingConfigured() {
        #expect(throws: IntelligenceError.noProviderConfigured) {
            try ModelRouter(preferred: nil).provider(for: .ordinary, available: [])
        }
    }

    // MARK: - Requests

    @Test("a cloud request carries the user's own key and goes straight to the provider")
    func requestShape() throws {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { $0 == "anthropic_api_key" ? "sk-user-own" : nil })
        let request = try client.build(
            IntelligenceRequest(system: "Sé breve", prompt: "Hola"),
            provider: cloud, model: "claude-sonnet-5"
        )
        #expect(request.url?.host == "api.anthropic.com", "no proxy of ours in the middle")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-user-own")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-sonnet-5")
        #expect(body["system"] as? String == "Sé breve")
    }

    @Test("a local request carries no key at all")
    func localNeedsNoKey() throws {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { _ in nil })
        let request = try client.build(IntelligenceRequest(prompt: "Hola"), provider: local,
                                       model: "llama3.2")
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("a missing key is named, not swallowed")
    func missingKey() {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { _ in nil })
        #expect(throws: IntelligenceError.missingKey("Anthropic")) {
            try client.build(IntelligenceRequest(prompt: "Hola"), provider: cloud, model: "x")
        }
    }

    // MARK: - Answers

    @Test("answers are read from every shape the providers use")
    func parsesEveryShape() {
        let openAI = #"{"choices":[{"message":{"role":"assistant","content":" Hola "}}]}"#
        #expect(IntelligenceClient.extractText(from: Data(openAI.utf8)) == "Hola")

        let anthropic = #"{"content":[{"type":"text","text":"Hola"},{"type":"text","text":" mundo"}]}"#
        #expect(IntelligenceClient.extractText(from: Data(anthropic.utf8)) == "Hola mundo")

        let failure = #"{"error":{"message":"rate limited"}}"#
        #expect(IntelligenceClient.extractText(from: Data(failure.utf8))?.contains("rate limited") == true)

        #expect(IntelligenceClient.extractText(from: Data("<html>".utf8)) == nil)
    }

    @Test("an unreachable model reads as a transport problem, never as an empty answer")
    func transportFailure() async {
        struct Offline: Error {}
        let client = IntelligenceClient(transport: { _ in throw Offline() }, keyLookup: { _ in "k" })
        await #expect(throws: IntelligenceError.self) {
            try await client.answer(IntelligenceRequest(prompt: "Hola"), using: local)
        }
    }

    @Test("every provider is reachable and distinct")
    func catalogue() {
        #expect(Set(IntelligenceProvider.all.map(\.id)).count == IntelligenceProvider.all.count)
        #expect(IntelligenceProvider.all.contains { $0.isPrivate }, "there must be a local option")
        for provider in IntelligenceProvider.all {
            #expect(URL(string: provider.endpoint) != nil)
            #expect(provider.transport == .local || !provider.keychainAccount.isEmpty)
        }
    }
}
