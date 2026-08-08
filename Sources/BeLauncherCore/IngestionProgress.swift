import Foundation

/// One durable progress record shared by scheduled and manual source runs. It is intentionally
/// source-scoped: a Mail sync and an all-sources pass must never overwrite each other's meaning.
public struct IngestionProgress: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable, Equatable {
        case waiting, gathering, assembling, writing, completed, paused, deferred, failed
    }

    public let runID: String
    public let source: String
    public let phase: Phase
    public let completedItems: Int
    public let totalItems: Int
    public let writtenPassages: Int
    public let problem: String?
    public let updatedAt: Date

    public init(runID: String = UUID().uuidString, source: String = "corpus",
                phase: Phase, completedItems: Int = 0, totalItems: Int = 0,
                writtenPassages: Int = 0, problem: String? = nil, updatedAt: Date = .now) {
        self.runID = runID
        self.source = source
        self.phase = phase
        self.completedItems = max(0, completedItems)
        self.totalItems = max(0, totalItems)
        self.writtenPassages = max(0, writtenPassages)
        self.problem = problem
        self.updatedAt = updatedAt
    }

    public var fraction: Double? {
        guard totalItems > 0 else { return nil }
        return min(1, Double(completedItems) / Double(totalItems))
    }
}
