import Foundation

public struct BELProviderHealth: Sendable, Equatable {
    public let state: IntelligenceProbeState
    public let model: String?

    public init(state: IntelligenceProbeState, model: String? = nil) {
        self.state = state
        self.model = model
    }
}

public struct BELProviderRoute: Sendable, Equatable {
    public let providerID: String
    public let score: Int
    public let health: IntelligenceProbeState

    public init(providerID: String, score: Int, health: IntelligenceProbeState) {
        self.providerID = providerID
        self.score = score
        self.health = health
    }
}

public extension ModelRouter {
    /// Deterministic A3 routing. Offline providers are never candidates; configured providers
    /// remain usable as fallbacks but a provider that passed a real probe always wins.
    func rankedRoutes(
        for sensitivity: Sensitivity,
        available: [IntelligenceProvider],
        health: [String: BELProviderHealth] = [:],
        machine: MacCapabilitySnapshot? = nil
    ) throws -> [BELProviderRoute] {
        guard !available.isEmpty else { throw IntelligenceError.noProviderConfigured }
        let localOnly = localOnlyFor.contains(sensitivity)
        let snapshot = machine ?? MacCapabilityDetector.current()

        let candidates = available.compactMap { provider -> BELProviderRoute? in
            if localOnly, !provider.isPrivate { return nil }
            let status = health[provider.id] ?? BELProviderHealth(state: .ready)
            if case .offline = status.state { return nil }

            var score = 0
            switch status.state {
            case .ready: score += 300
            case .configured: score += 100
            case .needsSetup: return nil
            case .offline: return nil
            }
            // Preference breaks ties; it cannot promote an unprobed provider over one that
            // actually answered the health check.
            if provider.id == preferred { score += 150 }
            if provider.isPrivate { score += 50 }
            if localOnly { score += 500 }
            if snapshot.prefersSmallLocalModel, provider.isPrivate { score += 25 }
            if snapshot.networkAvailable == false, !provider.isPrivate { return nil }
            return BELProviderRoute(providerID: provider.id, score: score, health: status.state)
        }

        guard !candidates.isEmpty else {
            if localOnly, let first = available.first(where: { !$0.isPrivate }) {
                throw IntelligenceError.blockedBySensitivity(first.name)
            }
            throw IntelligenceError.noProviderConfigured
        }
        return candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.providerID < $1.providerID
        }
    }

    func providers(
        for sensitivity: Sensitivity,
        available: [IntelligenceProvider],
        health: [String: BELProviderHealth],
        machine: MacCapabilitySnapshot? = nil
    ) throws -> [IntelligenceProvider] {
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return try rankedRoutes(for: sensitivity, available: available, health: health,
                               machine: machine).compactMap { byID[$0.providerID] }
    }
}
