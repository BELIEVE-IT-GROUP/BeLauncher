import Foundation

/// Numeric telemetry from one speculative cycle. It intentionally has no prompt or token data.
public struct BELMTPCycleObservation: Sendable, Equatable {
    public let modelRevision: String
    public let draftedTokens: Int
    public let acceptedTokens: Int
    public let draftMilliseconds: Double
    public let verifyMilliseconds: Double
    public let ordinaryTokenMilliseconds: Double
    public let memoryPressure: Bool
    public let failed: Bool

    public init(modelRevision: String, draftedTokens: Int, acceptedTokens: Int,
                draftMilliseconds: Double, verifyMilliseconds: Double,
                ordinaryTokenMilliseconds: Double, memoryPressure: Bool = false,
                failed: Bool = false) {
        self.modelRevision = modelRevision
        self.draftedTokens = draftedTokens
        self.acceptedTokens = acceptedTokens
        self.draftMilliseconds = draftMilliseconds
        self.verifyMilliseconds = verifyMilliseconds
        self.ordinaryTokenMilliseconds = ordinaryTokenMilliseconds
        self.memoryPressure = memoryPressure
        self.failed = failed
    }

    public var isValid: Bool {
        !modelRevision.isEmpty && draftedTokens > 0 && acceptedTokens >= 0
            && acceptedTokens <= draftedTokens
            && draftMilliseconds > 0 && verifyMilliseconds > 0
            && ordinaryTokenMilliseconds > 0
    }

    public var acceptanceRate: Double {
        guard draftedTokens > 0 else { return 0 }
        return Double(acceptedTokens) / Double(draftedTokens)
    }

    public var speculativeTokensPerSecond: Double {
        let tokens = Double(acceptedTokens + 1)
        return tokens / ((draftMilliseconds + verifyMilliseconds) / 1000)
    }

    public var ordinaryTokensPerSecond: Double {
        1000 / ordinaryTokenMilliseconds
    }

    /// The scheduler uses the same accounting as the upstream drafter: accepted draft tokens
    /// plus the verified bonus token. This is numeric telemetry only; no prompt or token values
    /// enter the policy.
    public var acceptedTokensIncludingBonus: Int {
        acceptedTokens + 1
    }
}

/// A fail-closed adaptive policy for an upstream MTP executor.
///
/// LiteRT-LM binds draft length to a compiled signature shape. `supportedDraftSteps` therefore
/// represents already-compiled variants; this policy never invents a length the executor cannot
/// accept. Until enough numeric evidence exists, it returns ordinary decoding.
public struct BELMTPScheduler: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        public let supportedDraftSteps: [Int]
        public let initialDraftSteps: Int
        public let minimumSamples: Int
        public let increaseAcceptance: Double
        public let decreaseAcceptance: Double
        public let minimumSpeedup: Double
        public let maxFailures: Int

        public init(supportedDraftSteps: [Int] = [1, 2, 4], initialDraftSteps: Int = 1,
                    minimumSamples: Int = 3, increaseAcceptance: Double = 0.80,
                    decreaseAcceptance: Double = 0.35, minimumSpeedup: Double = 0.05,
                    maxFailures: Int = 2) {
            self.supportedDraftSteps = Array(Set(supportedDraftSteps.filter { $0 > 0 })).sorted()
            self.initialDraftSteps = initialDraftSteps
            self.minimumSamples = max(1, minimumSamples)
            self.increaseAcceptance = min(1, max(0, increaseAcceptance))
            self.decreaseAcceptance = min(self.increaseAcceptance,
                                          max(0, decreaseAcceptance))
            self.minimumSpeedup = max(0, minimumSpeedup)
            self.maxFailures = max(0, maxFailures)
        }
    }

    public enum Mode: Sendable, Equatable {
        case ordinary(reason: String)
        case speculative(draftSteps: Int, reason: String)
    }

    public struct Metrics: Sendable, Equatable {
        public let modelRevision: String?
        public let samples: Int
        public let draftedTokens: Int
        public let acceptedTokens: Int
        public let failures: Int
        public let averageAcceptance: Double
        public let averageSpeedup: Double
        public let currentDraftSteps: Int?

        public init(modelRevision: String? = nil, samples: Int = 0, draftedTokens: Int = 0,
                    acceptedTokens: Int = 0, failures: Int = 0,
                    averageAcceptance: Double = 0, averageSpeedup: Double = 0,
                    currentDraftSteps: Int? = nil) {
            self.modelRevision = modelRevision
            self.samples = samples
            self.draftedTokens = draftedTokens
            self.acceptedTokens = acceptedTokens
            self.failures = failures
            self.averageAcceptance = averageAcceptance
            self.averageSpeedup = averageSpeedup
            self.currentDraftSteps = currentDraftSteps
        }
    }

    private let configuration: Configuration
    private var modelRevision: String?
    private var currentDraftSteps: Int
    private var samples = 0
    private var draftedTokens = 0
    private var acceptedTokens = 0
    private var failures = 0
    private var speedupSum = 0.0

    public init(configuration: Configuration = Configuration(), modelRevision: String? = nil) {
        self.configuration = configuration
        self.modelRevision = modelRevision
        self.currentDraftSteps = configuration.supportedDraftSteps.contains(configuration.initialDraftSteps)
            ? configuration.initialDraftSteps
            : (configuration.supportedDraftSteps.first ?? 0)
    }

    public var metrics: Metrics {
        Metrics(modelRevision: modelRevision, samples: samples, draftedTokens: draftedTokens,
                acceptedTokens: acceptedTokens, failures: failures,
                averageAcceptance: draftedTokens > 0
                    ? Double(acceptedTokens) / Double(draftedTokens) : 0,
                averageSpeedup: samples > 0 ? speedupSum / Double(samples) : 0,
                currentDraftSteps: currentDraftSteps > 0 ? currentDraftSteps : nil)
    }

    /// Ordinary decoding is the default and the fallback for every unproven condition.
    public func decision(capabilityAvailable: Bool, memoryPressure: Bool = false) -> Mode {
        guard capabilityAvailable else { return .ordinary(reason: "capability-unavailable") }
        guard !memoryPressure else { return .ordinary(reason: "memory-pressure") }
        guard currentDraftSteps > 0 else { return .ordinary(reason: "no-supported-variant") }
        guard failures <= configuration.maxFailures else {
            return .ordinary(reason: "failure-budget-exhausted")
        }
        guard samples >= configuration.minimumSamples else {
            return .ordinary(reason: "warmup")
        }
        guard metrics.averageAcceptance >= configuration.decreaseAcceptance else {
            return .ordinary(reason: "acceptance-too-low")
        }
        guard metrics.averageSpeedup >= configuration.minimumSpeedup else {
            return .ordinary(reason: "speedup-unproven")
        }
        return .speculative(draftSteps: currentDraftSteps, reason: "evidence-backed")
    }

    /// Records one cycle and adapts only across configured executor variants.
    public mutating func record(_ observation: BELMTPCycleObservation) {
        guard observation.isValid else { return }
        if modelRevision != observation.modelRevision {
            reset(for: observation.modelRevision)
        }
        samples += 1
        draftedTokens += observation.draftedTokens
        acceptedTokens += observation.acceptedTokens
        if observation.failed || observation.memoryPressure {
            failures += 1
            currentDraftSteps = configuration.supportedDraftSteps.first ?? 0
            return
        }
        let speedup = observation.speculativeTokensPerSecond
            / observation.ordinaryTokensPerSecond - 1
        speedupSum += speedup
        if observation.acceptanceRate < configuration.decreaseAcceptance {
            stepDown()
        } else if samples >= configuration.minimumSamples,
                  observation.acceptanceRate >= configuration.increaseAcceptance,
                  speedup >= configuration.minimumSpeedup {
            stepUp()
        }
    }

    public mutating func reset(for revision: String? = nil) {
        modelRevision = revision
        samples = 0
        draftedTokens = 0
        acceptedTokens = 0
        failures = 0
        speedupSum = 0
        currentDraftSteps = configuration.supportedDraftSteps.contains(configuration.initialDraftSteps)
            ? configuration.initialDraftSteps
            : (configuration.supportedDraftSteps.first ?? 0)
    }

    private mutating func stepDown() {
        guard let index = configuration.supportedDraftSteps.firstIndex(of: currentDraftSteps),
              index > 0 else { return }
        currentDraftSteps = configuration.supportedDraftSteps[index - 1]
    }

    private mutating func stepUp() {
        guard let index = configuration.supportedDraftSteps.firstIndex(of: currentDraftSteps),
              index + 1 < configuration.supportedDraftSteps.count else { return }
        currentDraftSteps = configuration.supportedDraftSteps[index + 1]
    }
}
