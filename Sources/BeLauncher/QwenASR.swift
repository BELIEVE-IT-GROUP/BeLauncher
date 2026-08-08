import Foundation
import AppKit
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
    static let shared = QwenASRInstaller()

    private(set) var phase: Phase = .unknown
    var selectedModel = QwenASRInstaller.smallModel
    private(set) var installProgress = InstallProgressStore.load(providerID: "qwen-asr")
    private var task: Task<Void, Never>?

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
        if FileManager.default.isExecutableFile(atPath: python.path) &&
            FileManager.default.fileExists(atPath: modelMarker.path) {
            phase = .ready(model: selectedModel)
            persist(.ready)
            return
        }
        if let record = readRecord(), record.model == selectedModel,
           record.status == .failed, let message = record.message {
            phase = .failed(message)
            persist(.failed, message: message)
        } else {
            // An interrupted `installing` record is intentionally treated as not installed: the
            // next background preparation resumes the idempotent uv/pip/model steps.
            phase = .notInstalled
        }
    }

    func install() {
        guard isAvailable, !isInstalling else { return }
        let freeBytes = (try? FileManager.default.attributesOfFileSystem(
            forPath: root.path)[.systemFreeSize] as? Int64) ?? nil
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
                // Do not ask the person to find or install Python. uv is a small, isolated
                // bootstrapper; it downloads Python 3.12 into BeLauncher's support folder and
                // never changes the user's system Python or shell configuration.
                self.persist(.installing, step: L("download the local bootstrapper"))
                let uv = try await Self.ensureUV(at: root)
                if !FileManager.default.isExecutableFile(atPath: python.path) {
                    self.persist(.installing, step: L("prepare Python"))
                    try await Self.run(uv.path, ["python", "install", "3.12"], step: L("prepare Python"))
                    self.persist(.installing, step: L("create the local environment"))
                    try await Self.run(uv.path, ["venv", python.deletingLastPathComponent().path,
                                                  "--python", "3.12"], step: L("create the local environment"))
                }
                self.persist(.installing, step: L("install the voice engine"))
                try await Self.run(uv.path, ["pip", "install", "--python", python.path,
                                              "--upgrade", "qwen3-asr-mlx"], step: L("install the voice engine"))
                // Download the selected weights now, while the person can see progress in Settings.
                self.persist(.downloading, step: L("download the model"))
                let code = "import sys; from qwen3_asr_mlx import Qwen3ASR; Qwen3ASR.from_pretrained(sys.argv[1])"
                try await Self.run(python.path, ["-c", code, selectedModel], step: L("download the model"))
                guard !Task.isCancelled else { return }
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

    func prepareInBackground() {
        refresh()
        if case .notInstalled = phase { install() }
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

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .exit(let step, let code, let stderr):
                return userFacingMessage(step: step, code: code, stderr: stderr)
            case .download:
                return InstallDiagnostics.networkMessage(for: .offline)
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
                   stderr: FileHandle, stderrURL: URL,
                   continuation: CheckedContinuation<Void, Error>) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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

    private static func run(_ executable: String, _ arguments: [String], step: String) async throws {
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
                          stderr: errorFile, stderrURL: stderrURL,
                          continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }

    private static func ensureUV(at root: URL) async throws -> URL {
        let destination = root.appendingPathComponent("uv")
        if FileManager.default.isExecutableFile(atPath: destination.path) { return destination }

        #if arch(arm64)
        let archiveName = "uv-aarch64-apple-darwin.tar.gz"
        #else
        let archiveName = "uv-x86_64-apple-darwin.tar.gz"
        #endif
        let url = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/\(archiveName)")!
        let temporary = root.appendingPathComponent("uv-download-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
        try data.write(to: temporary, options: .atomic)

        let unpacked = root.appendingPathComponent("uv-unpacked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try await run("/usr/bin/tar", ["-xzf", temporary.path, "-C", unpacked.path],
                      step: L("unpack the local runtime"))
        guard let found = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "uv" })
        else { throw Failure.download }
        try FileManager.default.copyItem(at: found, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private enum Failure: LocalizedError {
        case exit(String, Int32, String), download
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
            }
        }
    }
}

enum QwenASRRuntime {
    static var isReady: Bool {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
        let python = root.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(
                atPath: QwenASRInstaller.modelMarker(for: QwenASRInstaller.smallModel,
                                                      root: root).path)
    }

    static func transcribe(fileAt url: URL, model: String) async throws -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
        let python = root.appendingPathComponent(".venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: QwenASRInstaller.modelMarker(for: model, root: root).path)
        else {
            throw Failure.notInstalled
        }
        let code = "import sys; from qwen3_asr_mlx import Qwen3ASR; print(Qwen3ASR.from_pretrained(sys.argv[2]).transcribe(sys.argv[1]).text)"
        let output = try await run(python.path, ["-c", code, url.path, model])
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 { continuation.resume(returning: output) }
                else { continuation.resume(throwing: Failure.exit(process.terminationStatus)) }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private enum Failure: LocalizedError {
        case notInstalled, empty, exit(Int32)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Qwen ASR is not installed."
            case .empty: "Qwen ASR returned no text."
            case .exit(let code): "Qwen ASR exited with code \(code)."
            }
        }
    }
}
