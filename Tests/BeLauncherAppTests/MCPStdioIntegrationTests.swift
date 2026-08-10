import Foundation
import Testing
@testable import BeLauncherCore

@MainActor
@Suite("MCP stdio process")
struct MCPStdioIntegrationTests {

    private static var repositoryRoot: String {
        var path = URL(fileURLWithPath: #filePath)
        while path.pathComponents.count > 1 {
            path.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: path.appendingPathComponent("Package.swift").path) {
                return path.path
            }
        }
        return FileManager.default.currentDirectoryPath
    }

    private static func executablePath() throws -> String {
        let root = repositoryRoot
        let candidates = [
            "\(root)/.build/debug/BeLauncher",
            "\(root)/.build/arm64-apple-macosx/debug/BeLauncher",
        ]
        return try #require(candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }, "BeLauncher executable was not built")
    }

    @Test("the launched MCP server reads the real index and returns cited data")
    func launchedServerReadsIndexedPassages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-mcp-stdio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let vaultRoot = root.appendingPathComponent("Vault").path
        _ = try Vault(root: vaultRoot)
        let storePath = root.appendingPathComponent("store.sqlite3").path
        let store = try Store(path: storePath)
        try store.migrateSemanticIndex(repairOversizedTitles: false)
        _ = try store.replacePassagesChecked(
            for: IndexedSource(kind: .note, id: "external-mcp-proof"),
            title: "External MCP proof note",
            occurredAt: Date(timeIntervalSince1970: 7_100_000),
            text: "The external MCP process can find zephyrpilot and must return amberledger.")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.executablePath())
        process.arguments = ["--mcp", "--database", storePath, "--vault-root", vaultRoot]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        let lines = LineCollector(handle: stdout.fileHandleForReading)
        defer {
            lines.stop()
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        try process.run()

        try Self.send(["jsonrpc": "2.0", "id": 1, "method": "initialize"],
                      to: stdin.fileHandleForWriting)
        let handshake = try lines.nextLine(timeout: 20)
        #expect(Self.json(handshake)?["result"] != nil)

        try Self.send(["jsonrpc": "2.0", "method": "notifications/initialized"],
                      to: stdin.fileHandleForWriting)
        try Self.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                      to: stdin.fileHandleForWriting)
        let listed = try lines.nextLine(timeout: 5)
        let tools = (((Self.json(listed)?["result"] as? [String: Any])?["tools"])
                     as? [[String: Any]]) ?? []
        #expect(tools.contains { $0["name"] as? String == "recall" })

        try Self.send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "recall",
            "arguments": ["query": "zephyrpilot", "limit": 3],
        ]], to: stdin.fileHandleForWriting)
        let called = try lines.nextLine(timeout: 8)
        let result = try #require(Self.json(called)?["result"] as? [String: Any])
        let text = Self.contentText(result)

        #expect(result["isError"] as? Bool == false)
        #expect(text.contains("[1]"), "external MCP replies must be citeable")
        #expect(text.contains("Note"), "the citation has to name where the passage came from")
        #expect(text.contains("amberledger"),
                "this word was never sent in the query; it proves the process read the index")
    }

    private static func send(_ message: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func contentText(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]]) ?? [])
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }
}

private final class LineCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var lines: [String] = []

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            guard let self else { return }
            let data = readable.availableData
            guard !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 10) {
                let lineData = self.buffer.prefix(upTo: newline)
                self.buffer.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    self.lines.append(line)
                    self.semaphore.signal()
                }
            }
            self.lock.unlock()
        }
    }

    func nextLine(timeout: TimeInterval) throws -> String {
        if let line = popLine() { return line }
        let result = semaphore.wait(timeout: .now() + timeout)
        guard result == .success, let line = popLine() else {
            throw MCPStdioError.timeout
        }
        return line
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func popLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }
}

private enum MCPStdioError: Error {
    case timeout
}
