import Foundation

/// Whether "conectado" means something, told in five checks instead of one boolean.
///
/// Ajustes used to call a client connected the moment its configuration file mentioned
/// BeLauncher's `--mcp` entry. That is intent, not proof: the file can be written correctly and
/// the assistant can still get nothing back, because the binary might not launch, the handshake
/// might not finish, the tool list might come back empty, or — the failure that matters most,
/// because it is exactly what was happening — every step above answers just fine and the real
/// call at the end comes back with nothing useful. Each of those is a distinct, silent failure
/// with its own fix, so they are modelled and reported one by one instead of collapsed into a
/// single green dot.
///
/// Pure on purpose: everything here is fed strings, tokens and closures, so the whole module is
/// testable without ever launching a process. That now includes the give-up rule the probe reads
/// its pipe with — the app target has no tests of its own, and the one part of this feature that
/// hung forever in production was a loop with no way out, which is exactly the kind of thing that
/// has to be provable somewhere.
public enum MCPHealth {

    /// In the order they have to happen. A later step is meaningless once an earlier one failed,
    /// which is why `report(...)` marks everything downstream of a failure as `.skipped` rather
    /// than pretending it was checked.
    public enum Step: Int, Sendable, CaseIterable, Comparable {
        case configured
        case launched
        case handshake
        case toolsListed
        case toolCalled

        public static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .configured: L("The assistant knows about BeLauncher")
            case .launched: L("The process starts")
            case .handshake: L("The opening handshake completes")
            case .toolsListed: L("The tools show up")
            case .toolCalled: L("A real call brings data back")
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        case passed
        /// A previous step already failed, so this one never ran.
        case skipped
        case failed(String)

        public var isHealthy: Bool { self == .passed }

        public var reason: String? {
            guard case .failed(let why) = self else { return nil }
            return why
        }
    }

    public struct StepStatus: Sendable, Equatable {
        public let step: Step
        public let outcome: Outcome
    }

    public enum LaunchOutcome: Sendable, Equatable {
        case started
        case failed(String)
    }

    // MARK: - Per-step evaluation

    public static func evaluateConfigured(_ configured: Bool) -> Outcome {
        configured
            ? .passed
            : .failed(L("It is not in that client's configuration. Press Connect in Settings."))
    }

    public static func evaluateLaunch(_ launch: LaunchOutcome?) -> Outcome {
        guard let launch else { return .skipped }
        switch launch {
        case .started:
            return .passed
        case .failed(let why):
            return .failed(L("The process did not start (%@). Check that BeLauncher is still installed at that path.", why))
        }
    }

    /// `raw` is the JSON-RPC reply to `initialize`, or `nil` if nothing came back in time.
    public static func evaluateHandshake(_ raw: String?) -> Outcome {
        guard let raw else {
            return .failed(L("No answer to the opening handshake (initialize). The process may have hung, or closed before replying."))
        }
        guard let envelope = parseEnvelope(raw) else {
            return .failed(L("It answered the handshake with something that is not valid JSON."))
        }
        if let error = envelope["error"] as? [String: Any] {
            return .failed(L("The handshake came back with an error: %@.", errorMessage(error)))
        }
        guard let result = envelope["result"] as? [String: Any],
              result["protocolVersion"] != nil else {
            return .failed(L("The handshake replied with no protocolVersion: it does not speak MCP."))
        }
        return .passed
    }

    /// `raw` is the JSON-RPC reply to `tools/list`, or `nil` if nothing came back in time.
    public static func evaluateToolsList(_ raw: String?) -> Outcome {
        guard let raw else {
            return .failed(L("No answer when asked for the tool list (tools/list)."))
        }
        guard let envelope = parseEnvelope(raw) else {
            return .failed(L("The tool list is not valid JSON."))
        }
        if let error = envelope["error"] as? [String: Any] {
            return .failed(L("Asking for the tool list came back with an error: %@.", errorMessage(error)))
        }
        guard let result = envelope["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return .failed(L("The reply carries no tool list at all."))
        }
        guard !tools.isEmpty else {
            return .failed(L("The server answered but announced zero tools: the assistant would have nothing to call."))
        }
        return .passed
    }

    /// The check that matters most: a real call has to bring back real material, and the only
    /// proof of that is finding something in the reply that could not have arrived by any other
    /// route. `expected` is the canary's `echo`: planted in the index seconds earlier and never
    /// sent in the question.
    ///
    /// This used to work the other way round, against a list of phrases meaning "encontré nada",
    /// and it was wrong from the first day it shipped. The marker read "no tiene nada sobre" while
    /// `search_memory` answers "La memoria deliberada no tiene ningún objeto sobre «…»": not one
    /// marker matched, so the five steps went green with the brain returning nothing at all — the
    /// exact failure this whole type exists to catch. Adding the missing sentences would not fix
    /// it either. A list of literal phrases pins this file to the wording of another one, and one
    /// of those markers ("falta la") already turned a correct answer red, because "a Acme le falta
    /// la firma del contrato" is a real fact carrying real data. Looking for a token we planted
    /// ourselves cannot drift when somebody improves a message.
    public static func evaluateToolCall(
        _ raw: String?, echoing expected: String
    ) -> Outcome {
        guard let raw else {
            return .failed(L("No answer to the test call (tools/call)."))
        }
        guard let envelope = parseEnvelope(raw) else {
            return .failed(L("The reply to the test call is not valid JSON."))
        }
        if let error = envelope["error"] as? [String: Any] {
            return .failed(L("The test call came back with an error: %@.", errorMessage(error)))
        }
        guard let result = envelope["result"] as? [String: Any] else {
            return .failed(L("The reply carries no result."))
        }
        let text = contentText(result)
        // The tool's own words, not a paraphrase of them. A probe against an older build answers
        // "Esa herramienta no existe.", which sends somebody to update the app; "error interno"
        // sends them nowhere.
        if (result["isError"] as? Bool) == true {
            return .failed(text.isEmpty
                ? L("The tool ran but came back with an internal error.")
                : L("The tool ran but came back with an error: “%@”.", String(text.prefix(120))))
        }
        guard let content = result["content"] as? [[String: Any]], !content.isEmpty else {
            return .failed(L("The tool replied with no content: the assistant would have nothing to read."))
        }
        guard !text.isEmpty else {
            return .failed(L("The tool replied with empty text."))
        }
        guard !expected.isEmpty else {
            return .failed(L("The test datum could not be put into the index, so this call proves nothing. Rebuild the index under “Brain status” and check again."))
        }
        guard text.lowercased().contains(expected.lowercased()) else {
            return .failed(L("It answered, but with no real datum: it said “%@”. The circuit works, the content did not arrive.", String(text.prefix(80))))
        }
        return .passed
    }

    // MARK: - The canary

    /// The statement planted in the index right before probing, so the last check can look for
    /// what a reply *contains* instead of for what it fails to say.
    ///
    /// Two tokens, and this is the part that is easy to get wrong: every tool prints the question
    /// back inside its own "no encontré nada" line ("La memoria deliberada no tiene ningún objeto
    /// sobre «…»", "No encontré nada sobre «…»"). A probe that looks for the thing it just asked
    /// about therefore passes on a completely empty answer. `needle` is what gets asked and is
    /// expected to come back in those echoes; `echo` never leaves this process inside a question,
    /// so a reply can only carry it by having read the planted text.
    ///
    /// Alphanumeric tokens rather than raw UUIDs because the word index splits on everything that
    /// is not a letter or a digit: a token with dashes stops being one rare term and becomes five
    /// common ones.
    public struct Canary: Sendable, Equatable {
        /// Asked for. Unique, so the word index ranks the planted passage first.
        public let needle: String
        /// Expected back. Never sent.
        public let echo: String

        public init(needle: String, echo: String) {
            self.needle = needle
            self.echo = echo
        }

        /// The readable part, identical on every run, so a person who stumbles on this passage in
        /// their own search results can tell what it is.
        /// Not translated, and that is the point: this string is planted in the index, searched
        /// for, and deleted seconds later. If it followed the interface language, a probe started
        /// in English and finished after a language change would look for a sentence that no longer
        /// exists — a self-test that fails for a reason having nothing to do with the connection.
        public static let mark = "BeLauncher internal MCP connection test"

        /// What gets written to the index. No colons and no long first word: `SecretGuard` would
        /// read `NOMBRE: valor` or a long bare token as a credential and drop the passage on the
        /// way out, which would look exactly like the failure being tested for.
        public var statement: String {
            "\(Self.mark). Word asked \(needle), word returned \(echo). "
            + "It deletes itself as soon as the check finishes."
        }

        public static func make(seed: UUID = UUID()) -> Canary {
            let hex = seed.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return Canary(needle: "canario" + String(hex.prefix(12)),
                          echo: "eco" + String(hex.suffix(12)))
        }
    }

    // MARK: - What the client will actually run

    /// The command written in a client's own configuration, arguments included.
    ///
    /// The probe used to launch `Bundle.main.executablePath`, which answers a question nobody
    /// asked: of course this copy of the app runs, it is the one doing the asking. Move the app
    /// from Downloads to Applications and the assistant keeps launching a path that no longer
    /// exists, while the panel shows five green steps for a binary the assistant never reaches.
    public static func commandStored(in data: Data?, client: MCPClient) -> [String]? {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[client.serversKey] as? [String: Any],
              let entry = servers[MCPSetup.serverName] as? [String: Any],
              let command = entry["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return [command] + ((entry["args"] as? [String]) ?? [])
    }

    // MARK: - JSON-RPC parsing, tolerant of malformed input

    static func parseEnvelope(_ raw: String) -> [String: Any]? {
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func errorMessage(_ error: [String: Any]) -> String {
        (error["message"] as? String) ?? L("no detail")
    }

    /// Everything the assistant would read, as one string.
    static func contentText(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]]) ?? [])
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Report

    public struct Report: Sendable, Equatable, Identifiable {
        public var id: String { clientName }
        public let clientName: String
        public let steps: [StepStatus]
        public let checkedAt: Date

        /// The only thing Ajustes should trust as "sí, está conectado": every step, including
        /// the last one, came back healthy.
        public var isConnected: Bool { steps.allSatisfy { $0.outcome.isHealthy } }

        public var firstFailure: StepStatus? {
            steps.first { if case .failed = $0.outcome { true } else { false } }
        }

        /// One line, for a status pill in Ajustes.
        public var summary: String {
            if isConnected { return L("%@: really connected.", clientName) }
            guard let failure = firstFailure else { return L("%@: unchecked.", clientName) }
            return L("%1$@: fails at “%2$@”. %3$@", clientName, failure.step.title,
                     failure.outcome.reason ?? "")
        }

        public func render() -> String {
            var lines = [clientName,
                         isConnected ? "  " + L("really connected") : "  " + L("not connected")]
            for status in steps {
                let mark: String
                switch status.outcome {
                case .passed: mark = "✓"
                case .skipped: mark = "·"
                case .failed: mark = "✗"
                }
                lines.append("  \(mark) \(status.step.title)")
                if let reason = status.outcome.reason {
                    lines.append("    \(reason)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Assembles one client's report from raw signals, marking everything downstream of the
    /// first failure as `.skipped` — running `tools/call` when `initialize` never answered would
    /// just report the same failure twice under a different name.
    ///
    /// `echoing` is the token the last reply has to carry. It defaults to the canary's fixed mark
    /// rather than to a per-run token so a caller assembling a report from replies it already has
    /// (a test, a saved transcript) still gets a real check instead of a free pass.
    public static func report(
        clientName: String, configured: Bool, launch: LaunchOutcome?,
        handshake: String?, toolsList: String?, toolCall: String?,
        echoing expected: String, at date: Date = .now
    ) -> Report {
        let configuredOutcome = evaluateConfigured(configured)
        let launchOutcome = configuredOutcome.isHealthy ? evaluateLaunch(launch) : .skipped
        let handshakeOutcome = launchOutcome.isHealthy ? evaluateHandshake(handshake) : .skipped
        let toolsListOutcome = handshakeOutcome.isHealthy ? evaluateToolsList(toolsList) : .skipped
        let toolCallOutcome = toolsListOutcome.isHealthy
            ? evaluateToolCall(toolCall, echoing: expected)
            : .skipped

        return Report(clientName: clientName, steps: [
            StepStatus(step: .configured, outcome: configuredOutcome),
            StepStatus(step: .launched, outcome: launchOutcome),
            StepStatus(step: .handshake, outcome: handshakeOutcome),
            StepStatus(step: .toolsListed, outcome: toolsListOutcome),
            StepStatus(step: .toolCalled, outcome: toolCallOutcome),
        ], checkedAt: date)
    }

    /// A full diagnostic, ready for a terminal or a text view: one block per client.
    public static func render(_ reports: [Report]) -> String {
        reports.map { $0.render() }.joined(separator: "\n\n")
    }

    // MARK: - Reading a pipe without hanging on it

    /// One line out of the subprocess, or the honest reason there is none.
    public enum LineRead: Sendable, Equatable {
        case line(String)
        case eof
        case timedOut
    }

    /// What a single non-blocking look at the pipe came back with.
    ///
    /// `idle` is the case the old code had no way to express, and that is precisely why its five
    /// second timeout did not exist: it raced a blocking read against a sleep inside a task group,
    /// and the sleep winning did nothing, because `availableData` is not cancellable and the group
    /// waits for every child before it returns. Measured against `/bin/sleep 120` the call never
    /// came back at all, so `defer { process.terminate() }` never ran, an orphan subprocess was
    /// left behind and the "Comprobar" button in Ajustes stayed disabled for the rest of the
    /// session. Being able to say "nothing right now" is what lets a deadline be enforced.
    public enum PipePeek: Sendable, Equatable {
        case bytes(Data)
        case idle
        case closed
    }

    /// The bytes seen so far, cut into lines as they complete.
    ///
    /// Main-actor bound rather than `@unchecked Sendable`. The old reader claimed only one task
    /// ever touched it, which stopped being true the moment a read timed out: the blocked task
    /// kept appending to the buffer while the next step started another read on the same object.
    /// The deadlock was hiding a data race, and fixing the deadlock alone would have released it.
    @MainActor
    public final class LineFeed {
        private var buffer = Data()

        public init() {}

        public func append(_ data: Data) { buffer.append(data) }

        /// Pops the first complete line, leaving the rest of the bytes for the next call.
        public func takeLine() -> String? {
            guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
            let line = String(data: buffer[..<newline], encoding: .utf8)
            buffer.removeSubrange(...newline)
            return line
        }

        /// Whatever is left when the pipe closes without a final newline.
        public func drain() -> String? {
            guard !buffer.isEmpty else { return nil }
            let rest = String(data: buffer, encoding: .utf8)
            buffer.removeAll()
            return rest
        }
    }

    /// Waits for one line, giving up when the clock passes `deadline`.
    ///
    /// The clock, the peek and the pause are all injected so the give-up rule can be tested
    /// without a subprocess: the bug being fixed here was never about pipes, it was a loop that
    /// had no way out.
    @MainActor
    public static func nextLine(
        from feed: LineFeed, deadline: Date, now: () -> Date = { Date() },
        peek: () -> PipePeek, pause: () async -> Void
    ) async -> LineRead {
        while true {
            // A finished line always wins over the clock: bytes that arrived in time are an
            // answer, however late the check for them runs.
            if let line = feed.takeLine() { return .line(line) }
            if now() >= deadline { return .timedOut }
            switch peek() {
            case .bytes(let data): feed.append(data)
            case .closed: return feed.drain().map { .line($0) } ?? .eof
            case .idle: await pause()
            }
        }
    }
}
