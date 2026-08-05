import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws a readable error when the app is run from a build folder instead of a real
    /// `.app` bundle — the usual reason this fails during development.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
