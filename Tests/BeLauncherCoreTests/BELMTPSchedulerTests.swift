import Testing
@testable import BeLauncherCore

struct BELMTPSchedulerTests {
    private func observation(accepted: Int, drafted: Int = 4, speedup: Bool = true,
                             revision: String = "e4b-r1", failed: Bool = false,
                             pressure: Bool = false) -> BELMTPCycleObservation {
        BELMTPCycleObservation(
            modelRevision: revision, draftedTokens: drafted, acceptedTokens: accepted,
            draftMilliseconds: speedup ? 10 : 100,
            verifyMilliseconds: 10, ordinaryTokenMilliseconds: 10,
            memoryPressure: pressure, failed: failed)
    }

    @Test("capability and memory gates fail closed")
    func gates() {
        let scheduler = BELMTPScheduler()
        #expect(scheduler.decision(capabilityAvailable: false) == .ordinary(
            reason: "capability-unavailable"))
        #expect(scheduler.decision(capabilityAvailable: true, memoryPressure: true) == .ordinary(
            reason: "memory-pressure"))
    }

    @Test("warmup never enables speculative decoding")
    func warmup() {
        var scheduler = BELMTPScheduler()
        scheduler.record(observation(accepted: 4))
        scheduler.record(observation(accepted: 4))
        #expect(scheduler.decision(capabilityAvailable: true) == .ordinary(reason: "warmup"))
    }

    @Test("strong evidence enables the current compiled variant")
    func enablesAfterEvidence() {
        var scheduler = BELMTPScheduler()
        for _ in 0..<3 { scheduler.record(observation(accepted: 4)) }
        #expect(scheduler.decision(capabilityAvailable: true) == .speculative(
            draftSteps: 2, reason: "evidence-backed"))
    }

    @Test("high acceptance and speedup move only to a supported variant")
    func stepsUp() {
        var scheduler = BELMTPScheduler(
            configuration: .init(supportedDraftSteps: [1, 2, 4], initialDraftSteps: 1))
        for _ in 0..<3 { scheduler.record(observation(accepted: 4)) }
        #expect(scheduler.metrics.currentDraftSteps == 2)
    }

    @Test("low acceptance steps down and then uses ordinary mode")
    func stepsDown() {
        var scheduler = BELMTPScheduler(
            configuration: .init(supportedDraftSteps: [1, 2, 4], initialDraftSteps: 4))
        scheduler.record(observation(accepted: 0))
        #expect(scheduler.metrics.currentDraftSteps == 2)
        scheduler.record(observation(accepted: 0))
        scheduler.record(observation(accepted: 0))
        #expect(scheduler.decision(capabilityAvailable: true) == .ordinary(
            reason: "acceptance-too-low"))
    }

    @Test("failures and pressure reset to the smallest safe variant")
    func failureFallback() {
        var scheduler = BELMTPScheduler(
            configuration: .init(supportedDraftSteps: [1, 2, 4], initialDraftSteps: 4,
                                 maxFailures: 0))
        scheduler.record(observation(accepted: 4))
        scheduler.record(observation(accepted: 4, failed: true))
        #expect(scheduler.metrics.currentDraftSteps == 1)
        #expect(scheduler.decision(capabilityAvailable: true) == .ordinary(
            reason: "failure-budget-exhausted"))
    }

    @Test("model revision resets evidence and prevents cross-model adaptation")
    func revisionReset() {
        var scheduler = BELMTPScheduler()
        for _ in 0..<3 { scheduler.record(observation(accepted: 4, revision: "old")) }
        scheduler.record(observation(accepted: 4, revision: "new"))
        #expect(scheduler.metrics.modelRevision == "new")
        #expect(scheduler.metrics.samples == 1)
        #expect(scheduler.decision(capabilityAvailable: true) == .ordinary(reason: "warmup"))
    }

    @Test("invalid observations do not create false telemetry")
    func invalidObservation() {
        var scheduler = BELMTPScheduler()
        scheduler.record(BELMTPCycleObservation(
            modelRevision: "e4b-r1", draftedTokens: 0, acceptedTokens: 0,
            draftMilliseconds: 0, verifyMilliseconds: 0, ordinaryTokenMilliseconds: 0))
        #expect(scheduler.metrics.samples == 0)
        #expect(scheduler.metrics.draftedTokens == 0)
    }
}
