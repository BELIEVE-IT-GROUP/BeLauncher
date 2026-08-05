import Foundation

public struct Application: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Scans the usual application folders. No Spotlight, no indexing daemon, no permissions.
public struct AppIndex: Sendable {
    public private(set) var applications: [Application]

    public init(applications: [Application] = []) {
        self.applications = applications
    }

    public static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications",
        ]
    }

    public static func scan(paths: [String] = AppIndex.searchPaths) -> AppIndex {
        let manager = FileManager.default
        var found: [String: Application] = [:]
        for path in paths {
            guard let entries = try? manager.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let full = (path as NSString).appendingPathComponent(entry)
                let name = String(entry.dropLast(4))
                found[full] = Application(name: name, path: full)
            }
        }
        return AppIndex(applications: found.values.sorted { $0.name < $1.name })
    }
}
