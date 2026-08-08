import Foundation

public struct BELAIAuditEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case proposalRecorded
        case proposalConfirmed
        case proposalDiscarded
        case evidenceSaved
        case forgetPreviewed
        case forgetConfirmed
    }

    public let id: String
    public let action: Action
    public let result: String
    public let providerID: String?
    public let model: String?
    public let sensitivity: Sensitivity?
    public let reference: String?
    public let at: Date

    public init(action: Action, result: String, providerID: String? = nil,
                model: String? = nil, sensitivity: Sensitivity? = nil,
                reference: String? = nil, at: Date = .now) {
        self.id = UUID().uuidString
        self.action = action
        self.result = result
        self.providerID = providerID
        self.model = model
        self.sensitivity = sensitivity
        self.reference = reference
        self.at = at
    }
}

public enum BELWritebackError: Error, Equatable, CustomStringConvertible {
    case missingStatement
    case invalidKind(String)
    case invalidEntities
    case missingTitle
    case missingText
    case invalidPeriod

    public var description: String {
        switch self {
        case .missingStatement: "A memory proposal needs a statement."
        case .invalidKind(let value): "Unknown memory kind: \(value)."
        case .invalidEntities: "Memory entities must be an array of strings."
        case .missingTitle: "Saved evidence needs a title."
        case .missingText: "Saved evidence needs text."
        case .invalidPeriod: "The forget period is invalid."
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
        BELJSONField("body", .string),
        BELJSONField("owner", .string),
        BELJSONField("entities", .array),
    ])

    @discardableResult
    public static func propose(json: String, vault: Vault, reason: String = "AI proposal",
                               date: Date = .now, providerID: String? = nil,
                               model: String? = nil, sensitivity: Sensitivity? = nil) throws
        -> MemoryCommit {
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
        let body: String
        if case .string(let value) = object["body"] { body = value } else { body = "" }
        let owner: String
        if case .string(let value) = object["owner"] { owner = value } else { owner = "" }
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
                                  body: body, source: source, owner: owner,
                                  createdAt: date, validFrom: date,
                                  entities: entities)
        let commit = try vault.propose(memory, reason: reason)
        try vault.recordAIAudit(BELAIAuditEvent(
            action: .proposalRecorded, result: "proposal recorded", providerID: providerID,
            model: model, sensitivity: sensitivity, reference: commit.id, at: date))
        return commit
    }

    @discardableResult
    public static func confirm(commitID: String, in vault: Vault, date: Date = .now) throws
        -> MemoryObject {
        let object = try vault.confirm(commitID: commitID, at: date)
        try vault.recordAIAudit(BELAIAuditEvent(
            action: .proposalConfirmed, result: "proposal confirmed", reference: commitID,
            at: date))
        return object
    }

    public static func discard(commitID: String, in vault: Vault, date: Date = .now) throws {
        try vault.discard(commitID: commitID, at: date)
        try vault.recordAIAudit(BELAIAuditEvent(
            action: .proposalDiscarded, result: "proposal discarded", reference: commitID,
            at: date))
    }

    private static let evidenceSchema = BELJSONSchema(fields: [
        BELJSONField("title", .string, required: true),
        BELJSONField("text", .string, required: true),
        BELJSONField("sourcePath", .string),
    ])

    private static let projectSchema = BELJSONSchema(fields: [
        BELJSONField("statement", .string, required: true),
        BELJSONField("body", .string),
        BELJSONField("source", .string),
        BELJSONField("entities", .array),
    ])

    /// Project updates remain proposals. The model can describe the new state, but only the
    /// existing human confirmation path can make it current.
    @discardableResult
    public static func updateProject(json: String, vault: Vault, reason: String = "AI project update",
                                     date: Date = .now) throws -> MemoryCommit {
        let value = try BELStructuredOutputValidator.validate(json, against: projectSchema)
        guard var object = value.objectValue else { throw BELStructuredOutputError.notAnObject }
        object["kind"] = .string(MemoryObject.Kind.project.rawValue)
        let encoded = try JSONEncoder().encode(BELJSONValue.object(object))
        guard let normalized = String(data: encoded, encoding: .utf8) else {
            throw BELStructuredOutputError.invalidJSON
        }
        return try propose(json: normalized, vault: vault, reason: reason, date: date)
    }

    /// Saves explicit evidence to Inbox. This is not a memory commit and cannot become a fact by
    /// itself; it remains a Markdown source that a person can review and later propose from.
    @discardableResult
    public static func save(json: String, vault: Vault, date: Date = .now) throws -> String {
        let value = try BELStructuredOutputValidator.validate(json, against: evidenceSchema)
        guard let object = value.objectValue,
              case .string(let title) = object["title"],
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BELWritebackError.missingTitle
        }
        guard case .string(let text) = object["text"],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BELWritebackError.missingText
        }
        let sourcePath: String?
        if case .string(let value) = object["sourcePath"] { sourcePath = value } else { sourcePath = nil }
        let path = try vault.saveEvidence(title: title, text: text, at: date, sourcePath: sourcePath)
        try vault.recordAIAudit(BELAIAuditEvent(action: .evidenceSaved,
                                                  result: "evidence saved", reference: path,
                                                  at: date))
        return path
    }

    @discardableResult
    public static func previewForget(_ period: Privacy.Period, store: Store,
                                     vault: Vault? = nil, date: Date = .now)
        throws -> Privacy.Forgetting {
        let result = store.whatWouldBeForgotten(period)
        if let vault {
            try vault.recordAIAudit(BELAIAuditEvent(
                action: .forgetPreviewed, result: "forget preview: \(result.total) records",
                reference: String(date.timeIntervalSince1970), at: date))
        }
        return result
    }

    /// Destructive by design: callers must first show `previewForget` and then invoke this
    /// explicit confirmation method. Privacy itself remains the source of truth for deletion.
    @discardableResult
    public static func confirmForget(_ period: Privacy.Period, store: Store,
                                     vault: Vault? = nil, date: Date = .now)
        throws -> Privacy.Forgetting {
        let result = store.forget(period)
        if let vault {
            try vault.recordAIAudit(BELAIAuditEvent(
                action: .forgetConfirmed, result: "forget confirmed: \(result.total) records",
                reference: String(date.timeIntervalSince1970), at: date))
        }
        return result
    }
}
