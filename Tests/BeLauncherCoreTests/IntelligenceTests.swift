import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Bring Your Own Intelligence")
struct IntelligenceTests {

    private let local = IntelligenceProvider.named("ollama")!
    private let cloud = IntelligenceProvider.named("anthropic")!

    private final class AuditRecorder: @unchecked Sendable {
        var events: [BELPrivacyAuditEvent] = []
    }

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

    @Test("a configured fallback follows the preferred provider")
    func ordersFallbacks() throws {
        let router = ModelRouter(preferred: "ollama")
        #expect(try router.providers(for: .personal, available: [cloud, local]).map(\.id)
                == ["ollama", "anthropic"])
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

    @Test("local-only is enforced at the last request boundary")
    func localOnlyBoundary() {
        let client = IntelligenceClient(keyLookup: { _ in "user-key" })
        #expect(throws: IntelligenceError.blockedBySensitivity("Anthropic")) {
            try client.build(IntelligenceRequest(prompt: "private", localOnly: true),
                             provider: cloud, model: cloud.defaultModel)
        }
    }

    @Test("confidential requests are refused at the cloud boundary by default")
    func confidentialBoundary() {
        let client = IntelligenceClient(keyLookup: { _ in "user-key" })
        #expect(throws: IntelligenceError.blockedBySensitivity("Anthropic")) {
            try client.build(IntelligenceRequest(prompt: "company plan", sensitivity: .confidential),
                             provider: cloud, model: cloud.defaultModel)
        }
    }

    @Test("confidential cloud requests require an explicit boundary policy")
    func confidentialCloudPolicy() throws {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { _ in "user-key" },
                                        cloudAllowedFor: Set(Sensitivity.allCases))
        let request = try client.build(
            IntelligenceRequest(prompt: "approved cloud context", sensitivity: .confidential),
            provider: cloud, model: cloud.defaultModel)
        #expect(request.url?.host == "api.anthropic.com")
    }

    @Test("the cloud boundary redacts credentials from the actual request body")
    func cloudBoundaryRedactsCredentials() throws {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { _ in "sk-user-own" })
        let request = try client.build(
            IntelligenceRequest(system: "AUTH_TOKEN=sk-ant-api03-12345678901234567890",
                                 prompt: "Resume esto\nAPI_KEY=sk-proj-12345678901234567890"),
            provider: cloud, model: "claude-sonnet-5"
        )
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["system"] as? String == "[credential omitted]")
        #expect((body["messages"] as? [[String: String]])?.last?["content"]
                == "Resume esto\n[credential omitted]")
    }

    @Test("the cloud boundary redacts multiline private keys from the actual request body")
    func cloudBoundaryRedactsMultilinePrivateKeys() throws {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { _ in "sk-user-own" })
        let request = try client.build(
            IntelligenceRequest(prompt: """
            keep context
            -----BEGIN PRIVATE KEY-----
            MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCexample
            -----END PRIVATE KEY-----
            keep next task
            """),
            provider: cloud, model: "claude-sonnet-5"
        )

        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        let content = try #require(messages.last?["content"])
        #expect(content.contains("keep context"))
        #expect(content.contains("keep next task"))
        #expect(content.contains("[credential omitted]"))
        #expect(!content.contains("BEGIN PRIVATE KEY"))
        #expect(!content.contains("MIIEvQIBADAN"))
        #expect(!content.contains("END PRIVATE KEY"))
    }

    @Test("local providers keep the original text because it never leaves the Mac")
    func localKeepsContext() throws {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) })
        let request = try client.build(
            IntelligenceRequest(prompt: "API_KEY=sk-proj-12345678901234567890"),
            provider: local, model: "llama3.2"
        )
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.last?["content"]?.contains("sk-proj-") == true)
    }

    @Test("long-term Brain context is refused before a cloud request is built")
    func longTermContextIsLocalOnly() {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                         keyLookup: { _ in "user-key" })
        #expect(throws: IntelligenceError.blockedBySensitivity("Anthropic")) {
            try client.build(
                IntelligenceRequest(prompt: "private memory", brainContextLevel: .b3),
                provider: cloud, model: "claude-sonnet-5")
        }
    }

    @Test("the privacy audit records provider class and flags, never prompt content")
    func privacyAuditIsMetadataOnly() throws {
        let recorder = AuditRecorder()
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                         keyLookup: { _ in "user-key" },
                                         audit: { recorder.events.append($0) })
        _ = try client.build(
            IntelligenceRequest(system: "AUTH_TOKEN=sk-ant-api03-12345678901234567890",
                                 prompt: "hello", sensitivity: .personal),
            provider: cloud, model: "claude-sonnet-5")
        let event = try #require(recorder.events.first)
        #expect(event.providerID == "anthropic")
        #expect(event.providerClass == .cloud)
        #expect(event.brainContextLevel == .b0)
        #expect(event.localOnly == false)
        #expect(event.redactedSystem)
        #expect(event.redactedPrompt == false)

        let fields = Set(Mirror(reflecting: event).children.compactMap(\.label))
        #expect(fields == [
            "providerID", "providerClass", "sensitivity", "brainContextLevel", "localOnly",
            "redactedSystem", "redactedPrompt",
        ])
    }

    @Test("the privacy audit records localOnly separately from Brain context")
    func privacyAuditSeparatesLocalOnlyFromBrainContext() throws {
        let recorder = AuditRecorder()
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        audit: { recorder.events.append($0) })
        _ = try client.build(
            IntelligenceRequest(prompt: "memory", brainContextLevel: .b3),
            provider: local, model: "llama3.2")

        let event = try #require(recorder.events.first)
        #expect(event.providerClass == .local)
        #expect(event.brainContextLevel == .b3)
        #expect(event.localOnly == false)
    }

    @Test("OpenAI GPT-5 uses the current completion limit parameter")
    func openAIUsesCompletionTokens() throws {
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { _ in "sk-user-own" })
        let openAI = try #require(IntelligenceProvider.named("openai"))
        let request = try client.build(
            IntelligenceRequest(prompt: "Hola", maxTokens: 20),
            provider: openAI, model: "gpt-5"
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["max_completion_tokens"] as? Int == 20)
        #expect(json["max_tokens"] == nil)
    }

    @Test("Gemini uses its native endpoint, key header and request shape")
    func geminiRequestShape() throws {
        let gemini = try #require(IntelligenceProvider.named("gemini"))
        let client = IntelligenceClient(transport: { _ in (Data(), URLResponse()) },
                                        keyLookup: { _ in "google-user-key" })
        let request = try client.build(
            IntelligenceRequest(system: "Sé breve", prompt: "Hola", maxTokens: 20),
            provider: gemini, model: "gemini-2.5-pro"
        )

        #expect(request.url?.absoluteString ==
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "google-user-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["messages"] == nil)
        #expect((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 20)
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

        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"Hola Gemini"}]}}]}"#
        #expect(IntelligenceClient.extractText(from: Data(gemini.utf8)) == "Hola Gemini")

        let ollama = #"{"message":{"role":"assistant","content":"Hola local"}}"#
        #expect(IntelligenceClient.extractText(from: Data(ollama.utf8)) == "Hola local")

        let failure = #"{"error":{"message":"rate limited"}}"#
        #expect(IntelligenceClient.extractText(from: Data(failure.utf8)) == nil,
                "provider errors must be thrown, never rendered as successful answer text")

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

    @Test("a provider error can never be painted as a successful answer")
    func providerErrorIsNotAnAnswer() async {
        let openAI = IntelligenceProvider.named("openai")!
        let response = HTTPURLResponse(url: URL(string: openAI.endpoint)!, statusCode: 400,
                                       httpVersion: nil, headerFields: nil)!
        let payload = Data(#"{"error":{"message":"Unsupported parameter: max_tokens"}}"#.utf8)
        let client = IntelligenceClient(transport: { _ in (payload, response) },
                                        keyLookup: { _ in "sk-user-own" })

        await #expect(throws: IntelligenceError.transport(
            "Unsupported parameter: max_tokens")) {
            try await client.answer(IntelligenceRequest(prompt: "Hola"), using: openAI)
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

@Suite("Provider connectivity is evidence based")
struct IntelligenceProbeTests {

    private let ollama = IntelligenceProvider.named("ollama")!
    private let openAI = IntelligenceProvider.named("openai")!
    private let gemini = IntelligenceProvider.named("gemini")!
    private let anthropic = IntelligenceProvider.named("anthropic")!

    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    @Test("probe states expose configured, ready and unavailable without guessing")
    func probeStateSemantics() {
        #expect(IntelligenceProbeState.ready.isReadyForGeneration)
        #expect(IntelligenceProbeState.ready.isConfigured)
        #expect(IntelligenceProbeState.configured.isConfigured)
        #expect(!IntelligenceProbeState.configured.isReadyForGeneration)
        #expect(IntelligenceProbeState.needsSetup.isUnavailable)
        #expect(IntelligenceProbeState.offline("down").isUnavailable)
    }

    @Test("a local runner is ready only when its model catalogue is non-empty")
    func localCatalogueIsRequired() async {
        let empty = await IntelligenceProvider.probe(ollama, transport: { _ in
            (Data(#"{"models":[]}"#.utf8), HTTPURLResponse(url: URL(string: "http://localhost")!,
                                                              statusCode: 200, httpVersion: nil,
                                                              headerFields: nil)!)
        })
        #expect(empty == .offline("The local provider is running but returned no models."))

        let ready = await IntelligenceProvider.probe(ollama, transport: { _ in
            (Data(#"{"models":[{"name":"qwen2.5"}]}"#.utf8), HTTPURLResponse(url: URL(string: "http://localhost")!,
                                                                                 statusCode: 200,
                                                                                 httpVersion: nil,
                                                                                 headerFields: nil)!)
        })
        #expect(ready == .configured)
    }

    @Test("a cloud key is not a probe and an unauthorized response is offline")
    func cloudNeedsRealResponse() async {
        let missing = await IntelligenceProvider.probe(openAI, transport: { _ in
            (Data(), self.response())
        })
        #expect(missing == .needsSetup)

        let unauthorized = await IntelligenceProvider.probe(openAI, key: "stale",
            transport: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stale")
                return (Data(), self.response(401))
            })
        #expect(unauthorized == .offline("Provider answered HTTP 401."))
    }

    @Test("transport failures are visible instead of becoming ready")
    func transportFailure() async {
        struct Offline: Error {}
        let result = await IntelligenceProvider.probe(openAI, key: "key",
            transport: { _ in throw Offline() })
        #expect(result != .ready)
    }

    @Test("Gemini validates an API key with Google's native header")
    func geminiProbeShape() async {
        let result = await IntelligenceProvider.probe(gemini, key: "google-user-key",
            transport: { request in
                #expect(request.url?.absoluteString ==
                        "https://generativelanguage.googleapis.com/v1beta/models")
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "google-user-key")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return (Data(#"{"models":[{"name":"models/gemini-2.5-pro"}]}"#.utf8),
                        self.response())
            })
        #expect(result == .configured)
    }

    @Test("Anthropic validates keys against the models endpoint")
    func anthropicProbeShape() async {
        let result = await IntelligenceProvider.probe(anthropic, key: "anthropic-user-key",
            transport: { request in
                #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-user-key")
                return (Data(#"{"data":[{"id":"claude-sonnet-5"}]}"#.utf8), self.response())
            })
        #expect(result == .configured)
    }
}

/// Streaming, which is the difference between 28 seconds of spinner and 28 seconds of watching an
/// answer arrive — and between a long answer finishing and a long answer timing out.
@Suite("Reading an answer as it arrives")
struct StreamingTests {

    @Test("an SSE provider error is never accepted as generated text")
    func streamErrorIsNotText() {
        let line = #"data: {"error":{"message":"invalid model"}}"#
        #expect(IntelligenceClient.providerError(fromStreamLine: line) == "invalid model")
        #expect(IntelligenceClient.fragment(fromSSE: line) == nil)
    }

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
