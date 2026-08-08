import Foundation

public enum BELWritebackError: Error, Equatable, CustomStringConvertible {
    case missingStatement
    case invalidKind(String)
    case invalidEntities

    public var description: String {
        switch self {
        case .missingStatement: "A memory proposal needs a statement."
        case .invalidKind(let value): "Unknown memory kind: \(value)."
        case .invalidEntities: "Memory entities must be an array of strings."
        }
    }
}

/// The only model-facing write path. Proposals are durable, but never committed without a human
/// confirmation through the existing Vault commit flow.
@MainActor
public enum BELBrainWriteback {
    public static let proposalSchema = BELJSONSchema(fields: [
        BELJSONField("statement", .string, required: true),
        BELJSONField("kind", .string),
        BELJSONField("source", .string),
        BELJSONField("entities", .array),
    ])

    @discardableResult
    public static func propose(json: String, vault: Vault, reason: String = "AI proposal",
                               date: Date = .now) throws -> MemoryCommit {
        let value = try BELStructuredOutputValidator.validate(json, against: proposalSchema)
        guard let object = value.objectValue,
              case .string(let statement) = object["statement"],
              !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BELWritebackError.missingStatement
        }
        let rawKind: String
        if case .string(let value) = object["kind"] { rawKind = value } else { rawKind = "note" }
        guard let kind = MemoryObject.Kind(rawValue: rawKind) else {
            throw BELWritebackError.invalidKind(rawKind)
        }
        let source: String
        if case .string(let value) = object["source"] { source = value } else { source = "" }
        let entities: [String]
        if case .array(let values) = object["entities"] {
            let strings = values.compactMap { value -> String? in
                guard case .string(let string) = value else { return nil }
                return string
            }
            guard strings.count == values.count else { throw BELWritebackError.invalidEntities }
            entities = strings
        } else if object["entities"] == nil {
            entities = []
        } else {
            throw BELWritebackError.invalidEntities
        }

        let memory = MemoryObject(level: .extracted, kind: kind, statement: statement,
                                  source: source, createdAt: date, validFrom: date,
                                  entities: entities)
        return try vault.propose(memory, reason: reason)
    }

    @discardableResult
    public static func confirm(commitID: String, in vault: Vault, date: Date = .now) throws
        -> MemoryObject {
        try vault.confirm(commitID: commitID, at: date)
    }

    public static func discard(commitID: String, in vault: Vault, date: Date = .now) throws {
        try vault.discard(commitID: commitID, at: date)
    }
}
