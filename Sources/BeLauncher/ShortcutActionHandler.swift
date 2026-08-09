import Foundation
import BeLauncherCore

struct BELShortcutActionInput: Codable, Sendable {
    let name: String
}

/// Runs a user-owned Shortcut by argument, never by shell interpolation. The result carries the
/// real exit code and bounded stderr so Settings and the launcher can explain a missing or failed
/// shortcut instead of reporting a silent success.
struct ShortcutActionHandler: BELActionHandler {
    let actionID = "shortcuts.run"

    init?(definition: BELActionDefinition) {
        guard definition.id == "shortcuts.run", definition.adapter == .shortcut else { return nil }
    }

    func perform(input: Data) async throws -> BELActionResult {
        let value = try JSONDecoder().decode(BELShortcutActionInput.self, from: input)
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw ShortcutActionError.invalidName
        }
        let executable = "/usr/bin/shortcuts"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShortcutActionError.toolUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["run", name]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ShortcutActionError.launchFailed(error.localizedDescription)
        }

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ShortcutActionError.failed(status: process.terminationStatus,
                                              detail: String(problem.prefix(4_000)))
        }
        return BELActionResult(text: String(output.prefix(16_000)), receipt: "shortcut:\(name)")
    }
}

enum ShortcutActionError: Error, Equatable {
    case invalidName
    case toolUnavailable
    case launchFailed(String)
    case failed(status: Int32, detail: String)
}
