import Foundation
import Testing
@testable import BeLauncherCore

@Suite("Model provider registry")
struct ModelProviderRegistryTests {
    @Test("the router and the registry expose the same chat provider identities")
    func chatProvidersHaveOneCatalogue() {
        #expect(Set(IntelligenceProvider.all.map(\.id)) ==
                Set(ModelProviderRegistry.supporting(.chat).map(\.id)))
        #expect(ModelProviderRegistry.named("openai")?.keychainAccount == "openai_api_key")
    }

    @Test("provider state distinguishes a missing key from an offline local runner")
    func stateIsActionable() throws {
        let openAI = try #require(ModelProviderRegistry.named("openai"))
        let ollama = try #require(ModelProviderRegistry.named("ollama"))

        #expect(openAI.state() == .needsSetup)
        #expect(openAI.state(configuredKeyAccounts: ["openai_api_key"]) == .ready)
        #expect(ollama.state() == .offline)
        #expect(ollama.state(localProviderIDs: ["ollama"]) == .ready)
    }

    @Test("embedding capability is visible without pretending an embedding model can chat")
    func capabilitiesStaySeparate() {
        #expect(ModelProviderRegistry.supporting(.embeddings).map(\.id) == ["ollama", "lmstudio"])
        #expect(ModelProviderRegistry.supporting(.transcription).isEmpty)
    }

    @Test("local discovery and management endpoints come from the same descriptor")
    func localLifecycleHasOneSource() throws {
        let ollama = try #require(ModelProviderRegistry.named("ollama"))
        #expect(ollama.modelsEndpoint?.hasSuffix("/api/tags") == true)
        #expect(ollama.managementEndpoint == "http://127.0.0.1:11434")
        #expect(ModelProviderRegistry.named("anthropic")?.modelsEndpoint == nil)
    }
}

@Suite("Ingestion checkpoints")
struct IngestionCheckpointTests {
    @Test("a checkpoint cannot cross source boundaries")
    func sourceScope() {
        let checkpoint = IngestionCheckpoint(source: "apple-mail", windowStart: .now,
                                              phase: .writing)
        #expect(checkpoint.canResume(source: "apple-mail"))
        #expect(!checkpoint.canResume(source: "messages"))
    }
}

@Suite("Durable model installation state")
struct InstallProgressStoreTests {
    @Test("snapshots survive relaunch and replace only their provider")
    func roundTripAndScope() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-progress-\(UUID().uuidString).json")
        let ollama = InstallProgressSnapshot(providerID: "ollama", model: "bge-m3",
                                              phase: .downloading, step: "download",
                                              completedBytes: 4, totalBytes: 10)
        let qwen = InstallProgressSnapshot(providerID: "qwen-asr", model: "asr",
                                           phase: .failed, message: "network")
        try InstallProgressStore.save(ollama, to: url)
        try InstallProgressStore.save(qwen, to: url)
        #expect(InstallProgressStore.load(providerID: "ollama", from: url) == ollama)
        #expect(InstallProgressStore.load(providerID: "qwen-asr", from: url) == qwen)

        let replacement = InstallProgressSnapshot(providerID: "ollama", model: "bge-m3",
                                                   phase: .ready)
        try InstallProgressStore.save(replacement, to: url)
        #expect(InstallProgressStore.load(providerID: "ollama", from: url) == replacement)
        #expect(InstallProgressStore.load(providerID: "qwen-asr", from: url) == qwen)
    }
}

@Suite("Shared installer diagnostics")
struct InstallDiagnosticsTests {
    @Test("disk preflight distinguishes enough, insufficient and unknown")
    func diskStates() {
        #expect(InstallDiagnostics.disk(requiredBytes: 10, freeBytes: 11)
                == .enough(freeBytes: 11))
        #expect(InstallDiagnostics.disk(requiredBytes: 10, freeBytes: 9)
                == .insufficient(freeBytes: 9))
        #expect(InstallDiagnostics.disk(requiredBytes: 10, freeBytes: nil) == .unknown)
    }

    @Test("network errors use the same actionable categories")
    func networkStates() {
        #expect(InstallDiagnostics.networkFailure(from: "The network timed out") == .offline)
        #expect(InstallDiagnostics.networkFailure(from: "connection refused")
                == .serverUnavailable)
        #expect(InstallDiagnostics.networkFailure(from: "unexpected certificate")
                == .other("unexpected certificate"))
    }
}
