import Foundation
import IOKit

/// Identifies this Mac for licensing. The hardware UUID is stable across reinstalls and OS
/// upgrades, which is exactly what a seat count needs, and it is not personal data.
enum DeviceIdentity {
    static var id: String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return fallbackID }
        defer { IOObjectRelease(platformExpert) }

        guard let value = IORegistryEntryCreateCFProperty(
            platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String, !value.isEmpty else {
            return fallbackID
        }
        return value
    }

    static var name: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Only used if IOKit ever refuses: a stable per-install identifier, so activation still works.
    private static var fallbackID: String {
        let defaults = UserDefaults.standard
        let storageKey = "belauncher.device.fallback"
        if let existing = defaults.string(forKey: storageKey) { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: storageKey)
        return generated
    }
}
