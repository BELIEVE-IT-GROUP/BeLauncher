import AVFoundation
import AVFAudio
import Testing
@testable import BeLauncher

@Suite("Permission state shown to the person")
@MainActor
struct PermissionHealthTests {
    @Test("a granted microphone callback stays checked while TCC catches up")
    func grantedCallbackIsAuthoritative() async {
        let health = CapabilityHealth(
            microphoneGranted: { false },
            requestMicrophone: { true }
        )
        #expect(health.microphone == .needsPermission)

        #expect(await health.requestMicrophone())
        #expect(health.microphone == .ready)
    }

    @Test("the recorder authority maps a granted TCC decision to ready")
    func grantedAudioIsReady() {
        #expect(Permissions.microphoneStatus(for: .granted) == .authorized)
    }

    @Test("undetermined and denied recorder decisions never paint ready")
    func nonGrantsAreNotReady() {
        #expect(Permissions.microphoneStatus(for: .undetermined) == .notDetermined)
        #expect(Permissions.microphoneStatus(for: .denied) == .denied)
    }
}
