import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import BeLauncher

/// La autoprueba que decide si creerle al modelo de voz.
///
/// El fallo del que defiende no es una caída, es una mentira: con el modelo a medias el
/// transcriptor devuelve una frase fluida e inventada, a toda velocidad, y ninguna API dice que
/// pasó. Ese texto entra al índice indistinguible de uno bueno.
///
/// Aquí no hay micrófono ni modelo: se prueba la aritmética que decide, con las dos frases que
/// midió la sonda en este Mac — la buena, que puntuó 1,0, y la basura real que puntuó ~0,3.
@Suite("La autoprueba de la transcripción")
struct TranscriptionTests {
    @Test("Qwen disk check works before its support directory exists")
    func qwenReadsFreeDiskSpaceForCleanInstall() {
        let missingInstallRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: missingInstallRoot.path))

        let freeBytes = QwenASRInstaller.freeDiskSpace(at: missingInstallRoot.path)
        #expect(freeBytes != nil)
        #expect(freeBytes ?? 0 > 0)
    }

    @Test("Qwen creates the venv root, not a nested bin/bin environment")
    func qwenVenvDestination() {
        let root = URL(fileURLWithPath: "/tmp/BeLauncher/ASR", isDirectory: true)
        #expect(QwenASRInstaller.venvRoot(at: root).path == "/tmp/BeLauncher/ASR/.venv")
    }

    @Test("Qwen repairs the bin/bin environment created by 0.32.16")
    func repairsLegacyNestedVenv() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nestedPython = root.appendingPathComponent(".venv/bin/bin/python3")
        try FileManager.default.createDirectory(at: nestedPython.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nestedPython.path, contents: Data())

        #expect(try QwenASRInstaller.repairLegacyVenv(at: root))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".venv").path))
    }

    @Test("Qwen removes a partial venv before recreating it")
    func repairsPartialVenv() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent(".venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        #expect(try QwenASRInstaller.removeInvalidVenv(at: root))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv").path))
    }

    @Test("Qwen keeps Python and Hugging Face caches inside app support")
    func qwenRuntimeIsIsolated() {
        let root = URL(fileURLWithPath: "/tmp/BeLauncher/ASR", isDirectory: true)
        let environment = QwenASRInstaller.installEnvironment(root: root)
        #expect(environment["UV_PYTHON_INSTALL_DIR"] == "/tmp/BeLauncher/ASR/python")
        #expect(environment["UV_NO_MODIFY_PATH"] == "1")
        #expect(environment["HF_HOME"] == "/tmp/BeLauncher/ASR/.cache/huggingface")
        #expect(QwenASRInstaller.runtimeEnvironment(root: root)["HF_HOME"]
                == "/tmp/BeLauncher/ASR/.cache/huggingface")
        #expect(QwenASRInstaller.modelDownloadScript.contains("snapshot_download"))
        #expect(!QwenASRInstaller.modelDownloadScript.contains("from_pretrained"))
    }

    @Test("Qwen progress output never becomes a voice transcription")
    func qwenDropsProgressLines() {
        let output = "Fetching 11 files: 100%|##########| 11/11 [00:00<00:00, 4242.12it/s]\nHola, esta es la nota"
        #expect(QwenASRRuntime.transcriptText(from: output) == "Hola, esta es la nota")
        #expect(QwenASRRuntime.transcriptText(from: "Fetching 11 files: 100%|##########|").isEmpty)
    }

    @Test("Qwen convierte los contenedores de macOS a WAV antes de invocar Python")
    func qwenNormalizesMacAudio() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: source) }
        let format: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: source, settings: format)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: 1_600))
        buffer.frameLength = 1_600
        try file.write(from: buffer)

        let normalized = try QwenASRRuntime.normalizedAudioURL(for: source)
        defer { try? FileManager.default.removeItem(at: normalized) }
        #expect(normalized.pathExtension == "wav")
        #expect(normalized != source)
        #expect(FileManager.default.fileExists(atPath: normalized.path))
        #expect(try AVAudioFile(forReading: normalized).length == 1_600)
    }


    private let spanish = "el modelo de voz funciona sin conexion a internet"
    /// Lo que devolvió de verdad el transcriptor con el modelo ausente.
    private let garbage = "Astumost very fork CL modedelow"

    @Test("una transcripción inventada no llega al umbral y se rechaza")
    func laBasuraSeRechaza() {
        let score = Transcription.agreement(spoken: spanish, heard: garbage)

        #expect(score < Transcription.trustBar)
        #expect(!Transcription.isTrustworthy(score))
    }

    @Test("una transcripción fiel se acepta")
    func loFielSeAcepta() {
        let score = Transcription.agreement(spoken: spanish, heard: spanish)

        #expect(score == 1)
        #expect(Transcription.isTrustworthy(score))
    }

    @Test("acentos y mayúsculas no cuentan como errores del modelo")
    func losAcentosNoCuentan() {
        let heard = "El Modelo de Voz funciona sin conexión a Internet."

        #expect(Transcription.agreement(spoken: spanish, heard: heard) == 1)
    }

    @Test("una transcripción a medias tampoco pasa el umbral")
    func aMediasTampocoPasa() {
        // La mitad de las palabras largas de la frase. Un modelo que se come media frase es tan
        // inservible como uno que inventa: lo que se guarde sale mal citado para siempre.
        let heard = "el modelo de voz y poco mas"

        let score = Transcription.agreement(spoken: spanish, heard: heard)
        #expect(score < Transcription.trustBar)
    }

    @Test("el silencio puntúa cero, no uno por no contradecir nada")
    func elSilencioPuntuaCero() {
        #expect(Transcription.agreement(spoken: spanish, heard: "") == 0)
        #expect(!Transcription.isTrustworthy(0))
    }

    @Test("sin frase que comparar no se aprueba nada")
    func sinFraseNoSeApruebaNada() {
        // Si esto devolviera 1 —cero de cero— una locale sin frase conocida se daría por buena y
        // la autoprueba dejaría de ser una puerta.
        #expect(Transcription.agreement(spoken: "", heard: "lo que sea") == 0)
    }

    @Test("el umbral queda por encima de lo que puntúa un modelo ausente")
    func elUmbralSeparaLosDosCasos() {
        // La sonda midió 1,0 con el modelo puesto y ~0,3 sin él. El umbral tiene que quedar en
        // medio con holgura, o el arreglo entero deja de servir.
        #expect(Transcription.trustBar > 0.4)
        #expect(Transcription.trustBar < 1)
    }

    @Test("el motivo del rechazo dice qué hacer, no solo que falló")
    func elRechazoDiceQueHacer() {
        let said = Transcription.Failure.untrustworthy(0.3).errorDescription ?? ""

        #expect(said.contains("no"))
        #expect(said.contains("Settings"))
        // Lo importante: dice que NO se guarda nada. Un error que no aclare eso deja a alguien
        // creyendo que la reunión quedó transcrita.
        #expect(said.contains("nothing is kept"))
    }

    @Test("las palabras cortas no inflan la puntuación")
    func lasPalabrasCortasNoCuentan() {
        // "de", "el", "la", "a" no distinguen una transcripción buena de una inventada: cualquier
        // castellano las tiene. Si contaran, la basura medida subiría hacia el umbral.
        #expect(Transcription.words("de a el la un").isEmpty)
        #expect(Transcription.words("modelo voz internet").count == 3)
    }

    @Test("el aviso de macOS viejo se explica sin jerga")
    func elAvisoDeMacOSViejo() {
        #expect(Transcription.unsupportedReason.contains("macOS 26"))
        #expect(Transcription.unsupportedReason.contains("without sending the audio off the Mac"))
    }
}

@Suite("Voice provider routing")
struct VoiceProviderTests {
    @Test("the native fallback remains available without Qwen")
    func fallbackOrder() {
        #expect(VoiceProvider.providerOrder(qwenReady: false) == [.appleSpeech])
        #expect(VoiceProvider.providerOrder(qwenReady: true) == [.qwen, .appleSpeech])
    }

    @Test("provider failure remains actionable and local")
    func failureIsReadable() {
        let error = VoiceProvider.Failure.allProviders(["qwen: unavailable", "speech: no model"])
        #expect(error.localizedDescription.contains("No local transcription provider"))
    }
}

@Suite("Qwen install diagnostics")
struct QwenInstallDiagnosticsTests {
    @Test("exit 2 keeps the actionable subprocess detail")
    func exitTwoIsNotJustACode() {
        let message = QwenASRInstaller.userFacingMessage(
            step: "download the model", code: 2,
            stderr: "RuntimeError: model files are incomplete")

        #expect(message.contains("Retry"))
        #expect(message.contains("model files are incomplete"))
        #expect(!message.contains("error 2"))
    }

    @Test("long subprocess output is bounded")
    func outputIsBounded() {
        let detail = String(repeating: "x", count: 4_000)
        let message = QwenASRInstaller.userFacingMessage(step: "prepare Python", code: 1,
                                                          stderr: detail)
        #expect(message.count < 1_100)
        #expect(message.hasSuffix(String(repeating: "x", count: 900)))
    }

    @Test("detecta el snapshot real del modelo pequeño aunque falte el marcador")
    func detectsSmallModelFromHuggingFaceCache() throws {
        let fixture = try QwenFixture(model: QwenASRInstaller.smallModel)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makePythonAndEngine()
        try fixture.makeSnapshot()

        let state = QwenASRInstaller.inspect(root: fixture.root,
                                              model: fixture.model,
                                              modelCacheRoots: [fixture.cache])
        #expect(state == .init(pythonPresent: true, enginePresent: true, modelPresent: true))
    }

    @Test("el modelo grande se detecta de forma independiente del pequeño")
    func detectsLargeModelIndependently() throws {
        let fixture = try QwenFixture(model: QwenASRInstaller.largeModel)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makePythonAndEngine()
        try fixture.makeSnapshot()

        let large = QwenASRInstaller.inspect(root: fixture.root, model: QwenASRInstaller.largeModel,
                                              modelCacheRoots: [fixture.cache])
        let small = QwenASRInstaller.inspect(root: fixture.root, model: QwenASRInstaller.smallModel,
                                              modelCacheRoots: [fixture.cache])
        #expect(large.isReady)
        #expect(!small.modelPresent)
    }

    @Test("el runtime usa exactamente el modelo seleccionado")
    func selectedModelControlsRuntime() throws {
        let small = try QwenFixture(model: QwenASRInstaller.smallModel)
        defer { try? FileManager.default.removeItem(at: small.root) }
        try small.makePythonAndEngine()
        try small.makeSnapshot()

        #expect(QwenASRRuntime.readyModel(
            at: small.root,
            selectedModel: QwenASRInstaller.smallModel,
            modelCacheRoots: [small.cache]
        ) == QwenASRInstaller.smallModel)
        #expect(QwenASRRuntime.readyModel(
            at: small.root,
            selectedModel: QwenASRInstaller.largeModel,
            modelCacheRoots: [small.cache]
        ) == nil, "no debe usar 0.6B a escondidas cuando la persona eligió 1.7B")
    }

    @Test("una descarga interrumpida es reanudable y no se reporta como lista")
    func interruptedInstallIsResumable() throws {
        let fixture = try QwenFixture(model: QwenASRInstaller.smallModel)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makePythonOnly()
        let state = QwenASRInstaller.inspect(root: fixture.root, model: fixture.model,
                                              modelCacheRoots: [fixture.cache])
        #expect(!state.isReady)
        #expect(state.canResume)
        #expect(!state.modelPresent)
    }

    @Test("un marcador viejo o un snapshot sin pesos no pueden fingir que está listo")
    func markerAndIncompleteSnapshotAreRejected() throws {
        let fixture = try QwenFixture(model: QwenASRInstaller.smallModel)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makePythonAndEngine()
        try Data(fixture.model.utf8).write(to: QwenASRInstaller.modelMarker(for: fixture.model,
                                                                             root: fixture.root))
        try fixture.makeSnapshot(includeWeights: false)

        let state = QwenASRInstaller.inspect(root: fixture.root, model: fixture.model,
                                              modelCacheRoots: [fixture.cache])
        #expect(!state.isReady)
        #expect(!state.modelPresent)
    }

    @Test("un índice de pesos sin sus shards no cuenta como modelo descargado")
    func indexWithoutWeightShardsIsRejected() throws {
        let fixture = try QwenFixture(model: QwenASRInstaller.smallModel)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makePythonAndEngine()
        try fixture.makeSnapshotIndexWithoutWeights()

        let state = QwenASRInstaller.inspect(root: fixture.root, model: fixture.model,
                                              modelCacheRoots: [fixture.cache])
        #expect(!state.modelPresent)
        #expect(!state.isReady)
    }

    @Test("Hugging Face snapshots validate weights through their blob symlinks")
    func linkedWeightBlobIsAccepted() throws {
        let fixture = try QwenFixture(model: QwenASRInstaller.smallModel)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.makePythonAndEngine()
        try fixture.makeLinkedSnapshot()

        let state = QwenASRInstaller.inspect(root: fixture.root, model: fixture.model,
                                              modelCacheRoots: [fixture.cache])
        #expect(state.isReady)
    }

    @Test("archivos vacíos con nombres correctos no fingen un runtime instalado")
    func placeholderRuntimeIsRejected() throws {
        let fixture = try QwenFixture(model: QwenASRInstaller.smallModel)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let python = fixture.root.appendingPathComponent(".venv/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: python.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(
                ".venv/lib/python3.12/site-packages/qwen3_asr_mlx"),
            withIntermediateDirectories: true)

        let state = QwenASRInstaller.inspect(root: fixture.root, model: fixture.model,
                                              modelCacheRoots: [fixture.cache])
        #expect(!state.pythonPresent)
        #expect(!state.enginePresent)
    }

    private struct QwenFixture {
        let root: URL
        let cache: URL
        let model: String

        init(model: String) throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen-fixture-\(UUID().uuidString)")
            self.cache = root.appendingPathComponent("huggingface/hub")
            self.model = model
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func makePythonOnly() throws {
            let python = root.appendingPathComponent(".venv/bin/python3")
            try FileManager.default.createDirectory(at: python.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: python.path, contents: Data("python".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try Data("home = managed".utf8).write(
                to: root.appendingPathComponent(".venv/pyvenv.cfg"))
        }

        func makePythonAndEngine() throws {
            try makePythonOnly()
            let package = root.appendingPathComponent(".venv/lib/python3.12/site-packages/qwen3_asr_mlx")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("".utf8).write(to: package.appendingPathComponent("__init__.py"))
            try Data(QwenASRInstaller.engineVersion.utf8).write(
                to: QwenASRInstaller.engineMarker(at: root))
        }

        func makeSnapshot(includeWeights: Bool = true) throws {
            let cacheName = "models--" + model.replacingOccurrences(of: "/", with: "--")
            let snapshot = cache.appendingPathComponent("\(cacheName)/snapshots/test")
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
            if includeWeights {
                let weights = snapshot.appendingPathComponent("model.safetensors")
                FileManager.default.createFile(atPath: weights.path, contents: nil)
                let handle = try FileHandle(forWritingTo: weights)
                try handle.truncate(atOffset: 1_048_577)
                try handle.close()
            }
        }

        func makeLinkedSnapshot() throws {
            let cacheName = "models--" + model.replacingOccurrences(of: "/", with: "--")
            let modelRoot = cache.appendingPathComponent(cacheName)
            let snapshot = modelRoot.appendingPathComponent("snapshots/revision")
            let blobs = modelRoot.appendingPathComponent("blobs")
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
            let blob = blobs.appendingPathComponent("weight")
            FileManager.default.createFile(atPath: blob.path, contents: nil)
            let handle = try FileHandle(forWritingTo: blob)
            try handle.truncate(atOffset: 1_048_577)
            try handle.close()
            try FileManager.default.createSymbolicLink(
                atPath: snapshot.appendingPathComponent("model.safetensors").path,
                withDestinationPath: "../../blobs/weight")
        }

        func makeSnapshotIndexWithoutWeights() throws {
            let cacheName = "models--" + model.replacingOccurrences(of: "/", with: "--")
            let snapshot = cache.appendingPathComponent("\(cacheName)/snapshots/test")
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
            let index = #"{"weight_map":{"layer":"model-00001-of-00002.safetensors"}}"#
            try Data(index.utf8).write(to: snapshot.appendingPathComponent(
                "model.safetensors.index.json"))
        }
    }
}
