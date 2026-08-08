import Foundation

public enum MacArchitecture: String, Sendable, Equatable {
    case appleSilicon
    case intel
}

public enum MacThermalState: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public enum MacMemoryPressure: String, Sendable, Equatable {
    case normal
    case elevated
    case critical
    case unknown
}

/// Facts that influence model routing. Optional values are deliberate: an unknown battery or
/// network state must not be rendered as a false positive in Settings or used as proof of health.
public struct MacCapabilitySnapshot: Sendable, Equatable {
    public let architecture: MacArchitecture
    public let unifiedMemoryGB: Int
    public let thermalState: MacThermalState
    public let memoryPressure: MacMemoryPressure
    public let lowPowerMode: Bool
    public let onBattery: Bool?
    public let networkAvailable: Bool?

    public init(architecture: MacArchitecture, unifiedMemoryGB: Int,
                thermalState: MacThermalState = .unknown,
                memoryPressure: MacMemoryPressure = .unknown,
                lowPowerMode: Bool = false, onBattery: Bool? = nil,
                networkAvailable: Bool? = nil) {
        self.architecture = architecture
        self.unifiedMemoryGB = unifiedMemoryGB
        self.thermalState = thermalState
        self.memoryPressure = memoryPressure
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.networkAvailable = networkAvailable
    }

    public var prefersSmallLocalModel: Bool {
        unifiedMemoryGB <= 8 || lowPowerMode
            || memoryPressure == .elevated || memoryPressure == .critical
            || thermalState == .serious || thermalState == .critical
    }
}

public enum MacCapabilityDetector {
    public static func current(
        processInfo: ProcessInfo = .processInfo,
        onBattery: Bool? = nil,
        networkAvailable: Bool? = nil,
        memoryPressure: MacMemoryPressure = .unknown
    ) -> MacCapabilitySnapshot {
        #if arch(arm64)
        let architecture: MacArchitecture = .appleSilicon
        #else
        let architecture: MacArchitecture = .intel
        #endif

        let thermal: MacThermalState
        switch processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }

        return MacCapabilitySnapshot(
            architecture: architecture,
            unifiedMemoryGB: max(1, Int(processInfo.physicalMemory / (1024 * 1024 * 1024))),
            thermalState: thermal,
            memoryPressure: memoryPressure,
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            onBattery: onBattery,
            networkAvailable: networkAvailable
        )
    }
}
