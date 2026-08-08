import Foundation

/// Durable, provider-neutral state for work that can outlive the Settings window.
/// It is deliberately metadata only: model weights and runtimes never pass through this file.
public struct InstallProgressSnapshot: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable, Equatable {
        case idle, checking, installing, downloading, ready, cancelled, failed
    }

    public let providerID: String
    public let model: String?
    public let phase: Phase
    public let step: String?
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let message: String?
    public let updatedAt: Date

    public init(providerID: String, model: String? = nil, phase: Phase,
                step: String? = nil, completedBytes: Int64 = 0,
                totalBytes: Int64 = 0, message: String? = nil, updatedAt: Date = .now) {
        self.providerID = providerID
        self.model = model
        self.phase = phase
        self.step = step
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = max(0, totalBytes)
        self.message = message
        self.updatedAt = updatedAt
    }

    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

/// A tiny atomic JSON ledger shared by local model installers. Callers can inject a root in tests.
public enum InstallProgressStore {
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/install-progress.json")
    }

    public static func load(providerID: String, from url: URL = defaultURL()) -> InstallProgressSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([InstallProgressSnapshot].self, from: data)
        else { return nil }
        return all.first { $0.providerID == providerID }
    }

    public static func save(_ snapshot: InstallProgressSnapshot,
                            to url: URL = defaultURL()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        var all = (try? JSONDecoder().decode([InstallProgressSnapshot].self,
                                              from: Data(contentsOf: url))) ?? []
        all.removeAll { $0.providerID == snapshot.providerID }
        all.append(snapshot)
        let data = try JSONEncoder().encode(all)
        try data.write(to: url, options: .atomic)
    }
}
