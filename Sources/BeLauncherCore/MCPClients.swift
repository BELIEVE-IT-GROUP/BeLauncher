import Foundation

/// Connecting the brain to the assistant you already use, without you editing a JSON file.
///
/// The old version of this screen showed the configuration and told you to paste it into Claude
/// Desktop's config. That is homework: you have to find a file inside a Library folder, know
/// whether it already has an `mcpServers` key, and merge by hand without breaking the JSON. Paste
/// does this with a dropdown, and they are right to.
///
/// What this does not copy is their transport. Theirs runs an HTTP server on a port on your Mac,
/// listening for as long as the app is open. Ours speaks over stdio: the assistant launches
/// BeLauncher itself and talks down a pipe, so there is no port, nothing listening and nothing for
/// anything else on the machine to find.
public struct MCPClient: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Where its configuration lives, relative to the home folder.
    public let configPath: String
    /// The key inside that file holding the servers.
    public let serversKey: String
    /// Some clients are configured by their own command-line tool instead of a file.
    public let command: [String]?

    public init(id: String, name: String, configPath: String, serversKey: String = "mcpServers",
                command: [String]? = nil) {
        self.id = id
        self.name = name
        self.configPath = configPath
        self.serversKey = serversKey
        self.command = command
    }

    public func absoluteConfigPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(configPath)
    }

    public static let all: [MCPClient] = [
        .init(id: "claude-desktop", name: "Claude Desktop",
              configPath: "Library/Application Support/Claude/claude_desktop_config.json"),
        .init(id: "claude-code", name: "Claude Code", configPath: ".claude.json"),
        .init(id: "cursor", name: "Cursor", configPath: ".cursor/mcp.json"),
        .init(id: "windsurf", name: "Windsurf",
              configPath: ".codeium/windsurf/mcp_config.json"),
        .init(id: "vscode", name: "VS Code",
              configPath: "Library/Application Support/Code/User/mcp.json", serversKey: "servers"),
        .init(id: "codex", name: "Codex", configPath: ".codex/config.json"),
    ]
}

public enum MCPSetup {

    public static let serverName = "belauncher"

    /// What the entry looks like: the app itself, launched with `--mcp`.
    public static func entry(executablePath: String) -> [String: Any] {
        ["command": executablePath, "args": ["--mcp"]]
    }

    public enum Outcome: Sendable, Equatable {
        case connected(String)
        case alreadyConnected(String)
        case failed(String)

        public var message: String {
            switch self {
            case .connected(let name):
                L("%@ can consult your brain now. Restart it so it notices.", name)
            case .alreadyConnected(let name):
                L("%@ was already connected.", name)
            case .failed(let why):
                why
            }
        }
    }

    /// Adds BeLauncher to a client's configuration, keeping everything else that was there.
    ///
    /// Merging rather than writing: that file is usually not empty, and replacing it would take
    /// away every other server the person had connected. A config that arrives broken is worse
    /// than one that was never touched, so it is written atomically and only after it parses.
    public static func merge(into existing: Data?, client: MCPClient,
                             executablePath: String) throws -> (data: Data, wasAlready: Bool) {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
            else {
                throw MCPSetupError.unreadable(client.name)
            }
            root = parsed
        }

        var servers = root[client.serversKey] as? [String: Any] ?? [:]
        let wasAlready = servers[serverName] != nil
        servers[serverName] = entry(executablePath: executablePath)
        root[client.serversKey] = servers

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        return (data, wasAlready)
    }

    /// Whether a client's file already mentions us, for showing the state without touching it.
    public static func isConnected(_ data: Data?, client: MCPClient) -> Bool {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[client.serversKey] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    /// Returns the executable currently recorded for BeLauncher, if the entry has the expected
    /// shape. Keeping this separate from `isConnected` preserves the useful distinction between
    /// intent (the server key exists) and a route that can actually launch this installation.
    public static func executablePath(in data: Data?, client: MCPClient) -> String? {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[client.serversKey] as? [String: Any],
              let entry = servers[serverName] as? [String: Any],
              let command = entry["command"] as? String, !command.isEmpty else { return nil }
        return command
    }

    public static func isCurrent(_ data: Data?, client: MCPClient,
                                 executablePath: String) -> Bool {
        self.executablePath(in: data, client: client) == executablePath
    }
}

public enum MCPSetupError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case notWritable(String)

    public var description: String {
        switch self {
        case .unreadable(let name):
            L("%@'s configuration file has something in it that is not valid JSON. Open it and fix it, or delete it and try again: I will not overwrite it, because there may be other connections of yours in there.", name)
        case .notWritable(let name):
            L("%@'s configuration could not be written.", name)
        }
    }
}
