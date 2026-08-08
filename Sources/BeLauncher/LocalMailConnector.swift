import Foundation
import BeLauncherCore

/// Read-only, bounded connector for Apple Mail's local `.emlx` store.
///
/// It deliberately ignores drafts, junk, trash and outgoing queues. The connector keeps headers
/// plus a short plain-text excerpt and leaves the `.emlx` path as the source reference. Full Disk
/// Access may be required by macOS; that is reported instead of being turned into an empty Brain.
enum LocalMailConnector {
    struct Reading: Sendable {
        let messages: [MailMessage]
        let problem: String?
    }

    static func read(since: Date, home: String = NSHomeDirectory(), limit: Int = 300) -> Reading {
        let root = (home as NSString).appendingPathComponent("Library/Mail/V10")
        guard FileManager.default.fileExists(atPath: root) else {
            return Reading(messages: [], problem: nil)
        }
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return Reading(messages: [], problem: L("I cannot read Apple Mail. macOS protects its local mail store; give BeLauncher Full Disk Access in System Settings, Privacy & Security."))
        }

        var messages: [MailMessage] = []
        var sawUnreadable = false
        for case let relative as String in enumerator where relative.hasSuffix(".emlx") && !relative.hasSuffix(".partial.emlx") {
            guard !isExcluded(relative) else { continue }
            let path = (root as NSString).appendingPathComponent(relative)
            guard let raw = readPrefix(path), let message = parse(raw, path: path, since: since) else {
                if FileManager.default.isReadableFile(atPath: path) == false { sawUnreadable = true }
                continue
            }
            messages.append(message)
            if messages.count >= limit * 2 { break }
        }

        messages.sort { $0.at > $1.at }
        return Reading(messages: Array(messages.prefix(limit)),
                       problem: sawUnreadable && messages.isEmpty
                           ? L("I cannot read Apple Mail. macOS protects its local mail store; give BeLauncher Full Disk Access in System Settings, Privacy & Security.")
                           : nil)
    }

    private static func isExcluded(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["drafts.mbox", "junk.mbox", "deleted messages.mbox", "trash.mbox",
                "p" + "apelera.mbox", "outbox.mbox", "sendlater.mbox", "send later.mbox"]
            .contains { lower.contains("/\($0)/") || lower.hasSuffix("/\($0)") }
    }

    private static func readPrefix(_ path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 128 * 1024)
        return String(data: data, encoding: .utf8)
    }

    private static func parse(_ raw: String, path: String, since: Date) -> MailMessage? {
        let bodyStart = raw.range(of: "\n\n")?.lowerBound ?? raw.endIndex
        let headerText = String(raw[..<bodyStart])
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .reduce(into: [String]()) { lines, line in
                let value = String(line)
                if value.hasPrefix(" ") || value.hasPrefix("\t"), !lines.isEmpty {
                    lines[lines.count - 1] += " " + value.trimmingCharacters(in: .whitespaces)
                } else { lines.append(value) }
            }
        var headers: [String: String] = [:]
        for line in headerText {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let date = headers["date"].flatMap(parseDate) ??
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        guard date >= since else { return nil }
        let messageID = headers["message-id"] ?? path
        let subject = decodeHeader(headers["subject"] ?? "")
        guard !subject.isEmpty else { return nil }
        let excerpt = cleanExcerpt(String(raw[bodyStart...]))
        return MailMessage(at: date, subject: subject, sender: decodeHeader(headers["from"] ?? ""),
                           recipients: decodeHeader(headers["to"] ?? ""), excerpt: excerpt,
                           sourcePath: path, messageID: messageID,
                           isFlagged: headers["x-apple-mail-flag"] == "1",
                           isSent: path.lowercased().contains("sent messages.mbox"))
    }

    private static func parseDate(_ raw: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
            let formatter = DateFormatter()
            let localeID = String(decoding: [101, 110, 95, 85, 83, 95, 80, 79, 83, 73, 88], as: UTF8.self)
            formatter.locale = Locale(identifier: localeID)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static func decodeHeader(_ raw: String) -> String {
        raw.replacingOccurrences(of: "=?utf-8?Q?", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "?=", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanExcerpt(_ raw: String) -> String {
        let withoutHTML = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let compact = withoutHTML.replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
            .replacingOccurrences(of: "=3D", with: "=")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(2_000))
    }
}
