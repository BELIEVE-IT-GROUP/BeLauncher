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
        let profiles = [8, 16, 32, 64].map {
            MacCapabilitySnapshot(architecture: .appleSilicon, unifiedMemoryGB: $0)
        }

        let expectedBytes: [UInt64] = [8, 16, 32, 64].map {
            UInt64($0) * 1024 * 1024 * 1024
        }
        let actualBytes = profiles.map(\.physicalMemoryBytes)
        #expect(actualBytes == expectedBytes)
        #expect(profiles[0].prefersSmallLocalModel)
        #expect(!profiles[3].prefersSmallLocalModel)
    }

    @Test("unknown power and network facts never become a positive claim")
    func unknownFactsStayUnknown() {
        let snapshot = MacCapabilitySnapshot(architecture: .intel, unifiedMemoryGB: 16)

        #expect(snapshot.onBattery == nil)
        #expect(snapshot.networkAvailable == nil)
        #expect(snapshot.foundationModelsAvailable == nil)
    }
}
