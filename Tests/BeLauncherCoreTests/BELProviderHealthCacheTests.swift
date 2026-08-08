import Foundation
import Testing
@testable import BeLauncherCore

@Suite("Provider health cache")
struct BELProviderHealthCacheTests {
    final class Counter: @unchecked Sendable {
        var value = 0
    }

    @Test("health probes are cached until the TTL expires")
    func cachesWithinTTL() async throws {
        let provider = try #require(IntelligenceProvider.named("ollama"))
        let cache = BELProviderHealthCache(ttl: 60)
        let counter = Counter()
        let start = Date(timeIntervalSince1970: 100)
        let probe: @Sendable (IntelligenceProvider, String?) async -> IntelligenceProbeState = { _, _ in
            counter.value += 1
            return .configured
        }

        _ = await cache.snapshot(for: [provider], now: start, probe: probe)
        _ = await cache.snapshot(for: [provider], now: start.addingTimeInterval(30), probe: probe)
        #expect(counter.value == 1)

        _ = await cache.snapshot(for: [provider], now: start.addingTimeInterval(61), probe: probe)
        #expect(counter.value == 2)
    }

    @Test("a generation failure can immediately mark a provider offline")
    func recordsFailure() async throws {
        let provider = try #require(IntelligenceProvider.named("ollama"))
        let cache = BELProviderHealthCache(ttl: 60)
        await cache.record(BELProviderHealth(state: .offline("generation failed")),
                           for: provider.id)
        let health = await cache.snapshot(for: [provider], probe: { _, _ in .configured })

        #expect(health[provider.id]?.state == .offline("generation failed"))
    }
}
