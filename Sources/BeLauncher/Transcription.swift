import Foundation
import AVFoundation
import Speech
import BeLauncherCore

/// Turning recordings into words, using only what is already on the Mac.
///
/// Everything here was measured on the target machine before a line of it was designed, because the
/// obvious assumption was wrong twice. What the probe found, on macOS 26.6:
///
/// - **`SpeechAnalyzer` + `SpeechTranscriber` work, fully on device.** No network, no authorization
///   prompt of any kind, and about 17 to 35 times faster than real time: nine seconds of audio came
///   back in 0.26 to 0.51 seconds. Spanish and English both transcribed cleanly.
/// - **`SFSpeechRecognizer` is not a fallback.** `requestAuthorization` never calls back at all
///   outside a full app bundle with a usage description, and it reports
///   `supportsOnDeviceRecognition == false` for `es-ES` on this Mac even though the newer API
///   handles that locale perfectly. Keeping it as a "safety net" would have meant a net that either
///   hangs forever or quietly sends audio to Apple's servers, which is the one thing this app
///   promises not to do. So there is no fallback: either the modern path runs on device or nothing
///   runs.
/// - **The asset APIs cannot be trusted as a readiness check.** `installedLocales` listed `es-ES`
///   when its model was absent, and `assetInstallationRequest(supporting:)` returned a non-nil
///   request for `en-US` at the same moment `en-US` was transcribing a sentence word for word.
///   Gating on either would refuse to work on a machine where it works. So it is used as a hint to
///   offer a download, never as a condition for trying.
///
/// One more measured trap, which cost the most time: when the model is genuinely missing the API
/// does not fail. It returns confident garbage — a Spanish sentence came back as "Astumost very
/// fork CL modedelow" — which is the worst possible behaviour for a memory product, because that
/// garbage is indistinguishable from a real transcript once it is in the index. That is why
/// `selfTest` exists.
enum Transcription {

    /// Whether this Mac is new enough at all. Everything below is gated on it.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Said plainly for the settings screen, since "no disponible" invites a support ticket.
    static var unsupportedReason: String {
        "La transcripción en local necesita macOS 26 o posterior. En esta versión de macOS no hay "
        + "un modelo de voz que funcione sin enviar el audio fuera del Mac, así que no se activa."
    }

    // MARK: - Which language

    /// The locale to transcribe in.
    ///
    /// `chosen` wins when it is set, and it exists because guessing is measurably wrong. The system
    /// language is not the spoken one: this Mac reports `["en-US", "es-419"]`, so a Spanish
    /// conversation was transcribed by the English model and came back as "El modelo de vos funciona
    /// cinconneciona internet" — close enough to look like a real transcript and wrong enough to
    /// poison anything built on it. Anybody working in one language on a machine set up in another
    /// hits this, which is most of the intended audience.
    ///
    /// The regional fallback is sorted before it is searched. `supportedLocales` is a `Set`, and
    /// `es-419` matches none of `es-CL`, `es-ES`, `es-US`, `es-MX` exactly — so picking "the first
    /// Spanish one" out of an unordered collection chose a different accent on different runs, and
    /// transcription quality wobbled for no visible reason.
    @available(macOS 26.0, *)
    static func preferredLocale(chosen: String? = nil) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        guard !supported.isEmpty else { return nil }
        let ordered = supported.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }

        var wanted: [Locale] = []
        if let chosen, !chosen.isEmpty { wanted.append(Locale(identifier: chosen)) }
        wanted += Locale.preferredLanguages.map { Locale(identifier: $0) }

        for locale in wanted {
            if let exact = ordered.first(where: {
                $0.identifier(.bcp47) == locale.identifier(.bcp47)
            }) { return exact }
        }
        for locale in wanted {
            guard let code = locale.language.languageCode?.identifier else { continue }
            if let near = ordered.first(where: {
                $0.language.languageCode?.identifier == code
            }) { return near }
        }
        return nil
    }

    /// Every language that can be transcribed on this Mac, for the settings screen to offer.
    @available(macOS 26.0, *)
    static func availableLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
            .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
    }

    // MARK: - Is the model really there

    /// Whether the model for a locale still has something to download.
    ///
    /// A hint, not a gate. Measured to report `true` for a locale that transcribes perfectly, so it
    /// is only ever used to decide whether offering a download is worth the person's attention.
    @available(macOS 26.0, *)
    static func suggestsDownload(_ locale: Locale) async -> Bool {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])
        let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        return request != nil
    }

    /// Downloads the language model, and only ever from an explicit choice.
    ///
    /// This is the single call in the whole file that touches the network, so it is never made on
    /// the app's own initiative. It reaches Apple's asset servers, not ours, and it is the same
    /// download System Settings would do — but the person still gets to be the one who starts it.
    @available(macOS 26.0, *)
    static func installModel(for locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        else { return }
        try await request.downloadAndInstall()
    }

    /// Proves the model works before anything it produces is believed.
    ///
    /// The failure this defends against is not a crash, it is a lie: with the model absent the
    /// transcriber returns fluent nonsense at full speed and nothing in the API says so. Storing
    /// that would poison the brain permanently and invisibly, and no later pass could tell a bad
    /// transcript from a good one.
    ///
    /// So a known sentence is spoken by the system voice, transcribed, and compared against itself.
    /// Entirely local, about a second, and it produced a clean separation when measured: with the
    /// model present the score was 1.0, with it missing the same check scored around 0.3.
    @available(macOS 26.0, *)
    static func selfTest(locale: Locale) async -> Double {
        let phrase = locale.language.languageCode?.identifier == "en"
            ? "the voice model works without an internet connection"
            : "el modelo de voz funciona sin conexion a internet"

        guard let audio = await speak(phrase, locale: locale) else { return 0 }
        defer { try? FileManager.default.removeItem(at: audio) }
        guard let heard = try? await run(fileAt: audio, locale: locale) else { return 0 }

        return agreement(spoken: phrase, heard: heard)
    }

    /// How much of a known sentence came back, from 0 to 1.
    ///
    /// Split out from `selfTest` because the decision it feeds is the one that keeps invented text
    /// out of the index, and the rest of `selfTest` needs a voice, a model and a second of audio —
    /// none of which a test can have. This half is arithmetic on two strings and can be checked
    /// against the exact garbage the probe measured.
    static func agreement(spoken: String, heard: String) -> Double {
        let wanted = words(spoken), got = words(heard)
        guard !wanted.isEmpty else { return 0 }
        return Double(wanted.intersection(got).count) / Double(wanted.count)
    }

    /// Whether a self-test score is good enough to believe what the model says next.
    static func isTrustworthy(_ score: Double) -> Bool { score >= trustBar }

    /// Below this the model is not to be trusted and nothing it produces is stored.
    ///
    /// Set from the measured gap: a working model scored 1.0 and a missing one about 0.3, so the
    /// bar sits well clear of both. A synthesised voice is not a person, so perfection is not
    /// required — only the difference between transcribing and hallucinating.
    static let trustBar: Double = 0.7

    static func words(_ text: String) -> Set<String> {
        Set(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 })
    }

    /// Writes a spoken phrase to a file, in process and offline.
    @available(macOS 26.0, *)
    static func speak(_ phrase: String, locale: Locale) async -> URL? {
        let synthesiser = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier(.bcp47))

        var buffers: [AVAudioPCMBuffer] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            synthesiser.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // A zero-length buffer is how the synthesiser signals the end.
                if pcm.frameLength == 0 {
                    if !resumed { resumed = true; continuation.resume() }
                    return
                }
                buffers.append(pcm)
            }
        }
        guard let first = buffers.first else { return nil }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belauncher-selftest-\(UUID().uuidString).caf")
        guard let file = try? AVAudioFile(forWriting: url, settings: first.format.settings)
        else { return nil }
        for buffer in buffers where (try? file.write(from: buffer)) == nil { return nil }
        return url
    }

    // MARK: - Transcribing

    enum Failure: LocalizedError {
        case tooOld
        case noLanguage
        case untrustworthy(Double)
        case empty

        var errorDescription: String? {
            switch self {
            case .tooOld: Transcription.unsupportedReason
            case .noLanguage:
                "No hay un modelo de voz para tu idioma en este Mac."
            case .untrustworthy:
                "El modelo de voz está instalado a medias y devuelve texto inventado, así que no "
                + "se guarda nada. Descarga el idioma desde Ajustes para arreglarlo."
            case .empty: "No se entendió nada en ese audio."
            }
        }
    }

    /// Transcribes one recording, after proving the model is honest.
    static func transcribe(fileAt url: URL, title: String? = nil, spokenLanguage: String? = nil,
                           verify: Bool = true) async throws -> Transcript {
        guard #available(macOS 26.0, *) else { throw Failure.tooOld }
        guard let locale = await preferredLocale(chosen: spokenLanguage) else {
            throw Failure.noLanguage
        }

        if verify {
            let score = await selfTest(locale: locale)
            guard isTrustworthy(score) else { throw Failure.untrustworthy(score) }
        }

        let text = try await run(fileAt: url, locale: locale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }

        let recorded = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate]
            as? Date ?? Date()
        return Transcript(at: recorded,
                          title: title ?? url.deletingPathExtension().lastPathComponent,
                          text: text, sourcePath: url.path)
    }

    /// The transcription itself.
    ///
    /// `analyzeSequence(from:)` over a file, deliberately, rather than the streaming
    /// `start(inputSequence:)` path: the streaming path was measured returning `nilError`
    /// immediately in one arrangement and hanging forever in another, while the file path completed
    /// every time. A hang inside a nightly background pass is invisible until somebody notices the
    /// brain stopped learning.
    @available(macOS 26.0, *)
    static func run(fileAt url: URL, locale: Locale) async throws -> String {
        // A reservation is required and the number available is finite — once exhausted, `reserve`
        // returns false and every later locale silently fails. It is released the moment the file
        // is done, whatever happened.
        // Releasing is itself async, so it cannot go in a `defer`; both exits do it by hand
        // instead. Leaking one on the error path is what eventually exhausts the pool.
        let reserved = (try? await AssetInventory.reserve(locale: locale)) ?? false
        func release() async {
            if reserved { await AssetInventory.release(reservedLocale: locale) }
        }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            let file = try AVAudioFile(forReading: url)

            // Results are drained on their own task: the sequence only finishes once the analyzer
            // has been finalised, so collecting after the fact would deadlock against it.
            let collector = Task {
                var text = ""
                for try await result in transcriber.results {
                    text += String(result.text.characters)
                }
                return text
            }

            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let text = try await collector.value
            await release()
            return text
        } catch {
            await release()
            throw error
        }
    }
}
