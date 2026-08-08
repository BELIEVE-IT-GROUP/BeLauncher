import Foundation
import Testing
@testable import BeLauncherCore

@Suite("AI BEL adapters")
struct BELAIActionHandlerTests {
    @Test("an existing AI verb runs through its stable ID and local provider")
    func aiBridgeUsesExistingRunner() async throws {
        let definition = try #require(BELActionCatalog.named("ai.verb.summarise"))
        let provider = IntelligenceProvider(id: "fixture", name: "Fixture", transport: .local,
                                            endpoint: "http://127.0.0.1/chat/completions",
                                            defaultModel: "fixture")
        let response = Data(#"{"choices":[{"message":{"content":"resultado local"}}]}"#.utf8)
        let client = IntelligenceClient(
            transport: { _ in (response, HTTPURLResponse(url: URL(string: "http://fixture")!,
                                                          statusCode: 200, httpVersion: nil,
                                                          headerFields: nil)!) },
            keyLookup: { _ in nil })
        let runner = AIVerbRunner(client: client, router: ModelRouter(preferred: "fixture"),
                                  providers: [provider])
        let handler = try #require(BELAIActionHandler(definition: definition, runner: runner))
        let input = try JSONEncoder().encode(BELTextActionInput(text: "texto de prueba"))
        let result = try await BELActionExecutor.execute(definition, input: input,
                                                         capabilities: .allGranted,
                                                         handler: handler)

        #expect(result.text == "resultado local")
        #expect(result.receipt == "ai:summarise")
    }

    @Test("the AI adapter rejects native and unavailable definitions")
    func adapterDoesNotPretend() throws {
        let provider = IntelligenceProvider(id: "fixture", name: "Fixture", transport: .local,
                                            endpoint: "http://127.0.0.1/chat/completions",
                                            defaultModel: "fixture")
        let runner = AIVerbRunner(client: IntelligenceClient(),
                                  router: ModelRouter(preferred: "fixture"), providers: [provider])
        let native = try #require(BELActionCatalog.named("brain.open"))
        #expect(BELAIActionHandler(definition: native, runner: runner) == nil)

        let unavailable = BELActionDefinition(id: "ai.future", kind: .ai,
                                              titleKey: "ai.future", aliases: ["future"],
                                              risk: .r0, adapter: .none,
                                              availability: .unavailable)
        #expect(BELAIActionHandler(definition: unavailable, runner: runner) == nil)
    }

    @Test("model tool calls are schema checked before the AI verb runs")
    func toolCallIsValidated() async throws {
        let definition = try #require(BELActionCatalog.named("ai.verb.summarise"))
        let provider = IntelligenceProvider(id: "fixture", name: "Fixture", transport: .local,
                                            endpoint: "http://127.0.0.1/chat/completions",
                                            defaultModel: "fixture")
        let response = Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)
        let client = IntelligenceClient(transport: { _ in
            (response, HTTPURLResponse(url: URL(string: "http://fixture")!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!)
        })
        let runner = AIVerbRunner(client: client, router: ModelRouter(preferred: "fixture"),
                                  providers: [provider])
        let handler = try #require(BELAIActionHandler(definition: definition, runner: runner))
        let result = try await handler.perform(toolCall: "{\"name\":\"ai.verb.summarise\",\"arguments\":{\"text\":\"hola\"}}")
        #expect(result.text == "ok")
        await #expect(throws: BELStructuredOutputError.unknownTool("ai.verb.fix")) {
            try await handler.perform(toolCall: "{\"name\":\"ai.verb.fix\",\"arguments\":{\"text\":\"hola\"}}")
        }
        await #expect(throws: BELStructuredOutputError.wrongType(field: "text", expected: .string)) {
            try await handler.perform(toolCall: "{\"name\":\"ai.verb.summarise\",\"arguments\":{\"text\":42}}")
        }
    }
}
