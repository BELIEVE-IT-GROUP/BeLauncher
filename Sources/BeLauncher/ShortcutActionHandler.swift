import Foundation
import AppKit
import BeLauncherCore

struct BELShortcutActionInput: Codable, Sendable {
    let name: String?
    let actionID: String?

    init(name: String) {
        self.name = name
        self.actionID = nil
    }

    init(actionID: String) {
        self.name = nil
        self.actionID = actionID
    }
}

/// Runs a user-owned Shortcut by argument, never by shell interpolation. The result carries the
/// real exit code and bounded stderr so Settings and the launcher can explain a missing or failed
/// shortcut instead of reporting a silent success.
struct ShortcutActionHandler: BELActionHandler {
    let actionID = "shortcuts.run"

    init?(definition: BELActionDefinition) {
        guard definition.id == "shortcuts.run", definition.adapter == .shortcut else { return nil }
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELShortcutActionInput.self, from: input)
        let name = (value.name ?? ShortcutMappingStore.name(for: value.actionID))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, !name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw ShortcutActionError.invalidName
        }
        if value.actionID != nil {
            guard name.hasPrefix(BELShortcutMapping.namePrefix) else {
                throw ShortcutActionError.invalidMapping
            }
            let mapping = await MainActor.run { ShortcutMappingStore.mapping(for: value.actionID) }
            let available = await MainActor.run {
                Shortcuts.available(using: Shortcuts.defaultRunner)
            }
            switch available {
            case .success(let names):
                guard names.contains(name) else { throw ShortcutActionError.missingShortcut(name) }
            case .failure(.toolUnavailable):
                throw ShortcutActionError.toolUnavailable
            case .failure(.failed(let status, let detail)):
                throw ShortcutActionError.failed(status: status, detail: detail)
            case .failure(.invalidName):
                throw ShortcutActionError.invalidName
            }
            if mapping?.requiresForeground == true {
                let active = await MainActor.run { NSApp?.isActive == true }
                guard active else { throw ShortcutActionError.foregroundRequired(name) }
            }
        }
        do {
            let result = try await MainActor.run { try Shortcuts.run(named: name) }
            return BELActionResult(text: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                   receipt: "shortcut:\(name)")
        } catch let error as BELShortcutCommandError {
            switch error {
            case .invalidName: throw ShortcutActionError.invalidName
            case .toolUnavailable: throw ShortcutActionError.toolUnavailable
            case .failed(let status, let detail):
                throw ShortcutActionError.failed(status: status, detail: detail)
            }
        } catch {
            throw ShortcutActionError.launchFailed(error.localizedDescription)
        }
    }
}

enum ShortcutActionError: Error, Equatable {
    case invalidName
    case invalidMapping
    case foregroundRequired(String)
    case missingShortcut(String)
    case toolUnavailable
    case launchFailed(String)
    case failed(status: Int32, detail: String)
}
