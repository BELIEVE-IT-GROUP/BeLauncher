import Foundation

public struct LicenseIdentity: Sendable, Equatable, Codable {
    public var email: String
    public var key: String
    public var deviceID: String
    /// Last time the server confirmed this activation. Nil means "never re-checked since activating".
    public var lastCheck: Date?

    public init(email: String, key: String, deviceID: String, lastCheck: Date? = nil) {
        self.email = email
        self.key = key
        self.deviceID = deviceID
        self.lastCheck = lastCheck
    }
}

public struct LicenseDevice: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let since: String
    /// The server currently returns only {name, since}. Without an id this seat cannot be
    /// released remotely, so the UI says so instead of offering a button that cannot work.
    public let deviceID: String?

    public var id: String { deviceID ?? name }
    public var canBeReleased: Bool { deviceID != nil }

    public init(name: String, since: String, deviceID: String? = nil) {
        self.name = name
        self.since = since
        self.deviceID = deviceID
    }
}

public enum ActivationOutcome: Sendable, Equatable {
    case activated(devicesUsed: Int, maxDevices: Int)
    case invalid
    case deviceLimit(devices: [LicenseDevice], maxDevices: Int)
    case serverError
    case unreachable(String)
    /// The request never reached the function: gateway rejection, wrong URL, bad anon key.
    /// Kept apart from `.invalid` so a misconfigured build never accuses the user's key.
    case rejected(status: Int)

    /// Message shown to the user, in the app's voice.
    public var message: String {
        switch self {
        case .activated:
            "Activated."
        case .invalid:
            L("Wrong email or key.")
        case .deviceLimit(_, let max):
            L("This licence is already on %@ Macs. Release one to activate this one.", String(max))
        case .serverError:
            L("Try again in a moment.")
        case .unreachable:
            L("We could not connect. Check your connection and try again.")
        case .rejected(let status):
            L("The licence server refused the request (HTTP %@). It is not your key: write to us if it keeps happening.",
              String(status))
        }
    }
}

public enum LicenseKey {
    /// Keys are compared in upper case; the user may type them however they like.
    public static func normalise(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    /// BELN-XXXX-XXXX-XXXX
    public static func isWellFormed(_ raw: String) -> Bool {
        normalise(raw).range(of: #"^BELN(-[A-Z0-9]{4}){3}$"#, options: .regularExpression) != nil
    }
}

public enum LicenseEmail {
    /// Case-insensitive and trimmed, as the server expects.
    public static func normalise(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isPlausible(_ raw: String) -> Bool {
        let value = normalise(raw)
        guard let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        let domain = value[value.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !value.contains(" ")
    }
}

public enum LicenseGate {
    /// A licensed machine works offline forever; the server is only consulted again after a
    /// month, and a failed check never revokes anything.
    public static let revalidateAfter: TimeInterval = 30 * 24 * 3600

    public static func shouldRevalidate(lastCheck: Date?, now: Date = .now) -> Bool {
        guard let lastCheck else { return false }
        return now.timeIntervalSince(lastCheck) >= revalidateAfter
    }
}
