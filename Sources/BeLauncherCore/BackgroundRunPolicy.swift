import Foundation

/// Decides whether an unattended pass may compete with the Mac right now. Manual source syncs
/// bypass this policy; only scheduled work is deferred. Keeping the decision pure makes the
/// scheduler explainable and testable instead of burying power checks inside CorpusRunner.
public enum BackgroundRunPolicy {
    /// Quiet window for model-heavy distillation. Capture itself remains periodic; only the
    /// expensive summary pass is restricted to the overnight hours.
    public static func isOvernight(hour: Int) -> Bool {
        (3..<6).contains(hour)
    }

    public enum ThermalState: Int, Sendable, Equatable {
        case nominal = 0
        case fair = 1
        case serious = 2
        case critical = 3
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        case deferred(reason: Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case lowPowerMode
        case lowBattery
        case seriousThermalState
    }

    public static func decide(lowPowerMode: Bool,
                              thermalState: ThermalState,
                              onBattery: Bool = false,
                              batteryFraction: Double? = nil) -> Decision {
        if lowPowerMode { return .deferred(reason: .lowPowerMode) }
        if onBattery, let batteryFraction, batteryFraction < 0.20 {
            return .deferred(reason: .lowBattery)
        }
        if thermalState == .serious || thermalState == .critical {
            return .deferred(reason: .seriousThermalState)
        }
        return .allowed
    }
}
