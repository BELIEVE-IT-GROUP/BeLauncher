import Foundation

public struct Snippet: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64
    public var keyword: String
    public var title: String
    public var body: String
    public var uses: Int

    public init(id: Int64 = 0, keyword: String, title: String, body: String, uses: Int = 0) {
        self.id = id
        self.keyword = keyword
        self.title = title
        self.body = body
        self.uses = uses
    }
}

public struct Workflow: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64
    public var keyword: String
    public var title: String
    /// A URL template such as `https://github.com/search?q={query}`.
    /// Only http/https/mailto survive validation — BeLauncher never executes scripts.
    public var urlTemplate: String
    public var uses: Int

    public init(id: Int64 = 0, keyword: String, title: String, urlTemplate: String, uses: Int = 0) {
        self.id = id
        self.keyword = keyword
        self.title = title
        self.urlTemplate = urlTemplate
        self.uses = uses
    }
}

public struct Clip: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case text
        case image
        case file
        case link
    }

    public var id: Int64
    public var text: String
    public var sourceApp: String
    public var createdAt: Date
    public var kind: Kind
    /// Pinned clips survive trimming and sort above the rest.
    public var isPinned: Bool
    /// For images: where the copy was written. Empty for anything else.
    public var assetPath: String

    public init(id: Int64 = 0, text: String, sourceApp: String = "", createdAt: Date = .now,
                kind: Kind = .text, isPinned: Bool = false, assetPath: String = "") {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.kind = kind
        self.isPinned = isPinned
        self.assetPath = assetPath
    }

    /// Detected from the content itself, so a copied URL or path reads as what it is.
    public static func detectKind(_ text: String) -> Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"),
           !trimmed.contains(" "), URL(string: trimmed) != nil { return .link }
        if trimmed.hasPrefix("/"), !trimmed.contains("\n"),
           FileManager.default.fileExists(atPath: trimmed) { return .file }
        return .text
    }
}

/// Validation errors surfaced to the user as recoverable inline messages.
public enum ValidationError: Error, Equatable, CustomStringConvertible {
    case emptyKeyword
    case keywordHasWhitespace
    case emptyBody
    case duplicateKeyword(String)
    case emptyTitle
    case badURLTemplate(String)

    public var description: String {
        switch self {
        case .emptyKeyword: "Keyword cannot be empty."
        case .keywordHasWhitespace: "Keyword cannot contain spaces."
        case .emptyBody: "Snippet text cannot be empty."
        case .duplicateKeyword(let k): "The keyword “\(k)” is already in use."
        case .emptyTitle: "Title cannot be empty."
        case .badURLTemplate(let reason): "Invalid URL template: \(reason)"
        }
    }
}

public enum Validate {
    public static func keyword(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyKeyword }
        guard !trimmed.contains(where: \.isWhitespace) else { throw ValidationError.keywordHasWhitespace }
        return trimmed.lowercased()
    }

    public static func title(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyTitle }
        return trimmed
    }

    public static func snippetBody(_ raw: String) throws -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyBody
        }
        return raw
    }
}
