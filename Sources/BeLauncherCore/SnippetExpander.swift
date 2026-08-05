import Foundation

public struct ExpandedSnippet: Sendable, Equatable {
    public let text: String
    /// Offset of `{cursor}` in `text`, or nil when the snippet has no cursor marker.
    public let cursorOffset: Int?
}

/// The core transformation of the app: snippet template → final text.
/// Every source of non-determinism is injected so the behaviour is fully testable.
public struct SnippetExpander: Sendable {
    public var clipboard: @Sendable () -> String?
    public var secret: @Sendable (String) -> String?
    public var uuid: @Sendable () -> String
    public var now: Date
    public var locale: Locale

    public init(
        clipboard: @escaping @Sendable () -> String? = { nil },
        secret: @escaping @Sendable (String) -> String? = { _ in nil },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString },
        now: Date = .now,
        locale: Locale = .current
    ) {
        self.clipboard = clipboard
        self.secret = secret
        self.uuid = uuid
        self.now = now
        self.locale = locale
    }

    /// Supported tokens: `{clipboard}` `{date}` `{date:FORMAT}` `{time}` `{uuid}` `{cursor}`
    /// `{secret:NAME}` `{query}`. `{{` and `}}` are literal braces.
    /// Unknown tokens are left untouched rather than silently deleted — a typo should be visible.
    public func expand(_ template: String, query: String = "") -> ExpandedSnippet {
        var output = ""
        var cursorOffset: Int?
        var index = template.startIndex

        while index < template.endIndex {
            let character = template[index]

            if character == "{", template.index(after: index) < template.endIndex,
               template[template.index(after: index)] == "{" {
                output.append("{")
                index = template.index(index, offsetBy: 2)
                continue
            }
            if character == "}", template.index(after: index) < template.endIndex,
               template[template.index(after: index)] == "}" {
                output.append("}")
                index = template.index(index, offsetBy: 2)
                continue
            }
            guard character == "{",
                  let close = template[index...].firstIndex(of: "}") else {
                output.append(character)
                index = template.index(after: index)
                continue
            }

            let token = String(template[template.index(after: index)..<close])
            switch resolve(token, query: query) {
            case .text(let value):
                output.append(value)
            case .cursor:
                if cursorOffset == nil { cursorOffset = output.count }
            case .unknown:
                output.append("{\(token)}")
            }
            index = template.index(after: close)
        }

        return ExpandedSnippet(text: output, cursorOffset: cursorOffset)
    }

    private enum Resolution {
        case text(String)
        case cursor
        case unknown
    }

    private func resolve(_ token: String, query: String) -> Resolution {
        let name: String
        let argument: String?
        if let colon = token.firstIndex(of: ":") {
            name = String(token[token.startIndex..<colon]).lowercased()
            argument = String(token[token.index(after: colon)...])
        } else {
            name = token.lowercased()
            argument = nil
        }

        switch name {
        case "cursor":
            return .cursor
        case "clipboard":
            return .text(clipboard() ?? "")
        case "query":
            return .text(query)
        case "uuid":
            return .text(uuid())
        case "date":
            return .text(formatted(argument ?? "yyyy-MM-dd"))
        case "time":
            return .text(formatted(argument ?? "HH:mm"))
        case "secret":
            guard let argument, !argument.isEmpty else { return .unknown }
            return .text(secret(argument) ?? "")
        default:
            return .unknown
        }
    }

    private func formatted(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter.string(from: now)
    }
}
