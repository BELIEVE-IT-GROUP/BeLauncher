import Foundation

/// What you asked an assistant, and what it answered.
///
/// This is the highest-value source there is and one of the cheapest to reach: Claude Code already
/// writes every session to disk as JSONL in the user's own home folder. No screen capture, no new
/// permission, no daemon watching a browser. The file is already theirs.
///
/// And it answers the question a memory product exists for. "Cómo resolví lo de autenticación hace
/// dos meses" is almost never in a file — the file holds the result. The reasoning, the false
/// starts and the thing that finally worked are in the conversation.
public enum Conversations {

    public struct Exchange: Sendable, Equatable {
        public let at: Date
        /// What the person asked. This is the part worth indexing: it is short, it is in their own
        /// words, and it is what they will search for later.
        public let asked: String
        /// The answer, trimmed. Kept for context, not for quoting whole.
        public let answered: String
        /// Where the work was happening, which is what ties a conversation to a project.
        public let workingDirectory: String

        public init(at: Date, asked: String, answered: String, workingDirectory: String) {
            self.at = at
            self.asked = asked
            self.answered = answered
            self.workingDirectory = workingDirectory
        }
    }

    /// Where the sessions live.
    public static func sessionsFolder(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".claude/projects")
    }

    /// Questions shorter than this are "sí", "sigue", "arréglalo". True, useless, and numerous.
    public static let minimumQuestion = 25
    /// Only the head of an answer is kept. A full answer is pages long and would drown the
    /// question inside its own episode.
    public static let answerLimit = 600

    /// Reads one session file.
    ///
    /// Written line by line rather than parsed whole: these files reach tens of megabytes, and a
    /// single malformed line — a session killed mid-write — must not lose the rest of the day.
    public static func exchanges(inLines lines: [String]) -> [Exchange] {
        var result: [Exchange] = []
        var pendingQuestion: (text: String, at: Date, cwd: String)?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let kind = row["type"] as? String
            guard kind == "user" || kind == "assistant" else { continue }
            guard row["isSidechain"] as? Bool != true else { continue }

            let cwd = row["cwd"] as? String ?? ""
            let at = timestamp(row) ?? Date()
            let text = readable(row)
            guard !text.isEmpty else { continue }

            if kind == "user" {
                // Tool results come back as user rows. They are machine output, not something a
                // person said, and indexing them fills the brain with build logs.
                guard !isToolResult(row) else { continue }
                guard text.count >= minimumQuestion else { continue }
                pendingQuestion = (text, at, cwd)
            } else if let question = pendingQuestion {
                result.append(Exchange(at: question.at, asked: question.text,
                                       answered: String(text.prefix(answerLimit)),
                                       workingDirectory: question.cwd.isEmpty ? cwd : question.cwd))
                pendingQuestion = nil
            }
        }
        return result
    }

    /// The text a person would recognise, out of a content block that may hold thinking, tool
    /// calls and prose.
    ///
    /// Thinking is deliberately dropped. It is the model's private reasoning, it is long, and
    /// indexing it means a search for your own words returns the machine talking to itself.
    static func readable(_ row: [String: Any]) -> String {
        guard let message = row["message"] as? [String: Any] else { return "" }
        if let text = message["content"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        return blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isToolResult(_ row: [String: Any]) -> Bool {
        guard let message = row["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "tool_result" }
    }

    static func timestamp(_ row: [String: Any]) -> Date? {
        guard let raw = row["timestamp"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: raw)
            ?? ISO8601DateFormatter.withFractionalSeconds().date(from: raw)
    }

    /// Turns exchanges into things the index understands.
    ///
    /// The question leads, because the question is what somebody will search for months later, in
    /// their own words. The answer follows as context.
    public static func items(from exchanges: [Exchange]) -> [Indexer.Item] {
        exchanges.map { exchange in
            let project = Identity.project(fromPath: exchange.workingDirectory + "/x")
            let title = String(exchange.asked.prefix(70)).replacingOccurrences(of: "\n", with: " ")
            var text = exchange.asked
            if !exchange.answered.isEmpty { text += "\n\n" + exchange.answered }
            if let project { text += "\n\nProyecto: " + project }
            return Indexer.Item(
                source: IndexedSource(kind: .conversation,
                                      id: Semantic.digest(exchange.asked + "\(exchange.at.timeIntervalSince1970)").prefix(16).description),
                title: title, text: text, occurredAt: exchange.at
            )
        }
    }
}

extension ISO8601DateFormatter {
    /// Built fresh each call. A shared formatter is not Sendable and would race the background
    /// indexer, which is the same trap the vault's date stamp already documents.
    static func withFractionalSeconds() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
