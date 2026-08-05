import Foundation

/// Markdown with YAML front matter: the format Obsidian made ordinary.
///
/// Written by hand rather than with a YAML library on purpose — the shape is fixed and small, and
/// a dependency for eleven keys is not worth it. What matters is that the file stays readable and
/// editable in any editor, so the user's memory is never trapped in our app.
public enum VaultDocument {

    public static func render(_ object: MemoryObject) -> String {
        var lines = ["---"]
        lines.append("id: \(object.id)")
        lines.append("level: \(object.level.rawValue)")
        lines.append("kind: \(object.kind.rawValue)")
        lines.append("statement: \(quote(object.statement))")
        lines.append("status: \(object.status.rawValue)")
        lines.append("owner: \(quote(object.owner))")
        lines.append("source: \(quote(object.source))")
        lines.append("created_at: \(iso(object.createdAt))")
        lines.append("valid_from: \(iso(object.validFrom))")
        if let validUntil = object.validUntil { lines.append("valid_until: \(iso(validUntil))") }
        lines.append("confidence: \(object.confidence)")
        if !object.supersedes.isEmpty {
            lines.append("supersedes: [\(object.supersedes.map(quote).joined(separator: ", "))]")
        }
        if let supersededBy = object.supersededBy { lines.append("superseded_by: \(supersededBy)") }
        if !object.entities.isEmpty { lines.append("entities: [\(object.entities.map(quote).joined(separator: ", "))]") }
        if !object.evidence.isEmpty { lines.append("evidence: [\(object.evidence.map(quote).joined(separator: ", "))]") }
        lines.append("---")
        lines.append("")
        lines.append("# \(object.statement)")
        if !object.body.isEmpty {
            lines.append("")
            lines.append(object.body)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) -> MemoryObject? {
        // Scanned line by line rather than split on "\n---": a Markdown body legitimately
        // contains horizontal rules, and a substring split would put the boundary in the wrong
        // place the day someone writes one.
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = unquote(value)
        }

        guard let id = fields["id"],
              let statement = fields["statement"], !statement.isEmpty,
              let level = MemoryObject.Level(rawValue: fields["level"] ?? ""),
              let kind = MemoryObject.Kind(rawValue: fields["kind"] ?? "") else { return nil }

        let body = lines[(closing + 1)...]
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .drop { $0.hasPrefix("# ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return MemoryObject(
            id: id,
            level: level,
            kind: kind,
            statement: statement,
            body: body,
            source: fields["source"] ?? "",
            owner: fields["owner"] ?? "",
            createdAt: date(fields["created_at"]) ?? .now,
            validFrom: date(fields["valid_from"]),
            validUntil: date(fields["valid_until"]),
            confidence: Double(fields["confidence"] ?? "1") ?? 1,
            status: MemoryObject.Status(rawValue: fields["status"] ?? "") ?? .active,
            supersedes: list(fields["supersedes"]),
            supersededBy: fields["superseded_by"],
            entities: list(fields["entities"]),
            evidence: list(fields["evidence"])
        )
    }

    // MARK: - Scalars

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func list(_ value: String?) -> [String] {
        guard let value, value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        return String(value.dropFirst().dropLast())
            .split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
