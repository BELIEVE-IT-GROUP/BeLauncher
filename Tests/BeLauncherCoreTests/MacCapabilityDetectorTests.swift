import Testing
@testable import BeLauncherCore

@Suite("Mac capability detection")
struct MacCapabilityDetectorTests {
    @Test("the snapshot keeps exact memory and optional runtime facts")
    func snapshotIsExplicit() {
        let snapshot = MacCapabilitySnapshot(
            architecture: .appleSilicon,
            unifiedMemoryGB: 8,
            physicalMemoryBytes: 8_589_934_592,
            thermalState: .serious,
            memoryPressure: .elevated,
            lowPowerMode: true,
            onBattery: true,
            networkAvailable: false,
            foundationModelsAvailable: false)

        #expect(snapshot.physicalMemoryBytes == 8_589_934_592)
        #expect(snapshot.prefersSmallLocalModel)
        #expect(snapshot.foundationModelsAvailable == false)
        #expect(snapshot.networkAvailable == false)
    }

    @Test("memory profiles keep routing policy deterministic")
    func memoryProfiles() {
        let appleSiliconProfiles = [8, 16, 32, 64].map {
            MacCapabilitySnapshot(architecture: .appleSilicon, unifiedMemoryGB: $0)
        }
        let intelProfiles = [8, 16, 32, 64].map {
            MacCapabilitySnapshot(architecture: .intel, unifiedMemoryGB: $0)
        }

        let expectedBytes: [UInt64] = [8, 16, 32, 64].map {
            UInt64($0) * 1024 * 1024 * 1024
        }
        #expect(appleSiliconProfiles.map(\.architecture) == Array(repeating: .appleSilicon, count: 4))
        #expect(intelProfiles.map(\.architecture) == Array(repeating: .intel, count: 4))
        #expect(appleSiliconProfiles.map(\.physicalMemoryBytes) == expectedBytes)
        #expect(intelProfiles.map(\.physicalMemoryBytes) == expectedBytes)
        #expect(appleSiliconProfiles[0].prefersSmallLocalModel)
        #expect(intelProfiles[0].prefersSmallLocalModel)
        #expect(!appleSiliconProfiles[3].prefersSmallLocalModel)
        #expect(!intelProfiles[3].prefersSmallLocalModel)
    }

    @Test("thermal pressure and power facts are explicit routing inputs")
    func routingFactsAreExplicit() {
        let nominal = MacCapabilitySnapshot(
            architecture: .appleSilicon,
            unifiedMemoryGB: 32,
            thermalState: .nominal,
            memoryPressure: .normal,
            lowPowerMode: false,
            onBattery: false,
            networkAvailable: true,
            foundationModelsAvailable: true)
        let lowPower = MacCapabilitySnapshot(
            architecture: .appleSilicon,
            unifiedMemoryGB: 32,
            thermalState: .nominal,
            memoryPressure: .normal,
            lowPowerMode: true)
        let elevatedPressure = MacCapabilitySnapshot(
            architecture: .appleSilicon,
            unifiedMemoryGB: 32,
            thermalState: .nominal,
            memoryPressure: .elevated)
        let seriousThermal = MacCapabilitySnapshot(
            architecture: .intel,
            unifiedMemoryGB: 32,
            thermalState: .serious,
            memoryPressure: .normal)

        #expect(nominal.thermalState == .nominal)
        #expect(nominal.memoryPressure == .normal)
        #expect(nominal.lowPowerMode == false)
        #expect(nominal.onBattery == false)
        #expect(nominal.networkAvailable == true)
        #expect(nominal.foundationModelsAvailable == true)
        #expect(!nominal.prefersSmallLocalModel)
        #expect(lowPower.prefersSmallLocalModel)
        #expect(elevatedPressure.prefersSmallLocalModel)
        #expect(seriousThermal.prefersSmallLocalModel)
    }

    @Test("unknown power and network facts never become a positive claim")
    func unknownFactsStayUnknown() {
        let snapshot = MacCapabilitySnapshot(architecture: .intel, unifiedMemoryGB: 16)

        #expect(snapshot.thermalState == .unknown)
        #expect(snapshot.memoryPressure == .unknown)
        #expect(snapshot.onBattery == nil)
        #expect(snapshot.networkAvailable == nil)
        #expect(snapshot.foundationModelsAvailable == nil)
    }
}
