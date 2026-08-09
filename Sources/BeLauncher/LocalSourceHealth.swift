import Foundation
import BeLauncherCore

/// One evidence-based source state shared by Settings and the Brain.
@MainActor
enum LocalSourceHealth {
    static func state(for source: KnowledgeSource, store: Store) -> KnowledgeSource.State {
        switch source.id {
        case "clipboard":
            return store.setting("clipboard_enabled", default: true) && !store.clips(limit: 1).isEmpty
                ? .connected : .available
        case "browsers":
            return successfulSync("browsers", store: store) && browserAvailable()
                ? .connected : .available
        case "conversations":
            return successfulSync("conversations", store: store) ? .connected : .available
        case "notes", "messages", "apple-mail":
            return Permissions.fullDiskAccessLikely && successfulSync(source.id, store: store)
                ? .connected : .available
        case "apps":
            let hasEvidence = store.nodes(limit: 500).contains { $0.kind == .application }
            return store.setting("graph_enabled", default: false)
                && store.privacyState.isCapturing() && hasEvidence ? .connected : .available
        case "calendar", "reminders", "contacts", "photos":
            return successfulSync(source.id, store: store) ? .connected : .available
        default:
            return source.state
        }
    }

    static func successfulSync(_ id: String, store: Store,
                               home: String = NSHomeDirectory()) -> Bool {
        guard store.setting("source_enabled_\(id)", default: true),
              let raw = store.setting("source_last_sync_\(id)"),
              let timestamp = Double(raw), timestamp > 0,
              (store.setting("source_last_problem_\(id)") ?? "").isEmpty else { return false }
        switch id {
        case "apple-mail":
            guard let root = LocalMailConnector.mailRoot(home: home) else { return false }
            return FileManager.default.isReadableFile(atPath: root.path)
        case "messages":
            return FileManager.default.isReadableFile(
                atPath: home + "/Library/Messages/chat.db")
        case "notes":
            return FileManager.default.isReadableFile(
                atPath: home
                    + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        default:
            return true
        }
    }

    static func browserAvailable(home: String = NSHomeDirectory()) -> Bool {
        let safari = FileManager.default.isReadableFile(
            atPath: home + "/Library/Safari/History.db")
        let chromeRoot = home + "/Library/Application Support/Google/Chrome"
        let chrome = (try? FileManager.default.contentsOfDirectory(atPath: chromeRoot))?.contains {
            ($0 == "Default" || $0.hasPrefix("Profile ")) &&
                FileManager.default.isReadableFile(atPath: chromeRoot + "/\($0)/History")
        } == true
        return safari || chrome
    }
}
