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

/// Streaming, which is the difference between 28 seconds of spinner and 28 seconds of watching an
/// answer arrive — and between a long answer finishing and a long answer timing out.
@Suite("Reading an answer as it arrives")
struct StreamingTests {

    @Test("the OpenAI shape, which also covers Ollama and LM Studio")
    func openAIShape() {
        #expect(IntelligenceClient.fragment(
            fromSSE: #"data: {"choices":[{"delta":{"content":"Hola"}}]}"#) == "Hola")
        #expect(IntelligenceClient.fragment(
            fromSSE: #"data: {"choices":[{"delta":{"content":" allí"}}]}"#) == " allí")
    }

    @Test("the Anthropic shape")
    func anthropicShape() {
        #expect(IntelligenceClient.fragment(
            fromSSE: #"data: {"type":"content_block_delta","delta":{"text":"Hola"}}"#) == "Hola")
    }

    @Test("the lines that carry nothing are skipped instead of appearing as empty text")
    func skipsNoise() {
        // A stream that yields empty strings looks exactly like a model that has hung.
        #expect(IntelligenceClient.fragment(fromSSE: "") == nil)
        #expect(IntelligenceClient.fragment(fromSSE: ": keep-alive") == nil)
        #expect(IntelligenceClient.fragment(fromSSE: "data: [DONE]") == nil)
        #expect(IntelligenceClient.fragment(fromSSE: "event: message_start") == nil)
        #expect(IntelligenceClient.fragment(fromSSE: "data: no soy json") == nil)
        #expect(IntelligenceClient.fragment(
            fromSSE: #"data: {"choices":[{"delta":{}}]}"#) == nil)
        #expect(IntelligenceClient.fragment(
            fromSSE: #"data: {"choices":[{"delta":{"content":""}}]}"#) == nil)
    }

    @Test("whitespace around the payload never breaks it")
    func tolerantOfSpacing() {
        #expect(IntelligenceClient.fragment(
            fromSSE: #"  data:  {"choices":[{"delta":{"content":"x"}}]}  "#) == "x")
    }

    @Test("fragments assembled in order rebuild the whole answer")
    func assembles() {
        let lines = ["data: {\"choices\":[{\"delta\":{\"content\":\"Hola\"}}]}",
                     "data: {\"choices\":[{\"delta\":{\"content\":\" allí\"}}]}",
                     "data: [DONE]"]
        #expect(lines.compactMap(IntelligenceClient.fragment(fromSSE:)).joined() == "Hola allí")
    }

    @Test("a streaming request tells the provider it wants a stream")
    func asksForAStream() throws {
        let client = IntelligenceClient()
        let ollama = try #require(IntelligenceProvider.named("ollama"))
        let request = try client.build(
            IntelligenceRequest(prompt: "hola", sensitivity: .personal),
            provider: ollama, model: "qwen2.5", streaming: true
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["stream"] as? Bool == true)

        // And a plain request must not, or the non-streaming parser gets an event stream.
        let plain = try client.build(
            IntelligenceRequest(prompt: "hola", sensitivity: .personal),
            provider: ollama, model: "qwen2.5"
        )
        let plainBody = try #require(plain.httpBody)
        let plainJSON = try #require(
            JSONSerialization.jsonObject(with: plainBody) as? [String: Any])
        #expect(plainJSON["stream"] == nil)
    }
}

@Suite("The pane filling as text arrives")
@MainActor
struct StreamingPaneTests {

    @Test("fragments accumulate instead of replacing each other")
    func accumulates() {
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { _ in })
        model.aiWorking("Traducir")
        model.aiStreaming(verb: "Traducir", fragment: "Hola")
        model.aiStreaming(verb: "Traducir", fragment: " allí")
        #expect(model.aiState == .answer(verb: "Traducir", text: "Hola allí"))
    }

    @Test("a different verb starts a new answer rather than appending to the old one")
    func newVerbStartsOver() {
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { _ in })
        model.aiStreaming(verb: "Traducir", fragment: "Hola")
        model.aiStreaming(verb: "Resumir", fragment: "En resumen")
        #expect(model.aiState == .answer(verb: "Resumir", text: "En resumen"))
    }
}
