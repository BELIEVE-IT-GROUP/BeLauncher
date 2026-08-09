import Foundation
import Testing
@testable import BeLauncherCore

@Suite("Deterministic model routing")
struct ModelRoutingTests {
    private let local = IntelligenceProvider.named("ollama")!
    private let cloud = IntelligenceProvider.named("openai")!

    @Test("offline providers never become routes")
    func offlineIsExcluded() throws {
        let router = ModelRouter(preferred: "ollama")
        let routes = try router.rankedRoutes(
            for: .personal,
            available: [local, cloud],
            health: [
                "ollama": BELProviderHealth(state: .offline("connection refused")),
                "openai": BELProviderHealth(state: .ready),
            ]
        )

        #expect(routes.map(\.providerID) == ["openai"])
    }

    @Test("ready beats configured even when configured is preferred")
    func readinessBeatsPreference() throws {
        let router = ModelRouter(preferred: "openai")
        let routes = try router.rankedRoutes(
            for: .personal,
            available: [local, cloud],
            health: [
                "ollama": BELProviderHealth(state: .ready),
                "openai": BELProviderHealth(state: .configured),
            ]
        )

        #expect(routes.first?.providerID == "ollama")
        #expect(routes.first?.health == .ready)
    }

    @Test("confidential routing refuses cloud when local is not healthy")
    func confidentialNeedsLocal() {
        let router = ModelRouter(preferred: "openai")
        #expect(throws: IntelligenceError.blockedBySensitivity("OpenAI")) {
            try router.rankedRoutes(
                for: .confidential,
                available: [local, cloud],
                health: ["ollama": BELProviderHealth(state: .offline("down")),
                         "openai": BELProviderHealth(state: .ready)]
            )
        }
    }

    @Test("an 8 GB Mac prefers a local route when scores otherwise tie")
    func smallMachinePrefersLocal() throws {
        let router = ModelRouter(preferred: nil)
        let routes = try router.rankedRoutes(
            for: .personal,
            available: [cloud, local],
            health: ["ollama": BELProviderHealth(state: .ready),
                     "openai": BELProviderHealth(state: .ready)],
            machine: MacCapabilitySnapshot(architecture: .appleSilicon, unifiedMemoryGB: 8)
        )

        #expect(routes.first?.providerID == "ollama")
    }

    @Test("a provider without the requested capability is never a route")
    func capabilityMismatchIsExcluded() {
        let provider = IntelligenceProvider(id: "text-only", name: "Text only",
                                             transport: .local,
                                             endpoint: "http://127.0.0.1:1/chat",
                                             defaultModel: "text", capabilities: [.chat])
        #expect(throws: IntelligenceError.noProviderConfigured) {
            try ModelRouter(preferred: nil).rankedRoutes(
                for: .personal, available: [provider],
                health: ["text-only": BELProviderHealth(state: .ready)],
                requiredCapabilities: [.transcription])
        }
    }

    @Test("without an explicit preference, a usable local runtime excludes cloud")
    func localIsTheDefault() throws {
        let router = ModelRouter(preferred: nil)
        let routes = try router.rankedRoutes(
            for: .personal,
            available: [cloud, local],
            health: ["ollama": BELProviderHealth(state: .configured),
                     "openai": BELProviderHealth(state: .ready)]
        )

        #expect(routes.map(\.providerID) == ["ollama"])
    }

    @Test("stale ready evidence is not accepted as current health")
    func staleHealthIsExcluded() {
        let old = Date(timeIntervalSinceNow: -31)
        #expect(throws: IntelligenceError.noProviderConfigured) {
            try ModelRouter(preferred: nil).rankedRoutes(
                for: .personal, available: [local],
                health: ["ollama": BELProviderHealth(state: .ready, observedAt: old)],
                now: Date(), healthMaxAge: 30)
        }
    }

    @Test("freshness-required routes refuse providers without a web capability")
    func freshnessRequiresWebCapability() {
        #expect(throws: IntelligenceError.noProviderConfigured) {
            try ModelRouter(preferred: nil).rankedRoutes(
                for: .ordinary, available: [local, cloud],
                health: ["ollama": BELProviderHealth(state: .ready),
                         "openai": BELProviderHealth(state: .ready)],
                freshness: .required)
        }
    }
}
