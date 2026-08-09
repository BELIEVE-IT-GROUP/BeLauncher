import Foundation

/// Keeping the Mac awake, and jotting something down.
///
/// Both of these exist as separate apps on most Macs, and both are one line of intent. The point
/// of a launcher is that a single-purpose app in the menu bar is a single-purpose app you can
/// delete: the value is not the feature, it is the app that stops needing to exist.

// MARK: - Staying awake

public enum StayAwake {

    /// The lengths worth offering. Ending at "hasta que lo apague" because the honest answer to
    /// "how long is this render going to take" is usually "I do not know".
    public static let durations: [(minutes: Int?, label: String)] = [
        (nil, L("Until I turn it off")),
        (15, "15 minutos"),
        (30, "30 minutos"),
        (60, "1 hora"),
        (120, "2 horas"),
        (300, "5 horas"),
    ]

    public static func offers(for query: String) -> [(minutes: Int?, label: String)]? {
        let folded = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
        guard folded.count >= 3 else { return nil }

        let triggers = ["cafeina", "caffeine", "no dormir", "que no se duerma", "despierto",
                        "mantener despierto", "caffeinate", "insomnio"]
        guard let trigger = triggers.first(where: { folded == $0 || folded.hasPrefix($0 + " ") })
        else { return nil }

        // "cafeina 2 horas" jumps straight to that one instead of showing the menu again.
        let rest = String(folded.dropFirst(trigger.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return durations }
        if let asked = minutes(fromPhrase: rest) {
            return [(asked, label(forMinutes: asked))]
        }
        return durations.filter { $0.label.lowercased().contains(rest) }
    }

    /// "2 horas", "45 min", "1h" — the ways someone actually writes a duration.
    public static func minutes(fromPhrase phrase: String) -> Int? {
        let folded = phrase.lowercased()
        guard let number = folded.split(whereSeparator: { !$0.isNumber })
            .first.flatMap({ Int($0) }), number > 0 else { return nil }

        let isHours = folded.contains("hora") || folded.contains("hour")
            || folded.hasSuffix("h") || folded.contains(" h")
        let total = isHours ? number * 60 : number
        // A day is the ceiling: past that it is indefinite in everything but name, and a
        // forgotten assertion that outlives the day is how a laptop cooks in a bag.
        return total <= 1_440 ? total : nil
    }

    public static func label(forMinutes minutes: Int) -> String {
        if minutes % 60 == 0, minutes >= 60 {
            let hours = minutes / 60
            return hours == 1 ? "1 hora" : "\(hours) horas"
        }
        return "\(minutes) minutos"
    }

    /// What the menu bar says while it is on.
    public static func remaining(until end: Date?, now: Date = .now) -> String {
        guard let end else { return L("Awake · no end") }
        let left = Int(end.timeIntervalSince(now) / 60)
        guard left > 0 else { return L("Awake · finishing") }
        return left >= 60
            ? L("Awake · %1$@ h %2$@ min", String(left / 60), String(left % 60))
            : L("Awake · %@ min", String(left))
    }
}

// MARK: - Quick notes

/// Something you want out of your head and into a file, now.
///
/// It lands in the vault's `inbox` as ordinary Markdown, which means it is already in the folder
/// that opens in Obsidian and already inside whatever backup that folder has. What it explicitly
/// does *not* do is ask for confirmation the way a memory does: a memory is something the company
/// now believes and deserves a person agreeing to it, while a note is yours and asking would
/// defeat the entire purpose of typing it in one line.
public enum QuickNote {

    public struct Record: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case note
            case evidence
        }

        public enum State: String, Sendable, Equatable {
            case pending
            case needsTranscription
        }

        public let id: String
        public let title: String
        public let excerpt: String
        public let path: String
        public let reviewed: Bool
        public let kind: Kind
        public let state: State
        public let createdAt: Date?
        public let sourcePath: String?
        public let attachmentPath: String?
    }

    public static let triggers = [
        "nota rapida", "nota rápida", "crear nota", "nueva nota",
        "quick note", "new note", "write note", "note to self",
        "nota", "apunta", "anota", "note",
    ]

    public static func isTrigger(_ query: String) -> Bool {
        let folded = query.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return triggers.contains(folded)
    }

    public static func text(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let folded = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        for trigger in triggers.sorted(by: { $0.count > $1.count }).map({ $0 + " " })
        where folded.hasPrefix(trigger) {
            let text = String(trimmed.dropFirst(trigger.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// A filename that sorts by time and still says what it is.
    public static func filename(for text: String, at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: date)
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return SafeFilename.make("\(stamp) \(words)", extension: "md")
    }

    /// The file itself: front matter so it is machine-readable later, body so it is readable now.
    public static func render(_ text: String, at date: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        return """
            ---
            created: \(formatter.string(from: date))
            kind: nota
            ---

            \(text)

            """
    }

    public static func renderEvidence(title: String, text: String, at date: Date = .now,
                                      sourcePath: String? = nil,
                                      attachmentPath: String? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        let source = sourcePath.map { "source_path: \($0.replacingOccurrences(of: "\n", with: " "))\n" } ?? ""
        let attachment = attachmentPath.map {
            "attachment_path: \($0.replacingOccurrences(of: "\n", with: " "))\n"
        } ?? ""
        return """
            ---
            created: \(formatter.string(from: date))
            kind: evidence
            title: \(title.replacingOccurrences(of: "\n", with: " "))
            \(source)\(attachment)---

            # \(title)

            \(text)

            """
    }

    /// Where notes live: the vault's inbox, whose whole job is being emptied.
    public static func folder(inVaultAt root: String) -> String {
        (root as NSString).appendingPathComponent("inbox")
    }

    /// Returns the human text from an Inbox Markdown file without exposing its front matter to a
    /// reader or to a memory proposal.
    public static func body(from raw: String) -> String {
        frontMatter(in: raw)?.body ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits only the YAML envelope at the start of the file. Markdown bodies are allowed to
    /// contain horizontal rules, so splitting on every `---` corrupts a note during an edit.
    private static func frontMatter(in raw: String) -> (header: String, body: String)? {
        let lines = raw.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return nil }
        let header = lines[1..<closing].joined(separator: "\n")
        let bodyStart = lines.index(after: closing)
        let body = bodyStart < lines.endIndex
            ? lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (header, body)
    }

    public static func records(inVaultAt root: String) -> [Record] {
        let folder = folder(inVaultAt: root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.compactMap { name in
            let path = (folder as NSString).appendingPathComponent(name)
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let reviewed = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "reviewed: true" }
            let frontMatter = QuickNote.frontMatter(in: raw)?.header ?? ""
            let body = QuickNote.body(from: raw)
            let metadata = Dictionary(uniqueKeysWithValues: frontMatter
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> (String, String)? in
                    let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    return (parts[0].trimmingCharacters(in: .whitespaces).lowercased(),
                            parts[1].trimmingCharacters(in: .whitespaces))
                })
            let title = metadata["title"] ?? body.split(whereSeparator: \.isNewline).first.map(String.init)
                ?? (name as NSString).deletingPathExtension
            let kind: Record.Kind = metadata["kind"]?.lowercased() == "evidence" ? .evidence : .note
            let createdAt = metadata["created"].flatMap { ISO8601DateFormatter().date(from: $0) }
            let awaitingTranscription = raw.localizedCaseInsensitiveContains("awaiting transcription")
                || raw.localizedCaseInsensitiveContains("transcription failed")
            return Record(id: path, title: title, excerpt: String(body.prefix(180)), path: path,
                          reviewed: reviewed, kind: kind,
                          state: awaitingTranscription ? .needsTranscription : .pending,
                          createdAt: createdAt, sourcePath: metadata["source_path"],
                          attachmentPath: metadata["attachment_path"])
        }.sorted { $0.id > $1.id }
    }

    /// Keeps the note in the inbox and search index while recording that a person has triaged it.
    /// Moving files between folders would make the note disappear from search and would lose the
    /// original evidence trail, so review is explicit metadata instead.
    public static func markReviewed(_ record: Record) throws {
        var raw = try String(contentsOfFile: record.path, encoding: .utf8)
        guard !raw.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "reviewed: true" }) else {
            return
        }
        if let parsed = frontMatter(in: raw) {
            let header = parsed.header + "\nreviewed: true\n"
            raw = "---\n\(header)---\n\n\(parsed.body)\n"
        } else {
            raw = "---\nreviewed: true\n---\n\n" + raw
        }
        try raw.write(toFile: record.path, atomically: true, encoding: .utf8)
    }

    /// Discards the Inbox envelope without touching the original audio or source file.
    /// The Inbox is a triage queue; removing its Markdown entry must not destroy evidence.
    public static func discard(_ record: Record) throws {
        try FileManager.default.removeItem(atPath: record.path)
    }

    /// Updates only the human body while preserving the note's front matter and source metadata.
    /// Notes stay in the inbox so the Brain can keep their provenance and review state.
    public static func updateBody(_ record: Record, body: String) throws {
        let raw = try String(contentsOfFile: record.path, encoding: .utf8)
        guard let parsed = frontMatter(in: raw) else { throw UpdateError.invalidNote }
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = "---\n\(parsed.header)\n---\n\n\(clean)\n"
        try updated.write(toFile: record.path, atomically: true, encoding: .utf8)
    }

    public enum UpdateError: LocalizedError {
        case invalidNote

        public var errorDescription: String? { "The note has invalid Markdown front matter." }
    }
}
