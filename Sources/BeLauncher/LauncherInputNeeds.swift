import Foundation
import BeLauncherCore

/// What the launcher may read for this keystroke.
///
/// The hotkey path has to stay tiny even when the brain is huge. A previous version loaded the
/// vault and the work graph on every summon, then walked edges one node at a time. That is fine on
/// a demo database and fatal on a real one. This keeps expensive stores behind the intents that
/// actually need them.
struct LauncherInputNeeds: Equatable {
    let query: String
    let mode: LauncherModel.Mode

    init(query: String, mode: LauncherModel.Mode) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
    }

    var isEmpty: Bool { query.isEmpty }
    var needsPacks: Bool { mode == .all && query.hasPrefix("/") }
    var needsNotes: Bool {
        mode == .all && ["notas", "mis notas", "my notes", "notes", "quick note", "quick notes", "inbox"].contains(query.lowercased())
    }
    var needsProcesses: Bool { mode == .all && ProcessList.order(for: query) != nil }
    var needsWorkspaces: Bool { mode == .all && WorkspaceLayouts.Intent.detect(query) != nil }
    var workIntent: WorkQuery.Intent? { WorkQuery.Intent.detect(query) }
    var needsWorkGraph: Bool { mode == .all && workIntent != nil }

    var brainIntent: BrainQuery.Intent { BrainQuery.Intent.detect(query) }

    var naturalBrainQuestion: String? {
        BrainQuery.naturalQuestion(query)
    }

    var needsMemories: Bool {
        guard mode == .all else { return false }
        switch brainIntent {
        case .whatDidWeDecide, .prepare, .pulse:
            return true
        case .remember, .none:
            break
        }
        if naturalBrainQuestion != nil { return true }
        if case .promisedTo = workIntent { return true }
        return false
    }

    var needsPendingCommits: Bool { needsMemories }

    var needsTraits: Bool {
        guard mode == .all else { return false }
        if case .pulse = brainIntent { return true }
        if naturalBrainQuestion != nil { return true }
        return false
    }

    var needsCalendar: Bool {
        guard mode == .all else { return false }
        switch brainIntent {
        case .prepare: return true
        default: return workIntent == .resumeBefore
        }
    }

    private var sourceQuery: String {
        query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var needsReminders: Bool {
        guard mode == .all else { return false }
        return sourceQuery == "/reminders" || sourceQuery == "/reminder" ||
            sourceQuery.hasPrefix("reminder ") || sourceQuery.hasPrefix("recordatorio ")
    }

    var needsContacts: Bool {
        guard mode == .all else { return false }
        return sourceQuery == "/contacts" || sourceQuery == "/contact" ||
            sourceQuery.hasPrefix("contact ") || sourceQuery.hasPrefix("contacto ")
    }

    var needsPhotos: Bool {
        guard mode == .all else { return false }
        return sourceQuery == "/photos" || sourceQuery == "/photo" ||
            sourceQuery.hasPrefix("photo ") || sourceQuery.hasPrefix("foto ")
    }
}
