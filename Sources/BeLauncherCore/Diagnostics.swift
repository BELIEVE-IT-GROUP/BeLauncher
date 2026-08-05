import Foundation

/// A plain-text report the user can read before sending it anywhere.
/// Contents are deliberately boring: counts, paths, toggles. No clipboard text, no secrets.
public struct DiagnosticsReport: Sendable {
    public var appVersion: String
    public var systemVersion: String
    public var databasePath: String
    public var databaseSizeBytes: Int
    public var snippetCount: Int
    public var workflowCount: Int
    public var clipCount: Int
    public var secretNames: [String]
    public var accessibilityGranted: Bool
    public var settings: [String: String]
    public var generatedAt: Date

    public func render() -> String {
        var lines: [String] = []
        lines.append("BeLauncher diagnostics")
        lines.append("generated: \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("app version: \(appVersion)")
        lines.append("macOS: \(systemVersion)")
        lines.append("")
        lines.append("database: \(databasePath)")
        lines.append("database size: \(databaseSizeBytes) bytes")
        lines.append("snippets: \(snippetCount)")
        lines.append("workflows: \(workflowCount)")
        lines.append("clipboard entries: \(clipCount)")
        lines.append("keychain secret names: \(secretNames.isEmpty ? "none" : secretNames.joined(separator: ", "))")
        lines.append("accessibility permission: \(accessibilityGranted ? "granted" : "not granted")")
        lines.append("")
        lines.append("settings:")
        for key in settings.keys.sorted() {
            lines.append("  \(key) = \(settings[key] ?? "")")
        }
        lines.append("")
        lines.append("No clipboard contents, snippet bodies or secret values are included in this file.")
        return lines.joined(separator: "\n")
    }
}

extension Store {
    public func diagnostics(appVersion: String, systemVersion: String, accessibilityGranted: Bool) -> DiagnosticsReport {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        let keys = ["hotkey", "clipboard_enabled", "clipboard_retention_days",
                    "clipboard_max_items", "launch_at_login", "update_check_enabled",
                    "paste_after_copy", "last_update_check"]
        var settings: [String: String] = [:]
        for key in keys { settings[key] = setting(key) ?? "(default)" }
        return DiagnosticsReport(
            appVersion: appVersion,
            systemVersion: systemVersion,
            databasePath: path,
            databaseSizeBytes: size,
            snippetCount: snippets().count,
            workflowCount: workflows().count,
            clipCount: clips(limit: 100_000).count,
            secretNames: Keychain.names(),
            accessibilityGranted: accessibilityGranted,
            settings: settings,
            generatedAt: .now
        )
    }
}
