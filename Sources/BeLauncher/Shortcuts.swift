import Foundation
import AppKit
import UserNotifications
import BeLauncherCore

/// Bridge to Apple's Shortcuts app.
///
/// This is the one place a flow reaches outside the catalogue of built-in steps, and it is
/// deliberately narrow: it runs a shortcut *the user already created and authorised* in
/// Shortcuts.app, by name, as a process argument. There is no shell, so a name cannot become
/// a command, and BeLauncher never creates, edits or imports shortcuts.
@MainActor
enum Shortcuts {
    typealias ProcessRunner = @Sendable ([String]) -> BELShortcutCommandResult

    static func command(_ arguments: [String], using runner: ProcessRunner = defaultRunner)
        throws -> BELShortcutCommandResult {
        let result = runner(arguments)
        guard result.executableFound else { throw BELShortcutCommandError.toolUnavailable }
        guard result.terminationStatus == 0 else {
            throw BELShortcutCommandError.failed(status: result.terminationStatus,
                                                  detail: result.stderr)
        }
        return result
    }

    static func available(using runner: ProcessRunner = defaultRunner)
        -> Result<[String], BELShortcutCommandError> {
        let result = runner(["list"])
        guard result.executableFound else { return .failure(.toolUnavailable) }
        guard result.terminationStatus == 0 else {
            return .failure(.failed(status: result.terminationStatus, detail: result.stderr))
        }
        let names = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return .success(names)
    }

    static func validate(_ mapping: BELShortcutMapping,
                         availableNames: Set<String>) -> BELShortcutAvailability {
        guard mapping.isWellFormed else { return .invalidMapping }
        guard availableNames.contains(mapping.shortcutName) else { return .missing }
        return mapping.requiresForeground ? .availableForeground : .available
    }

    static func saveMapping(_ mapping: BELShortcutMapping) throws {
        guard mapping.isWellFormed else { throw ShortcutMappingError.invalid(mapping.actionID) }
        var values = mappings()
        values.removeAll { $0.actionID == mapping.actionID }
        values.append(mapping)
        let data = try JSONEncoder().encode(values.sorted { $0.actionID < $1.actionID })
        UserDefaults.standard.set(data, forKey: "bel_shortcut_mappings")
    }

    static func mappings() -> [BELShortcutMapping] {
        guard let data = UserDefaults.standard.data(forKey: "bel_shortcut_mappings"),
              let values = try? JSONDecoder().decode([BELShortcutMapping].self, from: data),
              BELShortcutMapping.validate(values).isEmpty else { return [] }
        return values.filter(\.enabled)
    }

    static func run(named name: String) throws -> BELShortcutCommandResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BELShortcutCommandError.invalidName }
        return try command(["run", trimmed])
    }

    /// Names of the user's shortcuts, for the picker in Settings. Empty when Shortcuts is
    /// unavailable — the field stays free-text so a flow can still be built.
    static func available() -> [String] {
        guard case .success(let names) = available(using: defaultRunner) else { return [] }
        return names
    }

    static let defaultRunner: ProcessRunner = { arguments in
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts") else {
            return BELShortcutCommandResult(executableFound: false, terminationStatus: -1,
                                            stdout: "", stderr: "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            return BELShortcutCommandResult(executableFound: true, terminationStatus: -1,
                                            stdout: "", stderr: String(error.localizedDescription.prefix(4_000)))
        }
        process.waitUntilExit()
        return BELShortcutCommandResult(
            executableFound: true,
            terminationStatus: process.terminationStatus,
            stdout: BELShortcutCommandResult.sanitized(stdout.fileHandleForReading.readDataToEndOfFile()),
            stderr: BELShortcutCommandResult.sanitized(stderr.fileHandleForReading.readDataToEndOfFile()))
    }
}

struct BELShortcutCommandResult: Sendable, Equatable {
    let executableFound: Bool
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    init(executableFound: Bool, terminationStatus: Int32, stdout: String, stderr: String) {
        self.executableFound = executableFound
        self.terminationStatus = terminationStatus
        self.stdout = String(stdout.prefix(16_000))
        self.stderr = String(stderr.prefix(4_000))
    }

    static func sanitized(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .filter { character in
                guard let ascii = character.asciiValue else { return true }
                return ascii == 9 || ascii == 10 || ascii == 13 || ascii >= 32
            }
            .replacingOccurrences(of: "\0", with: "")
    }
}

enum BELShortcutAvailability: Equatable {
    case available
    case availableForeground
    case missing
    case invalidMapping
}

enum BELShortcutCommandError: Error, Equatable {
    case invalidName
    case toolUnavailable
    case failed(status: Int32, detail: String)
}

enum ShortcutMappingStore {
    static func name(for actionID: String?) -> String? {
        guard let actionID else { return nil }
        guard let data = UserDefaults.standard.data(forKey: "bel_shortcut_mappings"),
              let values = try? JSONDecoder().decode([BELShortcutMapping].self, from: data),
              BELShortcutMapping.validate(values).isEmpty else { return nil }
        return values.first { $0.actionID == actionID && $0.enabled }?.shortcutName
    }

    static func mapping(for actionID: String?) -> BELShortcutMapping? {
        guard let actionID else { return nil }
        guard let data = UserDefaults.standard.data(forKey: "bel_shortcut_mappings"),
              let values = try? JSONDecoder().decode([BELShortcutMapping].self, from: data),
              BELShortcutMapping.validate(values).isEmpty else { return nil }
        return values.first { $0.actionID == actionID && $0.enabled }
    }
}

enum ShortcutMappingError: Error, Equatable {
    case invalid(String)
}

/// Local timers for the `timer` flow step. Notifications are requested the first time a flow
/// actually needs one, never at launch.
@MainActor
enum Timers {
    private static var requested = false

    static func schedule(minutes: Int, label: String) {
        let centre = UNUserNotificationCenter.current()
        if requested { return fire(minutes: minutes, label: label) }
        requested = true
        // Just in time: permission is asked the first time a flow actually sets a timer.
        Task { @MainActor in
            let granted = (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            fire(minutes: minutes, label: label)
        }
    }

    private static func fire(minutes: Int, label: String) {
        let content = UNMutableNotificationContent()
        content.title = label.isEmpty ? "BeLauncher" : label
        content.body = "Your \(minutes) minute timer is done."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes * 60), repeats: false
        )
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: trigger
        ))
    }
}
