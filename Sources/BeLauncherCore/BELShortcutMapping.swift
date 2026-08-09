import Foundation

/// Persistent identity for a Shortcut fallback. The human-facing name can change; the BEL action
/// ID cannot. The mapping is deliberately data-only so it can be validated without launching
/// Shortcuts.app or claiming that a shortcut exists on a machine where it does not.
public struct BELShortcutMapping: Codable, Sendable, Equatable, Identifiable {
    public let actionID: String
    public let shortcutName: String
    public let version: Int
    public let enabled: Bool
    public let requiresForeground: Bool

    public var id: String { actionID }

    public init(actionID: String, shortcutName: String, version: Int = 1, enabled: Bool = true,
                requiresForeground: Bool = false) {
        self.actionID = actionID
        self.shortcutName = shortcutName
        self.version = version
        self.enabled = enabled
        self.requiresForeground = requiresForeground
    }

    private enum CodingKeys: String, CodingKey {
        case actionID, shortcutName, version, enabled, requiresForeground
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        actionID = try values.decode(String.self, forKey: .actionID)
        shortcutName = try values.decode(String.self, forKey: .shortcutName)
        version = try values.decode(Int.self, forKey: .version)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        requiresForeground = try values.decodeIfPresent(Bool.self, forKey: .requiresForeground) ?? false
    }

    public static let namePrefix = "BEL • "

    public var isWellFormed: Bool {
        let components = actionID.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2
            && components.allSatisfy { !$0.isEmpty }
            && !actionID.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
            && shortcutName.hasPrefix(Self.namePrefix)
            && !shortcutName.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
            && version > 0
    }

    public static func validate(_ mappings: [BELShortcutMapping]) -> [String] {
        var seen = Set<String>()
        var issues: [String] = []
        for mapping in mappings {
            if !mapping.isWellFormed { issues.append("invalid:\(mapping.actionID)") }
            if !seen.insert(mapping.actionID).inserted { issues.append("duplicate:\(mapping.actionID)") }
        }
        return issues
    }
}
