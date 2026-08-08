import Foundation
import BeLauncherCore

/// One transcription decision for every audio surface in the app.
/// Qwen is attempted first for a fully local, high-quality result; Apple's on-device
/// SpeechAnalyzer is the fallback when Qwen is not installed or cannot handle the file.
enum VoiceProvider {
    enum Kind: String, Sendable, Equatable {
        case qwen, appleSpeech
    }

    static func providerOrder(qwenReady: Bool) -> [Kind] {
        qwenReady ? [.qwen, .appleSpeech] : [.appleSpeech]
    }

    static func transcribe(fileAt url: URL, title: String,
                           spokenLanguage: String? = nil) async throws -> Transcript {
        var failures: [String] = []
        for provider in providerOrder(qwenReady: QwenASRRuntime.isReady) {
            do {
                switch provider {
                case .qwen:
                    let text = try await QwenASRRuntime.transcribe(
                        fileAt: url, model: QwenASRInstaller.smallModel)
                    let recorded = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate]
                        as? Date ?? .now
                    return Transcript(at: recorded, title: title, text: text,
                                      sourcePath: url.path)
                case .appleSpeech:
                    return try await Transcription.transcribe(
                        fileAt: url, title: title, spokenLanguage: spokenLanguage)
                }
            } catch {
                failures.append("\(provider.rawValue): \(error.localizedDescription)")
            }
        }
        throw Failure.allProviders(failures)
    }

    enum Failure: LocalizedError, Equatable {
        case allProviders([String])

        var errorDescription: String? {
            switch self {
            case .allProviders(let failures):
                L("No local transcription provider could read this audio. %@",
                  failures.joined(separator: " · "))
            }
        }
    }
}
