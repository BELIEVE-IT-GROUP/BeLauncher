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

    public static func text(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let folded = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        for trigger in ["nota ", "apunta ", "anota ", "note "] where folded.hasPrefix(trigger) {
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

    /// Where notes live: the vault's inbox, whose whole job is being emptied.
    public static func folder(inVaultAt root: String) -> String {
        (root as NSString).appendingPathComponent("inbox")
    }
}
