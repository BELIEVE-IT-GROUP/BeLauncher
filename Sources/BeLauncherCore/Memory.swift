import Foundation

/// The unit of the brain.
///
/// Four levels of truth, because a company does not just need notes: it needs to know what
/// happened, what the system thinks it means, what a human actually accepted, and how it turned
/// out. Only `committed` is treated as true.
public struct MemoryObject: Sendable, Equatable, Codable, Identifiable {

    public enum Level: String, Sendable, Codable, CaseIterable {
        /// What happened: an email, a document, a transcript, a metric.
        case evidence
        /// What the system read into it. An interpretation, not yet true.
        case extracted
        /// Accepted by a person. This is the only level that answers "what did we decide".
        case committed
        /// What happened afterwards: it worked, it failed, it was reverted.
        case outcome
    }

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case decision
        case commitment
        case policy
        case definition
        case learning
        case note
        case person
        case project
    }

    public enum Status: String, Sendable, Codable {
        case active
        /// Replaced by a newer object, kept for history.
        case superseded
        /// Explicitly retired without a replacement.
        case retired
    }

    public var id: String
    public var level: Level
    public var kind: Kind
    /// One sentence, the way a person would say it out loud.
    public var statement: String
    public var body: String
    public var source: String
    public var owner: String
    public var createdAt: Date
    public var validFrom: Date
    public var validUntil: Date?
    public var confidence: Double
    public var status: Status
    /// Every object this one replaces, and the one that replaced it. A list because a decision
    /// can settle several older ones at once, and losing that trail makes history unwalkable.
    public var supersedes: [String]
    public var supersededBy: String?
    public var entities: [String]
    public var evidence: [String]

    public init(
        id: String = UUID().uuidString,
        level: Level,
        kind: Kind,
        statement: String,
        body: String = "",
        source: String = "",
        owner: String = "",
        createdAt: Date = .now,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        confidence: Double = 1,
        status: Status = .active,
        supersedes: [String] = [],
        supersededBy: String? = nil,
        entities: [String] = [],
        evidence: [String] = []
    ) {
        self.id = id
        self.level = level
        self.kind = kind
        self.statement = statement
        self.body = body
        self.source = source
        self.owner = owner
        self.createdAt = createdAt
        self.validFrom = validFrom ?? createdAt
        self.validUntil = validUntil
        self.confidence = confidence
        self.status = status
        self.supersedes = supersedes
        self.supersededBy = supersededBy
        self.entities = entities
        self.evidence = evidence
    }

    /// True when this object is the current answer at a given moment. The whole point of the
    /// brain: not "what do we know about pricing" but "what is true about pricing *today*".
    public func isCurrent(at date: Date = .now) -> Bool {
        guard status == .active else { return false }
        guard validFrom <= date else { return false }
        if let validUntil { return date < validUntil }
        return true
    }
}

/// A proposed change to the brain, which a person confirms, edits or discards.
///
/// Nothing is written silently: an assistant that quietly folds its own guesses into the company's
/// memory is worse than no memory at all, because you stop being able to tell what was decided
/// from what was inferred.
public struct MemoryCommit: Sendable, Equatable, Codable, Identifiable {
    public enum State: String, Sendable, Codable {
        case proposed
        case confirmed
        case discarded
    }

    public var id: String
    public var object: MemoryObject
    public var state: State
    public var reason: String
    public var proposedAt: Date
    public var decidedAt: Date?
    /// Objects this commit would replace, detected before it is applied.
    public var conflicts: [String]

    public init(id: String = UUID().uuidString, object: MemoryObject, state: State = .proposed,
                reason: String = "", proposedAt: Date = .now, decidedAt: Date? = nil,
                conflicts: [String] = []) {
        self.id = id
        self.object = object
        self.state = state
        self.reason = reason
        self.proposedAt = proposedAt
        self.decidedAt = decidedAt
        self.conflicts = conflicts
    }
}

public enum MemoryError: Error, Equatable, CustomStringConvertible {
    case emptyStatement
    case invalidValidity
    case notProposed
    case unknownCommit(String)

    public var description: String {
        switch self {
        case .emptyStatement: L("A memory needs a sentence describing it.")
        case .invalidValidity: L("The end date cannot come before the start date.")
        case .notProposed: L("That commit has already been decided.")
        case .unknownCommit(let id): L("There is no commit %@.", id)
        }
    }
}
