import Foundation

public struct BELProviderHealth: Sendable, Equatable {
    public let state: IntelligenceProbeState
    public let model: String?
    public let observedAt: Date

    public init(state: IntelligenceProbeState, model: String? = nil, observedAt: Date = .now) {
        self.state = state
        self.model = model
        self.observedAt = observedAt
    }

    public func isFresh(at now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(observedAt) >= 0 && now.timeIntervalSince(observedAt) <= maxAge
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
        machine: MacCapabilitySnapshot? = nil,
        routePolicy: BELActionDefinition.RoutePolicy? = nil,
        requiredCapabilities: Set<ModelCapability> = [.chat],
        freshness: BELActionDefinition.Freshness = .notRequired,
        now: Date = .now,
        healthMaxAge: TimeInterval = 30
    ) throws -> [BELProviderRoute] {
        guard !available.isEmpty else { throw IntelligenceError.noProviderConfigured }
        let localOnly = localOnlyFor.contains(sensitivity) || routePolicy == .localOnly
        let snapshot = machine ?? MacCapabilityDetector.current()
        let capabilities = requiredCapabilities.union(freshness == .required ? [.web] : [])

        let candidates = available.compactMap { provider -> BELProviderRoute? in
            if localOnly, !provider.isPrivate { return nil }
            guard provider.capabilities.isSuperset(of: capabilities) else { return nil }
            // A missing snapshot is not proof that generation works. Callers that need a route
            // must obtain one through BELProviderHealthCache first; an unobserved provider may be
            // considered configured, but never healthy by default.
            let status = health[provider.id] ?? BELProviderHealth(state: .configured)
            if case .offline = status.state { return nil }
            if health[provider.id] != nil && !status.isFresh(at: now, maxAge: healthMaxAge) {
                return nil
            }

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
            if routePolicy == .cloudPreferred && !provider.isPrivate { score += 75 }
            if routePolicy == .localFirst && provider.isPrivate { score += 25 }
            if snapshot.prefersSmallLocalModel, provider.isPrivate { score += 25 }
            if provider.isPrivate && snapshot.thermalState == .critical { score -= 100 }
            if provider.isPrivate && snapshot.memoryPressure == .critical { score -= 100 }
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
        machine: MacCapabilitySnapshot? = nil,
        routePolicy: BELActionDefinition.RoutePolicy? = nil,
        requiredCapabilities: Set<ModelCapability> = [.chat],
        freshness: BELActionDefinition.Freshness = .notRequired,
        now: Date = .now,
        healthMaxAge: TimeInterval = 30
    ) throws -> [IntelligenceProvider] {
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return try rankedRoutes(for: sensitivity, available: available, health: health,
                               machine: machine, routePolicy: routePolicy,
                               requiredCapabilities: requiredCapabilities,
                               freshness: freshness, now: now,
                               healthMaxAge: healthMaxAge).compactMap { byID[$0.providerID] }
    }
}
