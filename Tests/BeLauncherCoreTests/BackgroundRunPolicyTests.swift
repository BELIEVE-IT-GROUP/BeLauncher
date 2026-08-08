import Foundation
import Testing
@testable import BeLauncherCore

@Suite("Background scheduler policy")
struct BackgroundRunPolicyTests {
    @Test("manual-friendly conditions allow unattended work")
    func allowsNormalState() {
        #expect(BackgroundRunPolicy.decide(lowPowerMode: false, thermalState: .nominal)
                == .allowed)
        #expect(BackgroundRunPolicy.decide(lowPowerMode: false, thermalState: .fair)
                == .allowed)
    }

    @Test("low power and serious thermal states defer unattended work")
    func defersWhenMacNeedsHeadroom() {
        #expect(BackgroundRunPolicy.decide(lowPowerMode: true, thermalState: .nominal)
                == .deferred(reason: .lowPowerMode))
        #expect(BackgroundRunPolicy.decide(lowPowerMode: false, thermalState: .serious)
                == .deferred(reason: .seriousThermalState))
        #expect(BackgroundRunPolicy.decide(lowPowerMode: false, thermalState: .critical)
                == .deferred(reason: .seriousThermalState))
        #expect(BackgroundRunPolicy.decide(lowPowerMode: false, thermalState: .nominal,
                                           onBattery: true, batteryFraction: 0.19)
                == .deferred(reason: .lowBattery))
        #expect(BackgroundRunPolicy.decide(lowPowerMode: false, thermalState: .nominal,
                                           onBattery: true, batteryFraction: 0.50)
                == .allowed)
    }

    @Test("model-heavy distillation stays inside the overnight window")
    func overnightWindowHasClearEdges() {
        #expect(!BackgroundRunPolicy.isOvernight(hour: 2))
        #expect(BackgroundRunPolicy.isOvernight(hour: 3))
        #expect(BackgroundRunPolicy.isOvernight(hour: 5))
        #expect(!BackgroundRunPolicy.isOvernight(hour: 6))
    }
}

@Suite("Durable ingestion progress")
struct IngestionProgressTests {
    @Test("progress is source-scoped and clamps invalid counters")
    func progressContract() throws {
        let progress = IngestionProgress(source: "apple-mail", phase: .writing,
                                         completedItems: -2, totalItems: 4,
                                         writtenPassages: -1)
        #expect(progress.source == "apple-mail")
        #expect(progress.completedItems == 0)
        #expect(progress.writtenPassages == 0)
        #expect(progress.fraction == 0)
        let data = try JSONEncoder().encode(progress)
        #expect(try JSONDecoder().decode(IngestionProgress.self, from: data) == progress)
    }
}
