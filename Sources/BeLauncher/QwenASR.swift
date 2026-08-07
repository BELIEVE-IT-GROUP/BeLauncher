import Foundation
import AppKit

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

    static let smallModel = "mlx-community/Qwen3-ASR-0.6B-bf16"
    static let largeModel = "mlx-community/Qwen3-ASR-1.7B-bf16"
    static let requiredPython = "3.10–3.13"
    static let shared = QwenASRInstaller()

    private(set) var phase: Phase = .unknown
    var selectedModel = QwenASRInstaller.smallModel
    private var task: Task<Void, Never>?

    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/ASR", isDirectory: true)
    }

    var python: URL { root.appendingPathComponent(".venv/bin/python3") }

    private var modelMarker: URL { Self.modelMarker(for: selectedModel, root: root) }

    var isAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func refresh() {
        guard isAvailable else { phase = .unavailable; return }
        phase = FileManager.default.isExecutableFile(atPath: python.path) &&
                FileManager.default.fileExists(atPath: modelMarker.path)
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
                // Do not ask the person to find or install Python. uv is a small, isolated
                // bootstrapper; it downloads Python 3.12 into BeLauncher's support folder and
                // never changes the user's system Python or shell configuration.
                let uv = try await Self.ensureUV(at: root)
                if !FileManager.default.isExecutableFile(atPath: python.path) {
                    try await Self.run(uv.path, ["python", "install", "3.12"])
                    try await Self.run(uv.path, ["venv", python.deletingLastPathComponent().path,
                                                  "--python", "3.12"])
                }
                try await Self.run(uv.path, ["pip", "install", "--python", python.path,
                                              "--upgrade", "qwen3-asr-mlx"])
                // Download the selected weights now, while the person can see progress in Settings.
                let code = "import sys; from qwen3_asr_mlx import Qwen3ASR; Qwen3ASR.from_pretrained(sys.argv[1])"
                try await Self.run(python.path, ["-c", code, selectedModel])
                guard !Task.isCancelled else { return }
                try Data(selectedModel.utf8).write(to: modelMarker, options: .atomic)
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

    func prepareInBackground() {
        refresh()
        if case .notInstalled = phase { install() }
    }

    nonisolated static func modelMarker(for model: String, root: URL) -> URL {
        let safe = model.replacingOccurrences(of: "/", with: "-")
        return root.appendingPathComponent(".model-\(safe).installed")
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.terminationHandler = { process in
                guard process.terminationStatus != 0 else {
                    continuation.resume(); return
                }
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(throwing: Failure.exit(process.terminationStatus, stderr))
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
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
        try await run("/usr/bin/tar", ["-xzf", temporary.path, "-C", unpacked.path])
        guard let found = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "uv" })
        else { throw Failure.download }
        try FileManager.default.copyItem(at: found, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private enum Failure: LocalizedError {
        case exit(Int32, String), download
        var errorDescription: String? {
            switch self {
            case .exit(let code, let stderr):
                let detail = stderr.isEmpty ? "" : "\n\(stderr.suffix(2400))"
                return "Qwen ASR installer exited with code \(code).\(detail)"
            case .download: return "Could not download the local voice runtime."
            }
        }
    }
}

enum QwenASRRuntime {
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
