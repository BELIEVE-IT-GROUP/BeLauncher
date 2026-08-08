import Foundation
import Testing
@testable import BeLauncherCore

@Suite("BEL language model provider contract")
struct BELLanguageModelProviderTests {
    final class RequestBox: @unchecked Sendable {
        var value: URLRequest?
    }

    @Test("HTTP provider adapts a typed request and response")
    func adaptsRequestAndResponse() async throws {
        let provider = try #require(IntelligenceProvider.named("ollama"))
        let response = HTTPURLResponse(url: URL(string: provider.endpoint)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let captured = RequestBox()
        let client = IntelligenceClient(transport: { request in
            captured.value = request
            return (Data(#"{"message":{"content":"respuesta local"}}"#.utf8), response)
        })
        let model = BELHTTPModelProvider(descriptor: provider, client: client)

        let result = try await model.generate(
            BELModelRequest(system: "Sé breve", prompt: "Hola", sensitivity: .ordinary,
                            maxTokens: 16),
            model: "qwen2.5"
        )

        #expect(result.text == "respuesta local")
        #expect(result.providerID == "ollama")
        #expect(result.model == "qwen2.5")
        #expect(captured.value?.url?.absoluteString == provider.endpoint)
        #expect(captured.value?.httpBody?.isEmpty == false)
    }

    @Test("factory exposes only the canonical chat providers")
    func factoryUsesCanonicalCatalogue() {
        let providers = BELLanguageModelProviderFactory.httpProviders()
        #expect(Set(providers.map(\.providerID))
                == Set(ModelProviderRegistry.supporting(.chat).map(\.id)))
        #expect(providers.allSatisfy { $0.capabilities == [.chat] })
    }
}
