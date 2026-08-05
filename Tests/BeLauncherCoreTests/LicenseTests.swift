import Testing
import Foundation
@testable import BeLauncherCore

private func client(status: Int = 200, json: String) -> LicenseClient {
    LicenseClient(baseURL: URL(string: "https://example.com/f_")!, anonKey: "anon") { request in
        (Data(json.utf8), HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

@Suite("License input")
struct LicenseInputTests {

    @Test("keys are compared in upper case and without spaces")
    func keyNormalisation() {
        #expect(LicenseKey.normalise(" beln-a1b2-c3d4-e5f6 ") == "BELN-A1B2-C3D4-E5F6")
        #expect(LicenseKey.isWellFormed("beln-a1b2-c3d4-e5f6"))
        #expect(!LicenseKey.isWellFormed("BELN-A1B2-C3D4"))
        #expect(!LicenseKey.isWellFormed("XXXX-A1B2-C3D4-E5F6"))
        #expect(!LicenseKey.isWellFormed("BELN-A1B2-C3D4-E5F6-7890"))
    }

    @Test("emails are trimmed and lower-cased before they travel")
    func emailNormalisation() {
        #expect(LicenseEmail.normalise("  Jorge@Believe-Global.com ") == "jorge@believe-global.com")
        #expect(LicenseEmail.isPlausible("jorge@believe-global.com"))
        #expect(!LicenseEmail.isPlausible("jorge@localhost"))
        #expect(!LicenseEmail.isPlausible("@believe.com"))
        #expect(!LicenseEmail.isPlausible("jorge believe.com"))
    }

    @Test("an activated Mac is only re-checked after 30 days, and never before activating")
    func revalidationWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LicenseGate.shouldRevalidate(lastCheck: nil, now: now) == false)
        #expect(LicenseGate.shouldRevalidate(lastCheck: now.addingTimeInterval(-29 * 86_400), now: now) == false)
        #expect(LicenseGate.shouldRevalidate(lastCheck: now.addingTimeInterval(-31 * 86_400), now: now) == true)
    }
}

@Suite("License client")
struct LicenseClientTests {

    @Test("wrong email or key")
    func invalid() async {
        let outcome = await client(json: #"{"valid":false}"#)
            .activate(email: "a@b.com", key: "BELN-0000-0000-0000", deviceID: "D", deviceName: "Mac")
        #expect(outcome == .invalid)
        #expect(outcome.message == "Correo o clave incorrectos.")
    }

    @Test("successful activation reports the seat count")
    func activated() async {
        let outcome = await client(json: #"{"valid":true,"activated":true,"devices_used":2,"max_devices":3}"#)
            .activate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac")
        #expect(outcome == .activated(devicesUsed: 2, maxDevices: 3))
    }

    @Test("device limit returns the list with ids, ready for the release button")
    func deviceLimit() async {
        let json = #"""
        {"valid":true,"activated":false,"reason":"device_limit","max_devices":3,
         "devices":[{"device_id":"UUID-1","name":"MacBook de Jorge","since":"2026-01-02"},
                    {"device_id":"UUID-2","name":"iMac","since":"2026-03-04"}]}
        """#
        let outcome = await client(json: json)
            .activate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac")
        guard case .deviceLimit(let devices, let max) = outcome else {
            Issue.record("expected a device limit")
            return
        }
        #expect(max == 3)
        #expect(devices.map(\.name) == ["MacBook de Jorge", "iMac"])
        #expect(devices.map(\.deviceID) == ["UUID-1", "UUID-2"])
        #expect(devices.allSatisfy { $0.canBeReleased })
        #expect(outcome.message == "Esta licencia ya está en 3 Macs. Libera uno para activar este.")
    }

    @Test("an older server without ids degrades to a list you cannot release from")
    func deviceLimitWithoutIDs() async {
        let json = #"""
        {"valid":true,"activated":false,"reason":"device_limit","max_devices":3,
         "devices":[{"name":"iMac","since":"2026-03-04"}]}
        """#
        let outcome = await client(json: json)
            .activate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac")
        guard case .deviceLimit(let devices, _) = outcome else {
            Issue.record("expected a device limit")
            return
        }
        #expect(devices.first?.deviceID == nil)
        #expect(devices.first?.canBeReleased == false)
    }

    @Test("server_error is surfaced as a retry, not as an invalid license")
    func serverError() async {
        let outcome = await client(json: #"{"valid":true,"activated":false,"reason":"server_error","max_devices":3}"#)
            .activate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac")
        #expect(outcome == .serverError)
        #expect(outcome.message == "Intenta de nuevo en un momento.")
    }

    @Test("an unreachable server never reads as an invalid license")
    func offline() async {
        struct Offline: Error {}
        let offline = LicenseClient(baseURL: URL(string: "https://example.com/f_")!, anonKey: "anon") { _ in
            throw Offline()
        }
        let outcome = await offline.activate(
            email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac"
        )
        guard case .unreachable = outcome else {
            Issue.record("offline must not read as anything else, got \(outcome)")
            return
        }
        #expect(outcome != .invalid)
        #expect(outcome.message.contains("conexión"))
    }

    @Test("a gateway rejection never reads as a wrong key")
    func gatewayRejection() async {
        // What a build with no anon key actually gets back from Supabase.
        let outcome = await client(status: 401, json: #"{"message":"No API key found in request"}"#)
            .activate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac")
        #expect(outcome == .rejected(status: 401))
        #expect(outcome != .invalid)
        #expect(outcome.message.contains("No es tu clave"))

        let notFound = await client(status: 404, json: #"{"error":"not found"}"#)
            .activate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac")
        #expect(notFound == .rejected(status: 404))
    }

    @Test("garbage from the server is a retry, not a rejection")
    func garbage() async {
        let outcome = await client(json: "<html>502</html>")
            .activate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D", deviceName: "Mac")
        #expect(outcome == .serverError)   // HTTP 200 with a broken body: worth retrying
    }

    @Test("deactivation reports ok, and anything else is a failure")
    func deactivate() async {
        let freed = await client(json: #"{"ok":true}"#)
            .deactivate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D")
        #expect(freed)

        let refused = await client(json: #"{"ok":false,"error":"invalid_license"}"#)
            .deactivate(email: "a@b.com", key: "BELN-A1B2-C3D4-E5F6", deviceID: "D")
        #expect(!refused)
    }

    @Test("the function name is concatenated onto the prefix, never appended as a path")
    func urlShape() {
        let real = LicenseClient(baseURL: LicenseClient.productionBaseURL, anonKey: "k")
        #expect(real.url(for: "validate-license").absoluteString ==
            "https://supabase.believe-global.com/functions/v1/belauncher_landing_44aa9b_validate-license")
        #expect(real.url(for: "deactivate-device").absoluteString ==
            "https://supabase.believe-global.com/functions/v1/belauncher_landing_44aa9b_deactivate-device")
        // The bug this replaces: a slash turned the prefix into a folder and the Edge runtime
        // answered 500 "could not find an appropriate entrypoint".
        #expect(!real.url(for: "validate-license").absoluteString.contains("_/"))
    }

    @Test("the request carries the anon key and normalised fields")
    func requestShape() async {
        actor Capture {
            var body: [String: String] = [:]
            var headers: [String: String] = [:]
            func store(_ b: [String: String], _ h: [String: String]) { body = b; headers = h }
        }
        let capture = Capture()
        let probe = LicenseClient(baseURL: URL(string: "https://example.com/f_")!, anonKey: "ANON123") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
            await capture.store(body, request.allHTTPHeaderFields ?? [:])
            return (Data(#"{"valid":false}"#.utf8), URLResponse())
        }
        _ = await probe.activate(
            email: "  Jorge@Believe.com ", key: " beln-a1b2-c3d4-e5f6 ",
            deviceID: "UUID-X", deviceName: "MacBook de Jorge"
        )
        let body = await capture.body
        let headers = await capture.headers
        #expect(body["email"] == "jorge@believe.com")
        #expect(body["key"] == "BELN-A1B2-C3D4-E5F6")
        #expect(body["device_id"] == "UUID-X")
        #expect(body["device_name"] == "MacBook de Jorge")
        #expect(headers["apikey"] == "ANON123")
        #expect(headers["Authorization"] == "Bearer ANON123")
    }
}
