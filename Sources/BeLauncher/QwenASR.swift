import Foundation
import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import BeLauncherCore

/// Owns the optional MLX runtime outside BeLauncher's process. The launcher must remain a small
/// menu-bar agent even when a 1.7B model is loaded, so all Python and model memory live here.
@MainActor
@Observable
final class QwenASRInstaller {
    enum Phase: Equatable {
        case unknown
        case unavailable
        case pythonMissing
        case notInstalled
        case installing
        case ready(model: String)
        case failed(String)
    }

    nonisolated static let smallModel = "mlx-community/Qwen3-ASR-0.6B-bf16"
    nonisolated static let largeModel = "mlx-community/Qwen3-ASR-1.7B-bf16"
    nonisolated static let requiredPython = "3.10–3.13"
    nonisolated static let requiredDiskBytes: Int64 = 6_000_000_000
    nonisolated static let uvVersion = "0.12.3"
    nonisolated static let engineVersion = "0.2.0"
    nonisolated static let selectedModelDefaultsKey = "qwen_asr_selected_model"
    static let shared = QwenASRInstaller()

    private(set) var phase: Phase = .unknown
    var selectedModel: String {
        didSet {
            guard oldValue != selectedModel else { return }
            UserDefaults.standard.set(selectedModel, forKey: Self.selectedModelDefaultsKey)
            refresh()
        }
    }
    private(set) var installProgress = InstallProgressStore.load(providerID: "qwen-asr")
    private var task: Task<Void, Never>?

    private init() {
        selectedModel = Self.validModel(
            UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey))
    }

    nonisolated static func validModel(_ candidate: String?) -> String {
        guard let candidate, [smallModel, largeModel].contains(candidate) else { return smallModel }
        return candidate
    }

    private struct InstallRecord: Codable {
        enum Status: String, Codable { case installing, ready, failed, cancelled }
        let model: String
        let status: Status
        let message: String?
        let updatedAt: Date
    }

    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
    }

    var python: URL { root.appendingPathComponent(".venv/bin/python3") }

    nonisolated static func venvRoot(at root: URL) -> URL {
        root.appendingPathComponent(".venv", isDirectory: true)
    }

    /// Version 0.32.16 accidentally passed `.venv/bin` to `uv venv`, producing
    /// `.venv/bin/bin/python3`. That environment cannot be resumed at the correct path.
    @discardableResult
    nonisolated static func repairLegacyVenv(at root: URL) throws -> Bool {
        let manager = FileManager.default
        let expected = root.appendingPathComponent(".venv/bin/python3")
        let nested = root.appendingPathComponent(".venv/bin/bin/python3")
        guard !manager.fileExists(atPath: expected.path),
              manager.fileExists(atPath: nested.path) else { return false }
        try manager.removeItem(at: venvRoot(at: root))
        return true
    }

    @discardableResult
    nonisolated static func removeInvalidVenv(at root: URL) throws -> Bool {
        let venv = venvRoot(at: root)
        guard FileManager.default.fileExists(atPath: venv.path) else { return false }
        let python = venv.appendingPathComponent("bin/python3")
        let configuration = venv.appendingPathComponent("pyvenv.cfg")
        guard !FileManager.default.isExecutableFile(atPath: python.path)
                || !FileManager.default.fileExists(atPath: configuration.path) else { return false }
        try FileManager.default.removeItem(at: venv)
        return true
    }

    nonisolated static func installEnvironment(root: URL) -> [String: String] {
        [
            "UV_PYTHON_INSTALL_DIR": root.appendingPathComponent("python", isDirectory: true).path,
            "UV_NO_MODIFY_PATH": "1",
            "HF_HOME": root.appendingPathComponent(".cache/huggingface", isDirectory: true).path,
        ]
    }

    nonisolated static func runtimeEnvironment(root: URL) -> [String: String] {
        ["HF_HOME": root.appendingPathComponent(".cache/huggingface", isDirectory: true).path]
    }

    nonisolated static let modelDownloadScript =
        "import sys; from huggingface_hub import snapshot_download; snapshot_download(repo_id=sys.argv[1])"

    struct InstallationState: Equatable {
        let pythonPresent: Bool
        let enginePresent: Bool
        let modelPresent: Bool

        var isReady: Bool { pythonPresent && enginePresent && modelPresent }
        var canResume: Bool { pythonPresent || enginePresent || modelPresent }
    }

    private var modelMarker: URL { Self.modelMarker(for: selectedModel, root: root) }
    private var stateURL: URL { root.appendingPathComponent("install-state.json") }

    private func persist(_ phase: InstallProgressSnapshot.Phase, step: String? = nil,
                         message: String? = nil) {
        let snapshot = InstallProgressSnapshot(providerID: "qwen-asr", model: selectedModel,
                                               phase: phase, step: step, message: message)
        installProgress = snapshot
        try? InstallProgressStore.save(snapshot)
    }

    var isAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func refresh() {
        guard isAvailable else { phase = .unavailable; return }
        let state = Self.inspect(root: root, model: selectedModel)
        if state.isReady {
            phase = .ready(model: selectedModel)
            persist(.ready)
            return
        }
        if let record = readRecord(), record.model == selectedModel,
           record.status == .failed, let message = record.message {
            phase = .failed(message)
            persist(.failed, message: message)
        } else {
            // An interrupted install is resumable, not ready. `install()` reuses valid artifacts
            // and lets uv/Hugging Face continue from their own caches.
            phase = state.pythonPresent ? .notInstalled : .pythonMissing
        }
    }

    func install() {
        guard isAvailable, !isInstalling else { return }
        let freeBytes = Self.freeDiskSpace(at: root.path)
        guard case .enough = InstallDiagnostics.disk(requiredBytes: Self.requiredDiskBytes,
                                                     freeBytes: freeBytes) else {
            let message = freeBytes.map {
                InstallDiagnostics.diskMessage(requiredBytes: Self.requiredDiskBytes,
                                               freeBytes: $0)
            } ?? L("I could not check the free space on disk.")
            phase = .failed(message)
            persist(.failed, step: L("check free disk space"), message: message)
            return
        }
        task?.cancel()
        phase = .installing
        persist(.installing, step: L("prepare the local voice runtime"))
        writeRecord(.init(model: selectedModel, status: .installing, message: nil, updatedAt: .now))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let installEnvironment = Self.installEnvironment(root: root)
                // Do not ask the person to find or install Python. uv is a small, isolated
                // bootstrapper; it downloads Python 3.12 into BeLauncher's support folder and
                // never changes the user's system Python or shell configuration.
                self.persist(.installing, step: L("download the local bootstrapper"))
                let uv = try await Self.ensureUV(at: root)
                _ = try Self.repairLegacyVenv(at: root)
                _ = try Self.removeInvalidVenv(at: root)
                if !Self.inspect(root: root, model: selectedModel).pythonPresent {
                    self.persist(.installing, step: L("prepare Python"))
                    try await Self.run(uv.path, ["python", "install", "3.12", "--no-bin"],
                                       step: L("prepare Python"), environment: installEnvironment)
                    self.persist(.installing, step: L("create the local environment"))
                    try await Self.run(uv.path, ["venv", Self.venvRoot(at: root).path,
                                                  "--python", "3.12"], step: L("create the local environment"),
                                       environment: installEnvironment)
                }
                if !Self.inspect(root: self.root, model: self.selectedModel).enginePresent {
                    self.persist(.installing, step: L("install the voice engine"))
                    try await Self.run(uv.path, ["pip", "install", "--python", python.path,
                                                  "--upgrade", "qwen3-asr-mlx==\(Self.engineVersion)"],
                                       step: L("install the voice engine"),
                                       environment: installEnvironment)
                    try await Self.run(python.path,
                                       ["-c", "import qwen3_asr_mlx, huggingface_hub"],
                                       step: L("verify the voice engine"),
                                       environment: installEnvironment)
                    try Data(Self.engineVersion.utf8).write(
                        to: Self.engineMarker(at: root), options: .atomic)
                }
                // Download the selected weights now, while the person can see progress in Settings.
                self.persist(.downloading, step: L("download the model"))
                try await Self.run(python.path, ["-c", Self.modelDownloadScript, selectedModel],
                                   step: L("download the model"), environment: installEnvironment)
                guard !Task.isCancelled else { return }
                guard Self.inspect(root: self.root, model: self.selectedModel).isReady else {
                    throw Failure.modelIncomplete
                }
                try Data(selectedModel.utf8).write(to: modelMarker, options: .atomic)
                self.writeRecord(.init(model: self.selectedModel, status: .ready,
                                       message: nil, updatedAt: .now))
                self.persist(.ready)
                phase = .ready(model: selectedModel)
            } catch is CancellationError {
                self.writeRecord(.init(model: self.selectedModel, status: .cancelled,
                                       message: nil, updatedAt: .now))
                phase = .notInstalled
                self.persist(.cancelled)
            } catch {
                let message = Self.userFacingMessage(for: error)
                self.writeRecord(.init(model: self.selectedModel, status: .failed,
                                       message: message, updatedAt: .now))
                phase = .failed(message)
                self.persist(.failed, message: message)
            }
        }
    }

    /// `attributesOfFileSystem` bridges numeric values as `NSNumber` on macOS. Do not cast the
    /// bridged object directly to `Int64`: that returns nil on a real Mac and turns a healthy
    /// volume into the misleading "could not check" installer error.
    nonisolated static func freeDiskSpace(at path: String) -> Int64? {
        let manager = FileManager.default
        var probe = URL(fileURLWithPath: path, isDirectory: true)
        while !manager.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        guard let value = try? manager.attributesOfFileSystem(forPath: probe.path)[.systemFreeSize]
        else { return nil }
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        writeRecord(.init(model: selectedModel, status: .cancelled, message: nil, updatedAt: .now))
        phase = .notInstalled
        persist(.cancelled)
    }

    var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var canResume: Bool {
        Self.inspect(root: root, model: selectedModel).canResume
    }

    private func readRecord() -> InstallRecord? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(InstallRecord.self, from: data)
    }

    private func writeRecord(_ record: InstallRecord) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: stateURL, options: .atomic)
        } catch {
            // The runtime remains usable even if its diagnostic marker cannot be persisted.
        }
    }

    /// The marker is only a convenience written by BeLauncher. It is never trusted on its own:
    /// the model must be present in the Hugging Face cache as a real snapshot with configuration
    /// and weights. This also recognises models downloaded before BeLauncher created its marker.
    nonisolated static func inspect(root: URL, model: String,
                                    modelCacheRoots: [URL]? = nil) -> InstallationState {
        let fm = FileManager.default
        let pythonPresent = fm.isExecutableFile(
            atPath: root.appendingPathComponent(".venv/bin/python3").path)
            && fm.fileExists(atPath: root.appendingPathComponent(".venv/pyvenv.cfg").path)
        let enginePresent = pythonPresent && engineInstalled(root: root)
        let roots = modelCacheRoots ?? cacheRoots(for: root)
        let modelPresent = roots.contains { modelSnapshotExists(model: model, cacheRoot: $0) }
        return InstallationState(pythonPresent: pythonPresent, enginePresent: enginePresent,
                                  modelPresent: modelPresent)
    }

    private nonisolated static func engineInstalled(root: URL) -> Bool {
        guard (try? String(contentsOf: engineMarker(at: root), encoding: .utf8))
            == engineVersion else { return false }
        let sitePackages = root.appendingPathComponent(".venv/lib")
        guard let items = FileManager.default.enumerator(
            at: sitePackages, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        return items.compactMap { $0 as? URL }.contains {
            $0.lastPathComponent == "__init__.py" &&
            $0.deletingLastPathComponent().lastPathComponent == "qwen3_asr_mlx"
        }
    }

    nonisolated static func engineMarker(at root: URL) -> URL {
        root.appendingPathComponent(".engine-\(engineVersion).ready")
    }

    private nonisolated static func cacheRoots(for root: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            root.appendingPathComponent(".cache/huggingface/hub"),
            home.appendingPathComponent(".cache/huggingface/hub"),
            home.appendingPathComponent("Library/Caches/huggingface/hub"),
        ]
    }

    private nonisolated static func modelSnapshotExists(model: String, cacheRoot: URL) -> Bool {
        let cacheName = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let snapshots = cacheRoot.appendingPathComponent(cacheName).appendingPathComponent("snapshots")
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        return versions.contains { snapshot in
            guard (try? snapshot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("config.json").path)
            else { return false }
            return snapshotWeightsAreComplete(snapshot)
        }
    }

    private nonisolated static func snapshotWeightsAreComplete(_ snapshot: URL) -> Bool {
        let manager = FileManager.default
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let map = root["weight_map"] as? [String: String] {
            let shards = Set(map.values)
            return !shards.isEmpty && shards.allSatisfy {
                weightFileIsComplete(snapshot.appendingPathComponent($0))
            }
        }
        guard let entries = try? manager.contentsOfDirectory(
            at: snapshot, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        let weights = entries.filter {
            $0.pathExtension == "safetensors" && !$0.lastPathComponent.hasSuffix(".index.json")
        }
        return !weights.isEmpty && weights.allSatisfy(weightFileIsComplete)
    }

    private nonisolated static func weightFileIsComplete(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path),
              let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        // Every Qwen3-ASR weight file is hundreds of MB. This low floor rejects marker files,
        // empty shards and broken cache links without coupling detection to one model revision.
        return size > 1_048_576
    }

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .exit(let step, let code, let stderr):
                return userFacingMessage(step: step, code: code, stderr: stderr)
            case .download:
                return InstallDiagnostics.networkMessage(for: .offline)
            case .modelIncomplete:
                return L("The local voice setup stopped before finishing. Retry to resume it; your launcher is unaffected.")
            }
        }
        return L("The local voice setup stopped. Retry to continue.")
    }

    /// Bridges Process to structured concurrency without leaving a download alive after the
    /// Settings task is cancelled. A plain continuation does not observe task cancellation, so
    /// the old implementation could keep uv/pip running after the UI said "cancelled".
    private final class ProcessRun: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var continuation: CheckedContinuation<Void, Error>?
        private var cancelled = false

        func start(executable: String, arguments: [String], step: String,
                   environment: [String: String],
                   stderr: FileHandle, stderrURL: URL,
                   continuation: CheckedContinuation<Void, Error>) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                try? stderr.close()
                let message = String(data: (try? Data(contentsOf: stderrURL)) ?? Data(),
                                     encoding: .utf8) ?? ""
                let result: Result<Void, Error> = process.terminationStatus == 0
                    ? .success(())
                    : .failure(Failure.exit(step, process.terminationStatus, message))
                self.finish(result, cleanup: stderrURL)
            }

            lock.lock()
            self.process = process
            self.continuation = continuation
            let shouldCancel = cancelled
            lock.unlock()

            guard !shouldCancel else {
                cancel()
                return
            }
            do {
                try process.run()
                lock.lock()
                let cancelledAfterStart = cancelled
                lock.unlock()
                if cancelledAfterStart { process.terminate() }
            } catch {
                try? stderr.close()
                finish(.failure(error), cleanup: stderrURL)
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            process?.terminate()
            continuation?.resume(throwing: CancellationError())
        }

        private func finish(_ result: Result<Void, Error>, cleanup: URL? = nil) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.process = nil
            lock.unlock()
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            guard let continuation else { return }
            switch result {
            case .success: continuation.resume()
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    /// Keep the useful part of a subprocess failure. In particular, exit 2 is commonly Python's
    /// usage/runtime error, and replacing it with only "error 2" made an interrupted or malformed
    /// model install impossible to diagnose from the app. The launcher still shows a short,
    /// bounded diagnostic rather than dumping an entire pip traceback into Settings.
    nonisolated static func userFacingMessage(step: String, code: Int32, stderr: String) -> String {
        let detail = stderr
            .replacingOccurrences(of: "\u{001B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(detail.suffix(900))
        let base = code == 2
            ? L("The local voice setup stopped before finishing. Retry to resume it; your launcher is unaffected.")
            : L("The local voice setup stopped at %@. Retry to continue.", step)
        guard !bounded.isEmpty else { return base }
        return base + "\n\n" + bounded
    }

    nonisolated static func modelMarker(for model: String, root: URL) -> URL {
        let safe = model.replacingOccurrences(of: "/", with: "-")
        return root.appendingPathComponent(".model-\(safe).installed")
    }

    private static func run(_ executable: String, _ arguments: [String], step: String,
                            environment: [String: String] = [:]) async throws {
        let run = ProcessRun()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let stderrURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("belauncher-qwen-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: stderrURL.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
                guard let errorFile = try? FileHandle(forWritingTo: stderrURL) else {
                    continuation.resume(throwing: Failure.download)
                    return
                }
                run.start(executable: executable, arguments: arguments, step: step,
                          environment: environment,
                          stderr: errorFile, stderrURL: stderrURL,
                          continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }

    private static func ensureUV(at root: URL) async throws -> URL {
        let destination = root.appendingPathComponent("uv")
        let versionMarker = root.appendingPathComponent("uv-version")
        if FileManager.default.isExecutableFile(atPath: destination.path),
           (try? String(contentsOf: versionMarker, encoding: .utf8)) == uvVersion {
            return destination
        }

        #if arch(arm64)
        let archiveName = "uv-aarch64-apple-darwin.tar.gz"
        let expectedSHA256 = "546f7f8a6c70ff13a3a9d2bc958db3427298cebf3e0cb756f9177133b7068843"
        #else
        let archiveName = "uv-x86_64-apple-darwin.tar.gz"
        let expectedSHA256 = "4c9f52262a14da336e4a42ed24992d12d0c956acde87619e4611d321dffa602b"
        #endif
        let url = URL(string: "https://github.com/astral-sh/uv/releases/download/\(uvVersion)/\(archiveName)")!
        let temporary = root.appendingPathComponent("uv-download-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == expectedSHA256 else { throw Failure.download }
        try data.write(to: temporary, options: .atomic)

        let unpacked = root.appendingPathComponent("uv-unpacked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try await run("/usr/bin/tar", ["-xzf", temporary.path, "-C", unpacked.path],
                      step: L("unpack the local runtime"))
        guard let found = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "uv" })
        else { throw Failure.download }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: found, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        try Data(uvVersion.utf8).write(to: versionMarker, options: .atomic)
        return destination
    }

    private enum Failure: LocalizedError {
        case exit(String, Int32, String), download, modelIncomplete
        var stepName: String {
            if case .exit(let step, _, _) = self { return step }
            return L("download")
        }
        var errorDescription: String? {
            switch self {
            case .exit(let step, let code, let stderr):
                let detail = stderr.isEmpty ? "" : "\n\(stderr.suffix(2400))"
                return L("Could not %@ (code %@).", step, String(code)) + detail
            case .download: return "Could not download the local voice runtime."
            case .modelIncomplete:
                return L("The local voice setup stopped before finishing. Retry to resume it; your launcher is unaffected.")
            }
        }
    }
}

enum QwenASRRuntime {
    static var isReady: Bool {
        readyModel != nil
    }

    static var readyModel: String? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
        let selected = QwenASRInstaller.validModel(
            UserDefaults.standard.string(forKey: QwenASRInstaller.selectedModelDefaultsKey))
        return readyModel(at: root, selectedModel: selected)
    }

    static func readyModel(at root: URL, selectedModel: String,
                           modelCacheRoots: [URL]? = nil) -> String? {
        QwenASRInstaller.inspect(root: root, model: selectedModel,
                                modelCacheRoots: modelCacheRoots).isReady
            ? selectedModel : nil
    }

    static func transcribe(fileAt url: URL, model: String) async throws -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
        let python = root.appendingPathComponent(".venv/bin/python3")
        guard QwenASRInstaller.inspect(root: root, model: model).isReady
        else {
            throw Failure.notInstalled
        }
        let wav = try normalizedAudioURL(for: url)
        defer {
            if wav != url { try? FileManager.default.removeItem(at: wav) }
        }
        let code = "import sys; from qwen3_asr_mlx import Qwen3ASR; print(Qwen3ASR.from_pretrained(sys.argv[2]).transcribe(sys.argv[1]).text)"
        let output = try await run(python.path, ["-c", code, wav.path, model],
                                   environment: QwenASRInstaller.runtimeEnvironment(root: root))
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }

    /// qwen3-asr-mlx reads PCM WAV directly. AVAudioRecorder writes AAC M4A and the call
    /// recorder may write CAF, so decode those macOS-native containers before crossing into
    /// Python. The temporary file is deleted immediately after the subprocess exits.
    static func normalizedAudioURL(for url: URL) throws -> URL {
        guard url.pathExtension.lowercased() != "wav" else { return url }
        let input = try AVAudioFile(forReading: url)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-asr-(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: temporary, settings: input.processingFormat.settings)
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                             frameCapacity: capacity) else {
            throw Failure.audioConversion
        }
        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            let frames = AVAudioFrameCount(min(Int64(capacity), remaining))
            try input.read(into: buffer, frameCount: frames)
            try output.write(from: buffer)
        }
        return temporary
    }

    private static func run(_ executable: String, _ arguments: [String],
                            environment: [String: String] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 { continuation.resume(returning: output) }
                else {
                    let detail = output
                        .replacingOccurrences(of: "\u{001B}", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure.exit(process.terminationStatus,
                                                               String(detail.suffix(1_200))))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private enum Failure: LocalizedError {
        case notInstalled, empty, audioConversion, exit(Int32, String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Qwen ASR is not installed."
            case .empty: return "Qwen ASR returned no text."
            case .audioConversion:
                return L("This audio format could not be prepared for local transcription.")
            case .exit(let code, let detail):
                let base = "Qwen ASR exited with code \(code)."
                return detail.isEmpty ? base : base + "\n" + detail
            }
        }
    }
}
