import Foundation

/// Provider-neutral checks used before a potentially large local model install.
/// Network availability is classified from the provider's real response; no probe is run on launch.
public enum InstallDiagnostics {
    public enum DiskStatus: Sendable, Equatable {
        case enough(freeBytes: Int64)
        case insufficient(freeBytes: Int64)
        case unknown
    }

    public enum NetworkFailure: Sendable, Equatable {
        case offline
        case serverUnavailable
        case badResponse(status: Int)
        case other(String)
    }

    public static func disk(requiredBytes: Int64,
                            freeBytes: Int64?) -> DiskStatus {
        guard let freeBytes else { return .unknown }
        return freeBytes >= requiredBytes ? .enough(freeBytes: freeBytes)
                                          : .insufficient(freeBytes: freeBytes)
    }

    public static func networkFailure(from raw: String) -> NetworkFailure {
        let value = raw.lowercased()
        if value.contains("offline") || value.contains("network") || value.contains("internet")
            || value.contains("not connected") || value.contains("timed out") {
            return .offline
        }
        if value.contains("connection refused") || value.contains("could not connect")
            || value.contains("server") {
            return .serverUnavailable
        }
        return .other(raw)
    }

    public static func networkMessage(for failure: NetworkFailure,
                                      providerName: String? = nil) -> String {
        switch failure {
        case .offline:
            L("No internet connection. Check the network and try again.")
        case .serverUnavailable:
            providerName.map { L("%@ is not answering. Start it and try again.", $0) }
                ?? L("The local model service is not answering. Start it and try again.")
        case .badResponse(let status):
            L("The model service returned an unexpected response (%@). Try again.", String(status))
        case .other(let raw):
            L("The download failed: %@", raw)
        }
    }

    public static func diskMessage(requiredBytes: Int64, freeBytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return L("This install needs about %@, but only %@ is free on the disk.",
                 formatter.string(fromByteCount: requiredBytes),
                 formatter.string(fromByteCount: freeBytes))
    }
}
