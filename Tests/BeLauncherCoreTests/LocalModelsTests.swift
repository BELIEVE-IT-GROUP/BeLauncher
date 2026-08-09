import Foundation
import Testing
@testable import BeLauncherCore

@Suite("Local model discovery")
struct LocalModelsDiscoveryContractTests {
    actor RequestLog {
        private(set) var urls: [String] = []

        func record(_ url: String) {
            urls.append(url)
        }
    }

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

    @Test("discovery calls real catalogue endpoints and returns chat models only")
    func discoveryUsesProviderCatalogues() async throws {
        let ollama = try #require(ModelProviderRegistry.named("ollama"))
        let lmStudio = try #require(ModelProviderRegistry.named("lmstudio"))
        let log = RequestLog()
        let found = await LocalModels.installed(transport: { request in
            let url = try #require(request.url)
            await log.record(url.absoluteString)
            let body: Data
            if url.absoluteString == ollama.modelsEndpoint {
                body = Data(#"{"models":[{"name":"qwen2.5"},{"name":"nomic-embed-text"}]}"#.utf8)
            } else if url.absoluteString == lmStudio.modelsEndpoint {
                body = Data(#"{"data":[{"id":"local-chat"},{"id":"bge-m3"}]}"#.utf8)
            } else {
                body = Data(#"{"models":[]}"#.utf8)
            }
            let response = HTTPURLResponse(url: url, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        })

        let byProvider = Dictionary(uniqueKeysWithValues: found.map { ($0.providerID, $0.models) })
        let requestedURLs = await log.urls
        #expect(Set(requestedURLs) == Set([ollama.modelsEndpoint!, lmStudio.modelsEndpoint!]))
        #expect(byProvider["ollama"] == ["qwen2.5"])
        #expect(byProvider["lmstudio"] == ["local-chat"])
    }

    @Test("embedding-only catalogues are not usable chat backends")
    func embeddingOnlyCatalogueIsIgnored() async {
        let found = await LocalModels.installed(transport: { request in
            let url = request.url ?? URL(string: "http://127.0.0.1")!
            let body = url.absoluteString.contains("1234")
                ? Data(#"{"data":[{"id":"bge-m3"}]}"#.utf8)
                : Data(#"{"models":[{"name":"nomic-embed-text"}]}"#.utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        })

        #expect(found.isEmpty)
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
