import Foundation

/// Short-lived evidence for routing. It is intentionally in-memory: provider health is volatile,
/// and persisting an old "ready" state is how Settings ends up promising a dead local server.
public actor BELProviderHealthCache {
    private struct Cached: Sendable {
        let health: BELProviderHealth
        let expiresAt: Date
    }

    private var values: [String: Cached] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 30) {
        self.ttl = ttl
    }

    public func snapshot(
        for providers: [IntelligenceProvider],
        keyLookup: @escaping @Sendable (String) -> String? = { Keychain.get($0) },
        now: Date = .now,
        probe: @escaping @Sendable (IntelligenceProvider, String?) async -> IntelligenceProbeState = {
            provider, key in
            await IntelligenceProvider.probe(provider, key: key)
        }
    ) async -> [String: BELProviderHealth] {
        let fresh = providers.compactMap { provider -> (String, BELProviderHealth)? in
            guard let cached = values[provider.id], cached.expiresAt > now else { return nil }
            return (provider.id, cached.health)
        }
        let known = Set(fresh.map(\.0))
        let missing = providers.filter { !known.contains($0.id) }
        var result = Dictionary(uniqueKeysWithValues: fresh)

        await withTaskGroup(of: (String, BELProviderHealth).self) { group in
            for provider in missing {
                group.addTask {
                    let key = provider.transport == .directKey
                        ? keyLookup(provider.keychainAccount) : nil
                    let state = await probe(provider, key)
                    return (provider.id, BELProviderHealth(state: state))
                }
            }
            for await (id, health) in group {
                result[id] = health
                values[id] = Cached(health: health, expiresAt: now.addingTimeInterval(ttl))
            }
        }
        return result
    }

    public func record(_ health: BELProviderHealth, for providerID: String,
                       now: Date = .now) {
        values[providerID] = Cached(health: health, expiresAt: now.addingTimeInterval(ttl))
    }

    public func invalidate(providerID: String) {
        values.removeValue(forKey: providerID)
    }
}
