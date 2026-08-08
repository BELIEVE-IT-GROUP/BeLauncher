@preconcurrency import AVFoundation
import AppKit
import BeLauncherCore

/// A post-call recorder. Mic and system output are deliberately separate files so the resulting
/// evidence can say which side said what without pretending a diarization model is certain.
@MainActor
final class CallCaptureController: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording(started: Date), transcribing }

    private let notify: (String) -> Void
    private let onCompleted: (String, String) -> Void
    private let onSaved: () -> Void
    private let system = SystemAudioCapture()
    private let detector = CallAppDetector()
    var source: CallAudioSource
    var onSuggestionChange: () -> Void = {}
    private var microphone: AVAudioRecorder?
    private var micURL: URL?
    private var systemURL: URL?
    private(set) var state: State = .idle

    init(notify: @escaping (String) -> Void,
         onCompleted: @escaping (String, String) -> Void = { _, _ in },
        onSaved: @escaping () -> Void = {},
         source: CallAudioSource = .automatic) {
        self.notify = notify; self.onCompleted = onCompleted; self.onSaved = onSaved
        self.source = source
        super.init()
        detector.onUpdate = { [weak self] in self?.onSuggestionChange() }
        detector.start()
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var suggestedAppName: String? { detector.suggestedAppName }
    var suggestedSource: CallAudioSource? { detector.suggestedSource }
    var likelyInCall: Bool { detector.likelyInCall }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await Permissions.requestMicrophone() else {
                notify(L("Microphone permission is needed for a call recording.")); return
            }
            QwenASRInstaller.shared.prepareInBackground()
            guard SystemAudioCapture.permissionGranted else {
                SystemAudioCapture.requestPermission()
                notify(L("Screen Recording permission is needed for call audio.")); return
            }
            do {
                detector.refresh()
                let selectedSource = source == .automatic
                    ? (detector.likelyInCall ? (detector.suggestedSource ?? .system) : .system)
                    : source
                let folder = Vault.recordingsRoot()
                    .appendingPathComponent("call-\(Int(Date().timeIntervalSince1970))")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let mic = folder.appendingPathComponent("microphone.m4a")
                let system = folder.appendingPathComponent("system.caf")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: mic, settings: settings)
                recorder.delegate = self
                recorder.prepareToRecord()
                try await self.system.start(to: system, source: selectedSource)
                guard recorder.record() else { throw Failure.couldNotStart }
                microphone = recorder; micURL = mic; systemURL = system
                state = .recording(started: .now)
                let appName = detector.suggestedAppName
                notify(appName.map { L("Recording call in %@", $0) } ?? L("Recording call"))
            } catch {
                await self.system.stop()
                notify(L("Call recording could not start: %@", error.localizedDescription))
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        microphone?.stop()
        Task { await system.stop() }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finish(successfully: flag) }
    }

    private func finish(successfully flag: Bool) {
        let mic = micURL, output = systemURL
        microphone = nil; micURL = nil; systemURL = nil
        guard flag, let mic, let output else { state = .idle; notify(L("Call recording was not saved.")); return }
        state = .transcribing
        notify(L("Transcribing call"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await self.system.stop()
                async let yours = Self.transcribe(url: mic, title: "You")
                async let theirs = Self.transcribe(url: output, title: "Other participants")
                let body = "Audio (microphone): \(mic.path)\nAudio (system): \(output.path)\n\nYou:\n\(try await yours)\n\nOther participants:\n\(try await theirs)"
                let title = "Call \(Date().formatted(.iso8601))"
                let vault = try Vault(root: Vault.defaultRoot())
                _ = try vault.saveEvidence(title: title, text: body, sourcePath: mic.path)
                onSaved()
                onCompleted(title, body)
                state = .idle; notify(L("Call saved in your Brain"))
            } catch {
                let title = L("Call awaiting transcription")
                let detail = "Audio (microphone): \(mic.path)\nAudio (system): \(output.path)\n\n" +
                    L("Transcription failed: %@", error.localizedDescription)
                if let vault = try? Vault(root: Vault.defaultRoot()) {
                    _ = try? vault.saveEvidence(title: title, text: detail, sourcePath: mic.path)
                    onSaved()
                }
                state = .idle; notify(L("Call could not be transcribed: %@", error.localizedDescription))
            }
        }
    }

    private static func transcribe(url: URL, title: String) async throws -> String {
        try await VoiceProvider.transcribe(fileAt: url, title: title).text
    }

    private enum Failure: LocalizedError {
        case couldNotStart
        var errorDescription: String? { L("The call microphone did not start recording.") }
    }
}
