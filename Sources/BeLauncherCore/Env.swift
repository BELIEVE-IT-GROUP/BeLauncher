import Foundation

/// Tiny `.env` reader. Only non-secret configuration belongs here (see `.env.example`);
/// real secrets go to the Keychain.
public enum Env {
    public static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals]
                .replacingOccurrences(of: "export ", with: "")
                .trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    /// Reads `~/Library/Application Support/BeLauncher/.env` first, then a `.env` beside the app.
    public static func load(paths: [String]) -> [String: String] {
        var merged: [String: String] = [:]
        for path in paths {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            merged.merge(parse(contents)) { _, new in new }
        }
        return merged
    }
}
