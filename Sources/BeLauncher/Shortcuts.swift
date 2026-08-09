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

    static func run(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", trimmed]        // arguments, never a shell string
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("BeLauncher: could not run shortcut “\(trimmed)”: \(error.localizedDescription)")
        }
    }

    /// Names of the user's shortcuts, for the picker in Settings. Empty when Shortcuts is
    /// unavailable — the field stays free-text so a flow can still be built.
    static func available() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }
}

enum ShortcutMappingStore {
    static func name(for actionID: String?) -> String? {
        guard let actionID else { return nil }
        guard let data = UserDefaults.standard.data(forKey: "bel_shortcut_mappings"),
              let values = try? JSONDecoder().decode([BELShortcutMapping].self, from: data),
              BELShortcutMapping.validate(values).isEmpty else { return nil }
        return values.first { $0.actionID == actionID && $0.enabled }?.shortcutName
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
