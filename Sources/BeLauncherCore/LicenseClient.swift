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

    /// A prefix, not a directory: the function name is appended straight onto it.
    public static let productionBaseURL = URL(
        string: "https://supabase.believe-global.com/functions/v1/belauncher_landing_44aa9b_"
    )!

    /// `appendingPathComponent` would insert a slash and turn the prefix into a folder,
    /// which is a 500 from the Edge runtime. Concatenation is the whole point here.
    func url(for function: String) -> URL {
        URL(string: baseURL.absoluteString + function) ?? baseURL
    }

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
        let response: (data: Data, status: Int)
        do {
            response = try await send("validate-license", body: body)
        } catch {
            return .unreachable("\(error.localizedDescription)")
        }

        let payload = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]

        // A rejection from the Supabase gateway (401 with no anon key, 404 on a wrong path)
        // is not the user's key being wrong. Only a 200 carrying `valid` is a verdict.
        guard let payload, payload["valid"] != nil else {
            return (200..<300).contains(response.status) ? .serverError : .rejected(status: response.status)
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
        guard let response = try? await send("deactivate-device", body: body),
              let payload = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            return false
        }
        return payload["ok"] as? Bool == true
    }

    // MARK: - Transport

    private func send(_ function: String, body: [String: String]) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url(for: function))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport(request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
    }
}

/// Where the activation lives once it succeeds.
///
/// Deliberately **not** the Keychain. macOS asks the user to authorise access whenever the
/// requesting binary's signature differs from the one that wrote the item, and that dialog
/// blocks launch before the app can draw anything — a frozen menu-bar app with an invisible
/// prompt is the worst possible first run.
///
/// The licence is not a secret worth that cost: it is the user's own key, it is printed in
/// their purchase email, and the seat limit is enforced by the server against the device id.
/// Copying the file to another Mac does not grant a seat, because the stored device id no
/// longer matches the machine and the app asks to activate again.
///
/// The Keychain is still used for what it is good at: the `{secret:NAME}` values a user puts
/// in snippets, where a prompt is survivable because nothing is blocked on it.
@MainActor
public enum LicenseVault {
    private static let settingsKey = "license"
    private static var store: Store?

    /// Wired once at launch, before anything asks for the licence.
    public static func use(_ store: Store) { self.store = store }

    public static func save(_ identity: LicenseIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        store?.setSetting(settingsKey, String(decoding: data, as: UTF8.self))
    }

    /// Returns nil when this Mac is not the one that was activated, so a copied database
    /// cannot carry a licence to another machine.
    public static func load(currentDeviceID: String) -> LicenseIdentity? {
        guard let raw = store?.setting(settingsKey),
              let identity = try? JSONDecoder().decode(LicenseIdentity.self, from: Data(raw.utf8)),
              identity.deviceID == currentDeviceID else { return nil }
        return identity
    }

    public static func clear() {
        store?.setSetting(settingsKey, "")
    }
}
