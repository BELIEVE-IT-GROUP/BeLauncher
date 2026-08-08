import AppKit

/// The UI's single, live answer to "will this capability work right now?".
///
/// Permission APIs are intentionally kept here instead of being inferred from a preference or
/// from the last button click. TCC decisions can change in System Settings while the app remains
/// open, and a stale green check is worse than an honest orange one.
@MainActor
@Observable
final class CapabilityHealth {
    enum State: Equatable {
        case unknown
        case ready
        case needsPermission
        case unavailable

        var isReady: Bool { self == .ready }
    }

    private(set) var microphone: State = .unknown
    private(set) var screenRecording: State = .unknown
    private(set) var accessibility: State = .unknown
    private(set) var automation: State = .unknown
    private(set) var fullDiskAccess: State = .unknown

    private let microphoneGrantedCheck: @MainActor () -> Bool
    private let microphoneRequest: @MainActor () async -> Bool

    init(
        microphoneGranted: @escaping @MainActor () -> Bool = { Permissions.microphoneGranted },
        requestMicrophone: @escaping @MainActor () async -> Bool = {
            await Permissions.requestMicrophone()
        }
    ) {
        microphoneGrantedCheck = microphoneGranted
        microphoneRequest = requestMicrophone
        refresh()
    }

    func refresh() {
        microphone = microphoneGrantedCheck() ? .ready : .needsPermission
        screenRecording = ScreenCapture.screenRecordingGranted ? .ready : .needsPermission
        accessibility = Permissions.accessibilityGranted ? .ready : .needsPermission
        automation = Permissions.automationGranted() ? .ready : .needsPermission
        fullDiskAccess = Permissions.fullDiskAccessLikely ? .ready : .needsPermission
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        let granted = await microphoneRequest()
        microphone = granted ? .ready : .needsPermission
        return granted
    }

    func requestScreenRecording() {
        ScreenCapture.requestScreenRecording()
        refresh()
    }

    func requestAutomation() {
        if !Permissions.automationGranted(askUserIfNeeded: true) {
            Permissions.openAutomationSettings()
        }
        refresh()
    }

    func openFullDiskAccessSettings() {
        Permissions.openFullDiskAccessSettings()
    }

    @discardableResult
    func requestAccessibility(reason: String) -> Bool {
        let granted = Permissions.requestAccessibility(reason: reason)
        refresh()
        return granted
    }
}
