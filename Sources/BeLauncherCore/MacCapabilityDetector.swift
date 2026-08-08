import Foundation
import Darwin
#if os(macOS)
import IOKit.ps
import SystemConfiguration
#endif

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
        memoryPressure: MacMemoryPressure? = nil
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
            memoryPressure: memoryPressure ?? detectMemoryPressure(processInfo: processInfo),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            onBattery: onBattery ?? detectOnBattery(),
            networkAvailable: networkAvailable ?? detectNetworkAvailable()
        )
    }

    /// These probes are deliberately synchronous and bounded: routing happens when a request is
    /// already being made, never on the launch/hot-key path. A failed probe returns nil/unknown;
    /// it must never turn an unreadable system state into a false fact.
    private static func detectOnBattery() -> Bool? {
        #if os(macOS)
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let listed = IOPSCopyPowerSourcesList(info)?.takeUnretainedValue()
                as? [CFTypeRef],
              let source = listed.first,
              let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
              let state = raw[kIOPSPowerSourceStateKey] as? String else { return nil }
        return state == kIOPSBatteryPowerValue
        #else
        return nil
        #endif
    }

    private static func detectNetworkAvailable() -> Bool? {
        #if os(macOS)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let host = SCNetworkReachabilityCreateWithAddress(nil, withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        })
        var flags = SCNetworkReachabilityFlags()
        guard let host, SCNetworkReachabilityGetFlags(host, &flags) else { return nil }
        let reachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return reachable && !needsConnection
        #else
        return nil
        #endif
    }

    private static func detectMemoryPressure(processInfo: ProcessInfo) -> MacMemoryPressure {
        #if os(macOS)
        // ProcessInfo gives us the machine size but not current pressure. The VM counters are
        // the same source used by Activity Monitor; free + inactive is a conservative available
        // estimate, and failure stays unknown rather than influencing routing.
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                            / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .unknown }
        let pageSize = UInt64(getpagesize())
        let available = UInt64(statistics.free_count + statistics.inactive_count)
            * pageSize
        let total = UInt64(processInfo.physicalMemory)
        guard total > 0 else { return .unknown }
        let fraction = Double(available) / Double(total)
        if fraction < 0.08 { return .critical }
        if fraction < 0.18 { return .elevated }
        return .normal
        #else
        return .unknown
        #endif
    }
}
