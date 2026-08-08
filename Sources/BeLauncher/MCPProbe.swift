import Foundation
import BeLauncherCore

/// Runs the five checks for real, one client at a time, so "conectado" in Ajustes means that
/// assistant would actually get something back.
///
/// Three things make it a diagnosis rather than a formality:
///
/// - **It launches what the client has written down**, not this app's own binary. A copy of
///   BeLauncher launched by BeLauncher always starts; the question is whether the path saved in
///   Claude Desktop months ago still leads anywhere.
/// - **It asks `recall`**, the tool that has to reach the semantic index. `search_memory` reads
///   the vault and answers perfectly well with the brain unplugged, which made the panel green in
///   the one case it was built to catch.
/// - **It plants what it expects to get back.** The reply is checked for a token that was never
///   sent in the question, so an empty answer cannot pass by echoing the query.
@MainActor
public enum MCPProbe {

    /// How long to wait for one reply before calling that step failed.
    public static let stepTimeout: TimeInterval = 5

    /// The first reply gets much longer, and it is not slack: the subprocess loads the whole app
    /// binary and then looks for an embedding model before it answers `initialize`. Charging that
    /// startup to a five second budget would paint a healthy connection red on a cold launch,
    /// which is the same lie as a false green with the colours swapped.
    public static let launchTimeout: TimeInterval = 20

    /// How often the pipe is looked at while nothing is arriving. Small enough to be invisible
    /// against a reply that takes hundreds of milliseconds, large enough not to spin a core.
    static let pollInterval: TimeInterval = 0.01

    /// One fixed row in the index, reused by every probe, never a new one per run.
    ///
    /// The canary used to be written to the person's real vault as a committed memory: if the app
    /// died between the save and the cleanup, a permanent `.md` was left inside the deliberate
    /// memory it was auditing, and it showed up in their searches afterwards. Nothing is written
    /// to the vault now. This lives in the passage index instead, where a crash can leave behind
    /// at most this single row, the next probe overwrites it, and the app's own reindex removes it
    /// unprompted, since no source of this kind is ever produced by the indexer.
    static let canarySource = IndexedSource(kind: .note, id: "belauncher-sonda-mcp")

    /// One report per known client, each one probed through the command that client will really
    /// run. Identical commands are probed once and shared: four clients pointing at the same
    /// binary genuinely have the same answer, but a broken Claude Desktop and a healthy Claude
    /// Code do not, and copying one verdict into both rows is how the panel used to lie twice.
    ///
    /// `executablePath` is where this copy of BeLauncher lives. It is not what gets launched; it
    /// is what the failure message compares against when a client's saved path is dead.
    public static func diagnose(executablePath: String) async -> [MCPHealth.Report] {
        var commandByClient: [String: [String]] = [:]
        for client in MCPClient.all {
            let data = FileManager.default.contents(atPath: client.absoluteConfigPath())
            if let command = MCPHealth.commandStored(in: data, client: client) {
                commandByClient[client.id] = command
            }
        }

        let canary = MCPHealth.Canary.make()
        let store = try? Store(path: Store.defaultPath())
        try? store?.migrateSemanticIndex(repairOversizedTitles: false)
        let planted = plant(canary, in: store)
        defer { store?.removePassages(for: canarySource) }

        var byCommand: [String: Connectivity] = [:]
        for command in commandByClient.values {
            let key = command.joined(separator: "\u{1F}")
            guard byCommand[key] == nil else { continue }
            byCommand[key] = await probeConnectivity(command: command, canary: canary,
                                                     executablePath: executablePath)
        }

        // A token that was never planted is passed as empty rather than as itself: the reply
        // cannot contain it, and the report says why instead of blaming the pipe.
        let expected = planted ? canary.echo : ""

        return MCPClient.all.map { client in
            guard let command = commandByClient[client.id],
                  let connectivity = byCommand[command.joined(separator: "\u{1F}")] else {
                return MCPHealth.report(
                    clientName: client.name, configured: false, launch: nil,
                    handshake: nil, toolsList: nil, toolCall: nil, echoing: expected)
            }
            return MCPHealth.report(
                clientName: client.name, configured: true, launch: connectivity.launch,
                handshake: connectivity.handshake, toolsList: connectivity.toolsList,
                toolCall: connectivity.toolCall, echoing: expected)
        }
    }

    // MARK: - The canary

    /// Writes the canary passage straight into the index, without going through a reindex.
    ///
    /// `replacePassages` touches exactly one source; `reindex` would rebuild everything and drop
    /// every source it did not receive, which from here would mean wiping the person's entire
    /// index to run a health check.
    private static func plant(_ canary: MCPHealth.Canary, in store: Store?) -> Bool {
        guard let store else { return false }
        return !store.replacePassages(for: canarySource, title: MCPHealth.Canary.mark,
                                      occurredAt: .now, text: canary.statement).isEmpty
    }

    private struct Connectivity {
        let launch: MCPHealth.LaunchOutcome?
        let handshake: String?
        let toolsList: String?
        let toolCall: String?
    }

    /// The live part: one subprocess, walked through the same messages a real client sends.
    private static func probeConnectivity(
        command: [String], canary: MCPHealth.Canary, executablePath: String
    ) async -> Connectivity {
        guard let executable = command.first else {
            return Connectivity(launch: .failed(L("that client keeps no command at all")),
                                handshake: nil, toolsList: nil, toolCall: nil)
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            // Naming both paths turns "no arranca" into an instruction: the app moved, and the
            // configuration still points at where it used to be.
            let moved = executable == executablePath
                ? ""
                : L(" BeLauncher is now at %@.", executablePath)
            return Connectivity(
                launch: .failed(L("the path kept in that client, %1$@, no longer leads to anything runnable.%2$@",
                                  executable, moved)),
                handshake: nil, toolsList: nil, toolCall: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()   // discarded: diagnostics live in stdout's JSON-RPC only

        // Whatever happens below, this process does not get to outlive the diagnosis. Closing our
        // end of stdin first lets a healthy server exit on its own; the terminate is for one that
        // will not. Both of these now actually run: with the old blocking read they were
        // unreachable, which is what left orphan processes behind.
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? stdout.fileHandleForReading.close()
        }

        do {
            try process.run()
        } catch {
            return Connectivity(launch: .failed(error.localizedDescription),
                                handshake: nil, toolsList: nil, toolCall: nil)
        }

        let source = stdout.fileHandleForReading
        makeNonBlocking(source.fileDescriptor)
        let feed = MCPHealth.LineFeed()

        func awaitLine(_ timeout: TimeInterval) async -> MCPHealth.LineRead {
            await MCPHealth.nextLine(
                from: feed,
                deadline: Date().addingTimeInterval(timeout),
                peek: { peek(source.fileDescriptor) },
                pause: { try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000)) })
        }

        func send(_ message: [String: Any]) {
            guard process.isRunning,
                  let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        }

        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:] as [String: Any]])
        guard case .line(let handshake) = await awaitLine(launchTimeout) else {
            return Connectivity(launch: .started, handshake: nil, toolsList: nil, toolCall: nil)
        }

        send(["jsonrpc": "2.0", "method": "notifications/initialized"])   // no reply expected

        send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        guard case .line(let toolsList) = await awaitLine(stepTimeout) else {
            return Connectivity(launch: .started, handshake: handshake, toolsList: nil,
                                toolCall: nil)
        }

        // `recall`, not `search_memory`. The vault tool answers fine with `context.brain` nil, so
        // it certified a connection that hands the assistant nothing: the whole point of the last
        // step is to exercise the path that has to reach the index.
        send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "recall",
            "arguments": ["query": canary.needle, "limit": MCPTools.maximumLimit],
        ]])
        guard case .line(let toolCall) = await awaitLine(stepTimeout) else {
            return Connectivity(launch: .started, handshake: handshake, toolsList: toolsList,
                                toolCall: nil)
        }

        return Connectivity(launch: .started, handshake: handshake, toolsList: toolsList,
                            toolCall: toolCall)
    }

    // MARK: - The pipe

    /// Without this the read blocks a thread that no deadline can interrupt.
    private static func makeNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// One look at the pipe, returning immediately whatever the state of the other end.
    private static func peek(_ descriptor: Int32) -> MCPHealth.PipePeek {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        if count > 0 { return .bytes(Data(bytes.prefix(count))) }
        if count == 0 { return .closed }
        // EINTR is a signal arriving mid-syscall, not a broken pipe: retrying is the whole
        // contract of that error, and treating it as EOF would report a healthy server as dead.
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? .idle : .closed
    }
}
