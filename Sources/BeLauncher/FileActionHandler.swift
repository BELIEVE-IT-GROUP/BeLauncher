import AppKit
import Foundation
import BeLauncherCore

struct BELPathActionInput: Codable, Sendable {
    let path: String
}

/// File actions use Foundation/AppKit APIs directly. The handler does not ask for confirmation:
/// BELActionExecutor owns that policy and the caller must pass the explicit confirmation for trash.
struct FileActionHandler: BELActionHandler {
    let actionID: String

    init?(definition: BELActionDefinition) {
        guard definition.kind == .native,
              definition.adapter == .publicAPI,
              ["files.open", "files.reveal", "files.move_to_trash"].contains(definition.id)
        else { return nil }
        actionID = definition.id
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELPathActionInput.self, from: input)
        let url = URL(fileURLWithPath: value.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileActionError.pathDoesNotExist(value.path)
        }

        switch actionID {
        case "files.open":
            guard NSWorkspace.shared.open(url) else { throw FileActionError.couldNotOpen(value.path) }
            return BELActionResult(text: "Opened (url.lastPathComponent)", changed: [url.path],
                                   receipt: "file:open")
        case "files.reveal":
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return BELActionResult(text: "Revealed (url.lastPathComponent)", changed: [url.path],
                                   receipt: "file:reveal")
        case "files.move_to_trash":
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                return BELActionResult(text: "Moved (url.lastPathComponent) to Trash",
                                       changed: [trashed?.path ?? url.path], receipt: "file:trash")
            } catch {
                throw FileActionError.couldNotMoveToTrash(error.localizedDescription)
            }
        default:
            throw FileActionError.unknownAction(actionID)
        }
    }
}

enum FileActionError: Error, Equatable {
    case pathDoesNotExist(String)
    case couldNotOpen(String)
    case couldNotMoveToTrash(String)
    case unknownAction(String)
}
