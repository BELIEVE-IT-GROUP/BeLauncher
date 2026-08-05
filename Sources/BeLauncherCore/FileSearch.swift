import Foundation

public struct FoundFile: Sendable, Equatable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// File search on top of Spotlight's own index via `mdfind` — no extra permission, no
/// crawling of the user's disk by us, and nothing is read except file names and paths.
public struct FileSearch: Sendable {
    /// Injected so the search can be tested without touching the real index.
    public var run: @Sendable (String, Int) -> [FoundFile]

    public init(run: @escaping @Sendable (String, Int) -> [FoundFile] = FileSearch.spotlight) {
        self.run = run
    }

    /// Queries are explicit: `f budget` searches files, so plain typing stays instant.
    public static let prefix = "f "

    public static func query(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("f "), trimmed.count > 2 else { return nil }
        let term = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return term.count >= 2 ? term : nil
    }

    public func search(_ term: String, limit: Int = 6) -> [FoundFile] {
        run(term, limit)
    }

    public static let spotlight: @Sendable (String, Int) -> [FoundFile] = { term, limit in
        // mdfind takes the term as a single argument, so there is no shell to inject into.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", NSHomeDirectory(), "-name", term]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []   // Spotlight unavailable or disabled: degrade to no file results.
        }

        let handle = pipe.fileHandleForReading
        var data = Data()
        // Spotlight can return tens of thousands of rows; stop reading once we have plenty.
        while data.count < 64_000, let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty {
            data.append(chunk)
        }
        process.terminate()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .prefix(limit)
            .map { line in
                let path = String(line)
                return FoundFile(name: (path as NSString).lastPathComponent, path: path)
            }
    }
}
