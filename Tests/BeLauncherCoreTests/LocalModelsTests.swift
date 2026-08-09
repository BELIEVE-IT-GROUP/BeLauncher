import Foundation
import Testing
@testable import BeLauncherCore

@Suite("Local model discovery")
struct LocalModelsDiscoveryContractTests {
    @Test("discovery parses Ollama and OpenAI-compatible catalogues without duplicates")
    func parsesCatalogues() {
        let ollama = Data(#"{"models":[{"name":"qwen2.5"},{"name":"qwen2.5"},{"name":" bge-m3 "}]}"#.utf8)
        let lmStudio = Data(#"{"data":[{"id":"local-model"},{"id":"local-model"}]}"#.utf8)

        #expect(LocalModels.models(in: ollama) == ["qwen2.5", "bge-m3"])
        #expect(LocalModels.models(in: lmStudio) == ["local-model"])
    }

    @Test("a saved model is used only while it is installed")
    func selectionIsBoundToDiscovery() {
        let installation = LocalModels.Installation(
            providerID: "ollama", name: "Ollama", models: ["qwen2.5", "bge-m3"])

        #expect(LocalModels.selectedModel(in: installation, saved: "qwen2.5") == "qwen2.5")
        #expect(LocalModels.selectedModel(in: installation, saved: "missing") == "qwen2.5")
        #expect(LocalModels.selectedModel(in: installation, saved: "bge-m3") == "qwen2.5")
    }

    @Test("discovery ignores offline and non-success local endpoints")
    func offlineEndpointIsIgnored() async throws {
        let ollama = try #require(ModelProviderRegistry.named("ollama"))
        let response = HTTPURLResponse(url: URL(string: ollama.modelsEndpoint!)!, statusCode: 503,
                                       httpVersion: nil, headerFields: nil)!
        let found = await LocalModels.installed(transport: { _ in
            (Data(#"{"models":[{"name":"qwen2.5"}]}"#.utf8), response)
        })

        #expect(found.isEmpty)
    }
}
