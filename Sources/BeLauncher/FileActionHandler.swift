import AppKit
import Foundation
import BeLauncherCore

struct BELPathActionInput: Codable, Sendable {
    let path: String
}

struct BELFileSelectionInput: Codable, Sendable {
    let directoriesOnly: Bool
    let multiple: Bool

    init(directoriesOnly: Bool = false, multiple: Bool = false) {
        self.directoriesOnly = directoriesOnly
        self.multiple = multiple
    }
}

/// File actions use Foundation/AppKit APIs directly. The handler does not ask for confirmation:
/// BELActionExecutor owns that policy and the caller must pass the explicit confirmation for trash.
struct FileActionHandler: BELActionHandler {
    let actionID: String
    private let choose: @MainActor @Sendable (BELFileSelectionInput) -> [URL]

    init?(definition: BELActionDefinition,
          choose: @escaping @MainActor @Sendable (BELFileSelectionInput) -> [URL] = FileActionHandler.defaultChoose) {
        guard definition.kind == .native,
              definition.adapter == .publicAPI,
              ["files.choose", "files.open", "files.reveal", "files.move_to_trash"].contains(definition.id)
        else { return nil }
        actionID = definition.id
        self.choose = choose
    }

    func perform(input: Data) async throws -> BELActionResult {
        if actionID == "files.choose" {
            let value = input.isEmpty
                ? BELFileSelectionInput()
                : try JSONDecoder().decode(BELFileSelectionInput.self, from: input)
            let urls = await MainActor.run { choose(value) }
            guard !urls.isEmpty else { throw FileActionError.selectionCancelled }
            return BELActionResult(text: urls.map(\.path).joined(separator: "\n"),
                                   changed: urls.map(\.path), receipt: "file:choose")
        }

        let value = try JSONDecoder().decode(BELPathActionInput.self, from: input)
        let url = URL(fileURLWithPath: value.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileActionError.pathDoesNotExist(value.path)
        }

        switch actionID {
        case "files.open":
            guard NSWorkspace.shared.open(url) else { throw FileActionError.couldNotOpen(value.path) }
            return BELActionResult(text: "Opened \(url.lastPathComponent)", changed: [url.path],
                                   receipt: "file:open")
        case "files.reveal":
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return BELActionResult(text: "Revealed \(url.lastPathComponent)", changed: [url.path],
                                   receipt: "file:reveal")
        case "files.move_to_trash":
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                return BELActionResult(text: "Moved \(url.lastPathComponent) to Trash",
                                       changed: [trashed?.path ?? url.path], receipt: "file:trash")
            } catch {
                throw FileActionError.couldNotMoveToTrash(error.localizedDescription)
            }
        default:
            throw FileActionError.unknownAction(actionID)
        }
    }

    @MainActor
    private static func defaultChoose(_ input: BELFileSelectionInput) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !input.directoriesOnly
        panel.canChooseDirectories = input.directoriesOnly
        panel.allowsMultipleSelection = input.multiple
        panel.canCreateDirectories = false
        panel.prompt = input.multiple ? "Choose" : "Open"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

enum FileActionError: Error, Equatable {
    case selectionCancelled
    case pathDoesNotExist(String)
    case couldNotOpen(String)
    case couldNotMoveToTrash(String)
    case unknownAction(String)
}
