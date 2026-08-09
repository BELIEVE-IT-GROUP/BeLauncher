@preconcurrency import AVFoundation
import AppKit
import Combine
import BeLauncherCore

/// Owns the background voice-session lifecycle. The launcher window is deliberately not involved:
/// a note can start and finish while another app is in front, and the same controller will later
/// grow a system-audio input for calls.
@MainActor
final class AudioCaptureController: NSObject, AVAudioRecorderDelegate, ObservableObject {
    enum State: Equatable {
        case idle
        case recording(started: Date)
        case transcribing
    }

    private let notify: (String) -> Void
    private let onSaved: () -> Void
    private let targetApplication: () -> NSRunningApplication?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var shouldPaste = false
    private var pasteTarget: NSRunningApplication?
    @Published private(set) var state: State = .idle
    @Published private(set) var message = ""

    var stateLabel: String {
        switch state {
        case .idle: L("Ready to capture")
        case .recording: L("Recording")
        case .transcribing: L("Transcribing")
        }
    }

    var recordingStartedAt: Date? {
        guard case .recording(let started) = state else { return nil }
        return started
    }

    init(notify: @escaping (String) -> Void, onSaved: @escaping () -> Void = {},
         targetApplication: @escaping () -> NSRunningApplication? = { nil }) {
        self.notify = notify
        self.onSaved = onSaved
        self.targetApplication = targetApplication
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
        pasteTarget = shouldPaste ? targetApplication() : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if shouldPaste && !Permissions.requestAccessibility(
                reason: L("Dictation needs permission to insert the transcription in the app you were using.")) {
                self.shouldPaste = false
                self.pasteTarget = nil
                self.announce(L("Dictation was not started because insertion permission is not granted."))
                return
            }
            guard await Permissions.requestMicrophone() else {
                self.shouldPaste = false
                self.pasteTarget = nil
                announce(L("Microphone permission is needed for a voice note."))
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
                announce(L("Recording voice note"))
            } catch {
                announce(L("Voice note could not start: %@", error.localizedDescription))
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
        let target = pasteTarget
        shouldPaste = false
        pasteTarget = nil
        self.recorder = nil
        recordingURL = nil
        guard flag, let url else {
            state = .idle
            announce(L("Voice note was not saved."))
            return
        }
        state = .transcribing
        announce(L("Transcribing voice note"))
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
                var inserted = false
                var insertionUnavailable = false
                if paste {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.text, forType: .string)
                    if let target, !target.isTerminated {
                        target.activate(options: [])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            Permissions.pasteToFrontmostApp()
                        }
                        inserted = true
                    } else {
                        insertionUnavailable = true
                    }
                }
                state = .idle
                announce(inserted ? L("Transcription inserted in the active app") :
                            insertionUnavailable ? L("Voice note saved, but dictation could not be inserted.") :
                            L("Voice note saved in your Brain"))
            } catch {
                let title = L("Voice note awaiting transcription")
                let detail = "Audio: \(url.path)\n\n" +
                    L("Transcription failed: %@", error.localizedDescription)
                if let vault = try? Vault(root: Vault.defaultRoot()) {
                    _ = try? vault.saveEvidence(title: title, text: detail, sourcePath: url.path)
                    onSaved()
                }
                state = .idle
                announce(L("Voice note saved, but transcription needs attention."))
            }
        }
    }

    private func announce(_ text: String) {
        message = text
        notify(text)
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
