import Foundation

/// Persistent identity for a Shortcut fallback. The human-facing name can change; the BEL action
/// ID cannot. The mapping is deliberately data-only so it can be validated without launching
/// Shortcuts.app or claiming that a shortcut exists on a machine where it does not.
public struct BELShortcutMapping: Codable, Sendable, Equatable, Identifiable {
    public let actionID: String
    public let shortcutName: String
    public let version: Int
    public let enabled: Bool

    public var id: String { actionID }

    public init(actionID: String, shortcutName: String, version: Int = 1, enabled: Bool = true) {
        self.actionID = actionID
        self.shortcutName = shortcutName
        self.version = version
        self.enabled = enabled
    }

    public static let namePrefix = "BEL • "

    public var isWellFormed: Bool {
        !actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && shortcutName.hasPrefix(Self.namePrefix)
            && !shortcutName.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
            && version > 0
    }

    public static func validate(_ mappings: [BELShortcutMapping]) -> [String] {
        var seen = Set<String>()
        var issues: [String] = []
        for mapping in mappings {
            if !mapping.isWellFormed { issues.append("invalid:(mapping.actionID)") }
            if !seen.insert(mapping.actionID).inserted { issues.append("duplicate:\(mapping.actionID)") }
        }
        return issues
    }
}
