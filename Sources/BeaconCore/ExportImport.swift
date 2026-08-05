import Foundation

/// Plain JSON, human-readable, no proprietary container: your data leaves as easily as it arrives.
/// Clipboard history is excluded by default and secrets are never included.
public struct BeaconArchive: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    public var snippets: [Snippet]
    public var workflows: [Workflow]
    public var settings: [String: String]
    public var clips: [String]?

    public init(version: Int = BeaconArchive.currentVersion, exportedAt: Date = .now,
                snippets: [Snippet], workflows: [Workflow],
                settings: [String: String], clips: [String]? = nil) {
        self.version = version
        self.exportedAt = exportedAt
        self.snippets = snippets
        self.workflows = workflows
        self.settings = settings
        self.clips = clips
    }
}

public enum ArchiveError: Error, CustomStringConvertible {
    case unsupportedVersion(Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): "This file was written by a newer version of Beacon (format \(v))."
        case .unreadable(let m): "The file could not be read: \(m)"
        }
    }
}

public struct ImportSummary: Sendable, Equatable {
    public var addedSnippets = 0
    public var addedWorkflows = 0
    public var skipped = 0
}

public enum Archive {
    public static func encode(_ archive: BeaconArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    public static func decode(_ data: Data) throws -> BeaconArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: BeaconArchive
        do {
            archive = try decoder.decode(BeaconArchive.self, from: data)
        } catch {
            throw ArchiveError.unreadable("\(error.localizedDescription)")
        }
        guard archive.version <= BeaconArchive.currentVersion else {
            throw ArchiveError.unsupportedVersion(archive.version)
        }
        return archive
    }
}

extension Store {
    public func exportArchive(includeClipboard: Bool = false) -> BeaconArchive {
        let keys = ["hotkey", "clipboard_enabled", "clipboard_retention_days",
                    "clipboard_max_items", "launch_at_login", "update_check_enabled"]
        var settings: [String: String] = [:]
        for key in keys { if let value = setting(key) { settings[key] = value } }
        return BeaconArchive(
            snippets: snippets(),
            workflows: workflows(),
            settings: settings,
            clips: includeClipboard ? clips(limit: 1000).map(\.text) : nil
        )
    }

    /// Merges by keyword; existing entries win, so an import can never silently overwrite.
    @discardableResult
    public func importArchive(_ archive: BeaconArchive) -> ImportSummary {
        var summary = ImportSummary()
        for snippet in archive.snippets {
            do {
                try addSnippet(keyword: snippet.keyword, title: snippet.title, body: snippet.body)
                summary.addedSnippets += 1
            } catch {
                summary.skipped += 1
            }
        }
        for workflow in archive.workflows {
            do {
                try addWorkflow(keyword: workflow.keyword, title: workflow.title, urlTemplate: workflow.urlTemplate)
                summary.addedWorkflows += 1
            } catch {
                summary.skipped += 1
            }
        }
        for (key, value) in archive.settings { setSetting(key, value) }
        for text in archive.clips ?? [] { recordClip(text: text) }
        return summary
    }
}
