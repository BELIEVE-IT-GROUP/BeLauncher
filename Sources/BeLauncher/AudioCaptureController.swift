@preconcurrency import AVFoundation
import AppKit
import BeLauncherCore

/// Owns the background voice-session lifecycle. The launcher window is deliberately not involved:
/// a note can start and finish while another app is in front, and the same controller will later
/// grow a system-audio input for calls.
@MainActor
final class AudioCaptureController: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording(started: Date)
        case transcribing
    }

    private let notify: (String) -> Void
    private let onSaved: () -> Void
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var shouldPaste = false
    private(set) var state: State = .idle

    init(notify: @escaping (String) -> Void, onSaved: @escaping () -> Void = {}) {
        self.notify = notify
        self.onSaved = onSaved
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    static func pruneRecordings(olderThan age: TimeInterval = 30 * 24 * 60 * 60) {
        let folder = Vault.recordingsRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    func toggleVoiceNote() {
        if isRecording { stopVoiceNote() } else { startVoiceNote() }
    }

    func toggleDictation() {
        if isRecording { stopVoiceNote() } else { startRecording(shouldPaste: true) }
    }

    func startVoiceNote() {
        guard !isRecording else { return }
        startRecording(shouldPaste: false)
    }

    private func startRecording(shouldPaste: Bool) {
        guard !isRecording else { return }
        self.shouldPaste = shouldPaste
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await Permissions.requestMicrophone() else {
                notify(L("Microphone permission is needed for a voice note."))
                return
            }
            do {
                let folder = Vault.recordingsRoot()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder
                    .appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.delegate = self
                recorder.prepareToRecord()
                guard recorder.record() else { throw Failure.couldNotStart }
                self.recorder = recorder
                recordingURL = url
                state = .recording(started: .now)
                notify(L("Recording voice note"))
            } catch {
                notify(L("Voice note could not start: %@", error.localizedDescription))
            }
        }
    }

    func stopVoiceNote() {
        guard isRecording else { return }
        recorder?.stop()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.finishedRecording(successfully: flag)
        }
    }

    private func finishedRecording(successfully flag: Bool) {
        let url = recordingURL
        let paste = shouldPaste
        shouldPaste = false
        self.recorder = nil
        recordingURL = nil
        guard flag, let url else {
            state = .idle
            notify(L("Voice note was not saved."))
            return
        }
        state = .transcribing
        notify(L("Transcribing voice note"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let transcript = try await VoiceProvider.transcribe(fileAt: url, title: "Voice note")
                let vault = try Vault(root: Vault.defaultRoot())
                _ = try vault.saveEvidence(
                    title: transcript.title,
                    text: "Audio: \(url.path)\n\n\(transcript.text)",
                    at: transcript.at,
                    sourcePath: url.path)
                onSaved()
                if paste {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.text, forType: .string)
                    if Permissions.accessibilityGranted {
                        Permissions.pasteToFrontmostApp()
                    }
                }
                state = .idle
                notify(L("Voice note saved in your Brain"))
            } catch {
                let title = L("Voice note awaiting transcription")
                let detail = "Audio: \(url.path)\n\n" +
                    L("Transcription failed: %@", error.localizedDescription)
                if let vault = try? Vault(root: Vault.defaultRoot()) {
                    _ = try? vault.saveEvidence(title: title, text: detail, sourcePath: url.path)
                    onSaved()
                }
                state = .idle
                notify(L("Voice note saved, but transcription needs attention."))
            }
        }
    }

    private enum Failure: LocalizedError {
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .couldNotStart: L("The microphone did not start recording.")
            }
        }
    }
}
