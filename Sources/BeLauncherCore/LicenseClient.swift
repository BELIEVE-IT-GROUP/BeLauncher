import Foundation

/// Talks to the two license endpoints. The app never issues licenses: it only asks the server
/// to validate one and to attach or detach this Mac.
public struct LicenseClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let baseURL: URL
    public let anonKey: String
    /// Injected so every response shape can be asserted without a network.
    public var transport: Transport

    public init(
        baseURL: URL,
        anonKey: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.transport = transport
    }

    public static let productionBaseURL = URL(
        string: "https://supabase.believe-global.com/functions/v1/belauncher_landing_44aa9b_"
    )!

    // MARK: - Activate

    public func activate(
        email: String,
        key: String,
        deviceID: String,
        deviceName: String
    ) async -> ActivationOutcome {
        let body: [String: String] = [
            "email": LicenseEmail.normalise(email),
            "key": LicenseKey.normalise(key),
            "device_id": deviceID,
            "device_name": deviceName,
        ]
        guard let data = try? await send("validate-license", body: body) else {
            return .unreachable("network")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .serverError
        }

        guard payload["valid"] as? Bool == true else { return .invalid }

        if payload["activated"] as? Bool == true {
            return .activated(
                devicesUsed: payload["devices_used"] as? Int ?? 1,
                maxDevices: payload["max_devices"] as? Int ?? 3
            )
        }

        let maxDevices = payload["max_devices"] as? Int ?? 3
        switch payload["reason"] as? String {
        case "device_limit":
            let raw = payload["devices"] as? [[String: Any]] ?? []
            let devices = raw.map {
                LicenseDevice(
                    name: $0["name"] as? String ?? "Mac",
                    since: $0["since"] as? String ?? "",
                    // Accepted under either name, so the app works the moment the server sends it.
                    deviceID: ($0["id"] ?? $0["device_id"]) as? String
                )
            }
            return .deviceLimit(devices: devices, maxDevices: maxDevices)
        default:
            return .serverError
        }
    }

    // MARK: - Deactivate

    /// Frees a seat. Used both from Settings and from the device-limit screen.
    public func deactivate(email: String, key: String, deviceID: String) async -> Bool {
        let body: [String: String] = [
            "email": LicenseEmail.normalise(email),
            "key": LicenseKey.normalise(key),
            "device_id": deviceID,
        ]
        guard let data = try? await send("deactivate-device", body: body),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return payload["ok"] as? Bool == true
    }

    // MARK: - Transport

    private func send(_ function: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(function))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await transport(request)
        return data
    }
}

/// Where the activation lives once it succeeds: the Keychain, so it survives a reinstall of the
/// app bundle and never sits in the database or an export file.
public enum LicenseVault {
    public static let service = "com.believe.belauncher.license"
    private static let account = "activation"

    public static func save(_ identity: LicenseIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Keychain.Failure.status(status) }
    }

    public static func load() -> LicenseIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(LicenseIdentity.self, from: data)
    }

    public static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
