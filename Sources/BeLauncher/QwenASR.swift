import Foundation

/// Owns the optional MLX runtime outside BeLauncher's process. The launcher must remain a small
/// menu-bar agent even when a 1.7B model is loaded, so all Python and model memory live here.
@MainActor
@Observable
final class QwenASRInstaller {
    enum Phase: Equatable {
        case unknown
        case unavailable
        case notInstalled
        case installing
        case ready(model: String)
        case failed(String)
    }

    static let smallModel = "mlx-community/Qwen3-ASR-0.6B-bf16"
    static let largeModel = "mlx-community/Qwen3-ASR-1.7B-bf16"

    private(set) var phase: Phase = .unknown
    var selectedModel = QwenASRInstaller.smallModel
    private var task: Task<Void, Never>?

    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
    }

    var python: URL { root.appendingPathComponent(".venv/bin/python3") }

    var isAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func refresh() {
        guard isAvailable else { phase = .unavailable; return }
        phase = FileManager.default.isExecutableFile(atPath: python.path)
            ? .ready(model: selectedModel) : .notInstalled
    }

    func install() {
        guard isAvailable, !isInstalling else { return }
        task?.cancel()
        phase = .installing
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try await Self.run(Self.systemPython, ["-m", "venv", python.deletingLastPathComponent().path])
                try await Self.run(python.path, ["-m", "pip", "install", "--upgrade", "qwen3-asr-mlx"])
                // Download the selected weights now, while the person can see progress in Settings.
                let code = "import sys; from qwen3_asr_mlx import Qwen3ASR; Qwen3ASR.from_pretrained(sys.argv[1])"
                try await Self.run(python.path, ["-c", code, selectedModel])
                guard !Task.isCancelled else { return }
                phase = .ready(model: selectedModel)
            } catch is CancellationError {
                phase = .notInstalled
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .notInstalled
    }

    var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: Failure.exit(process.terminationStatus)) }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    private static var systemPython: String {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/python3"
    }

    private enum Failure: LocalizedError {
        case exit(Int32)
        var errorDescription: String? {
            switch self { case .exit(let code): "Qwen ASR installer exited with code \(code)." }
        }
    }
}

enum QwenASRRuntime {
    static func transcribe(fileAt url: URL, model: String) async throws -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
        let python = root.appendingPathComponent(".venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
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
