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
        #expect(providers.first(where: { $0.providerID == "ollama" })?.capabilities
                == [.chat, .embeddings])
    }

    @Test("local runtimes share the stable Brain identity")
    func localCoreFacade() throws {
        let locals = BELLanguageModelProviderFactory.localCoreProviders()
        #expect(Set(locals.map(\.providerID)) == Set([BELLocalCore.id]))
        #expect(Set(locals.map(\.backend.descriptor.id)) == Set(["ollama", "lmstudio"]))
        #expect(locals.allSatisfy { $0.capabilities.contains(.chat) })
        #expect(locals.allSatisfy { $0.capabilities.contains(.embeddings) })
    }

    @Test("factory collapses local providers and keeps cloud identities")
    func factoryProviderIdentity() throws {
        let ollama = try #require(IntelligenceProvider.named("ollama"))
        let lmStudio = try #require(IntelligenceProvider.named("lmstudio"))
        let anthropic = try #require(IntelligenceProvider.named("anthropic"))

        #expect(BELLanguageModelProviderFactory.provider(for: ollama).providerID
                == BELLocalCore.id)
        #expect(BELLanguageModelProviderFactory.provider(for: lmStudio).providerID
                == BELLocalCore.id)
        #expect(BELLanguageModelProviderFactory.provider(for: anthropic).providerID
                == "anthropic")
    }

    @Test("provider metadata exposes placement and never invents a context window")
    func providerMetadataIsExplicit() async throws {
        let provider = try #require(IntelligenceProvider.named("ollama"))
        let model = BELHTTPModelProvider(descriptor: provider)

        let contract: any BELLanguageModelProvider = model
        #expect(contract.placement == .local)
        let contextWindow = await contract.contextWindow
        #expect(contextWindow == nil)
    }

    @Test("availability performs a real local discovery probe")
    func availabilityUsesProbe() async throws {
        let provider = try #require(IntelligenceProvider.named("ollama"))
        let response = HTTPURLResponse(url: URL(string: provider.modelsEndpoint!)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let model = BELHTTPModelProvider(
            descriptor: provider,
            client: IntelligenceClient(transport: { _ in
                (Data(#"{"models":[{"name":"qwen"}]}"#.utf8), response)
            }))

        #expect(await model.isAvailable())
    }

    @Test("local generation refuses an undiscovered default model")
    func localGenerationRequiresDiscoveredModel() async throws {
        let provider = try #require(IntelligenceProvider.named("ollama"))
        let called = RequestBox()
        let model = BELHTTPModelProvider(
            descriptor: provider,
            client: IntelligenceClient(transport: { request in
                called.value = request
                return (Data(#"{"message":{"content":"should not arrive"}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }))

        await #expect(throws: IntelligenceError.noProviderConfigured) {
            try await model.generate(BELModelRequest(prompt: "hola"))
        }
        #expect(called.value == nil)
    }

    @Test("cancelled generation stops before making a provider request")
    func cancelledGenerationStopsBeforeRequest() async throws {
        let provider = try #require(IntelligenceProvider.named("ollama"))
        let called = RequestBox()
        let model = BELHTTPModelProvider(
            descriptor: provider,
            client: IntelligenceClient(transport: { request in
                called.value = request
                return (Data(#"{"message":{"content":"should not arrive"}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }))
        let task = Task {
            try await model.generate(BELModelRequest(prompt: "hola"))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(called.value == nil)
    }

    @Test("Foundation Models is either a real runtime provider or absent")
    func foundationModelsHasNoFalsePositive() {
        let provider = BELLanguageModelProviderFactory.foundationModelsProvider()
        #expect(provider == nil || provider?.providerID == "apple.foundation.models")
    }
}
