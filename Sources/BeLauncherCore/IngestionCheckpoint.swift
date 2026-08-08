import Foundation

/// Durable progress for a background capture pass.
///
/// The checkpoint is deliberately small and source-scoped. Replaying the overlap is safe because
/// passage writes replace the same source records, while losing this marker would make a restart
/// indistinguishable from a first run.
public struct IngestionCheckpoint: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case gathering, assembling, writing, completed
    }

    public let id: String
    public let source: String
    public let windowStart: Date
    public let updatedAt: Date
    public let phase: Phase
    public let completed: Bool

    public init(id: String = UUID().uuidString, source: String = "corpus",
                windowStart: Date, updatedAt: Date = .now, phase: Phase,
                completed: Bool = false) {
        self.id = id
        self.source = source
        self.windowStart = windowStart
        self.updatedAt = updatedAt
        self.phase = phase
        self.completed = completed
    }

    /// A checkpoint belongs to one ingestion scope. A manual Mail sync must never resume the
    /// half-written all-sources pass that happened to be interrupted before it.
    public func canResume(source requestedSource: String) -> Bool {
        !completed && source == requestedSource
    }
}
