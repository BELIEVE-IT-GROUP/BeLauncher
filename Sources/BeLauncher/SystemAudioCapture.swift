@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import BeLauncherCore

private struct SampleBufferBox: @unchecked Sendable {
    let value: CMSampleBuffer
}

/// Captures the Mac's output mix through ScreenCaptureKit. It intentionally writes a separate file
/// from the microphone: keeping channels separate makes call transcripts auditable and avoids a
/// diarization model guessing which voice was the owner of the Mac.
@MainActor
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var destination: URL?
    private var failed: Error?

    static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    func start(to url: URL, source: CallAudioSource = .system) async throws {
        guard Self.permissionGranted else { throw Failure.permission }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw Failure.noDisplay }

        let filter: SCContentFilter
        if source != .system,
           let application = content.applications.first(where: {
               source == .automatic
                   ? false
                   : source.bundleIdentifiers.contains($0.bundleIdentifier)
           }) {
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 5
        configuration.width = 2
        configuration.height = 2

        destination = url
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "com.belauncher.system-audio"))
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        file = nil
        destination = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let box = SampleBufferBox(value: sampleBuffer)
        Task { @MainActor [weak self] in
            self?.append(box.value)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.failed = error
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard let description = sampleBuffer.formatDescription,
              let destination else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: destination, settings: format.settings)
            }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            try file?.write(from: buffer)
        } catch {
            failed = error
        }
    }

    private enum Failure: LocalizedError {
        case permission, noDisplay
        var errorDescription: String? {
            switch self {
            case .permission: L("Screen Recording permission is needed for call audio.")
            case .noDisplay: L("There is no display available for system audio capture.")
            }
        }
    }
}
