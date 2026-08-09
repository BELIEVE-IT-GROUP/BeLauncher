import AppKit
import Foundation
import BeLauncherCore

struct BELOpenAppInput: Codable, Sendable {
    let identifier: String
}

struct BELOpenSettingInput: Codable, Sendable {
    let pane: String
}

/// Public AppKit actions with bounded inputs. The closures keep tests deterministic and prevent
/// the test suite from opening apps or System Settings on the host.
struct SystemPublicActionHandler: BELActionHandler {
    let actionID: String
    private let open: @MainActor @Sendable (URL) -> Bool

    private static let allowedSettings: Set<String> = [
        "Privacy_Security",
        "Privacy_Microphone",
        "Privacy_Accessibility",
        "Privacy_ScreenCapture",
        "Privacy_ListenEvent",
        "Privacy_AllFiles",
        "General",
    ]

    init?(definition: BELActionDefinition,
          open: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        guard definition.kind == .native, definition.adapter == .publicAPI,
              ["system.open_app", "system.open_system_setting"].contains(definition.id)
        else { return nil }
        actionID = definition.id
        self.open = open
    }

    func perform(input: Data) async throws -> BELActionResult {
        switch actionID {
        case "system.open_app":
            let value = try JSONDecoder().decode(BELOpenAppInput.self, from: input)
            let identifier = value.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, identifier.count <= 512,
                  !identifier.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw SystemPublicActionError.invalidInput
            }
            let url: URL?
            if identifier.hasPrefix("/") {
                url = URL(fileURLWithPath: identifier).standardizedFileURL
            } else {
                url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            }
            guard let url else { throw SystemPublicActionError.notFound(identifier) }
            let didOpen = await MainActor.run { open(url) }
            guard didOpen else { throw SystemPublicActionError.couldNotOpen(identifier) }
            return BELActionResult(text: "Opened \(url.deletingPathExtension().lastPathComponent)",
                                   changed: [url.path], receipt: "system:open_app")

        case "system.open_system_setting":
            let value = try JSONDecoder().decode(BELOpenSettingInput.self, from: input)
            let pane = value.pane.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.allowedSettings.contains(pane) else {
                throw SystemPublicActionError.settingNotAllowed(pane)
            }
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
            guard await MainActor.run(body: { open(url) }) else {
                throw SystemPublicActionError.couldNotOpen(pane)
            }
            return BELActionResult(text: "Opened System Settings", receipt: "system:open_setting")

        default:
            throw SystemPublicActionError.invalidInput
        }
    }
}

enum SystemPublicActionError: Error, Equatable {
    case invalidInput
    case notFound(String)
    case settingNotAllowed(String)
    case couldNotOpen(String)
}
