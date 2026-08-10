import Foundation

/// Lifecycle for the LiteRT-LM local core server (Scripts/litert-lm-server-bridge.cc): the process
/// that keeps Gemma loaded in memory and answers OpenAI-compatible chat requests on loopback.
///
/// This is the production successor to the X2/X4 spikes: those proved the model loads and that
/// speculative decoding runs, but each invocation paid the full model-load cost and exited after
/// one hardcoded prompt. The server bridge loads once and stays up; this type is what launches it,
/// waits for it to report ready, and stops it — the same shape `ModelInstaller` uses for Ollama,
/// kept out of the app layer because starting our own bundled binary has no install decision to
/// present to a person.
///
/// Wired into `ModelProviderRegistry` (id `litertlm`) and into `AppDelegate` startup/shutdown.
/// It stays a no-op on every real user's machine until `LiteRTLMLocalCore.isAvailable` is true,
/// which today means someone downloaded the binary and model through `LiteRTLMInstaller` — see
/// docs/spikes/litert-lm-server.md for what is and is not bundled.
public actor LiteRTLMService {
    public static let defaultPort = 8998

    public enum ServiceError: Error, Equatable {
        case alreadyRunning
        case binaryMissing(String)
        case modelMissing(String)
        case didNotBecomeReady
    }

    private var process: Process?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    public init() {}

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Starts the server and suspends until it prints its ready line on stdout, or the process
    /// exits first. `binaryPath` and `modelPath` are caller-supplied rather than discovered here:
    /// this type only manages the process, it does not decide where the model lives on disk.
    public func start(binaryPath: String, modelPath: String,
                      port: Int = LiteRTLMService.defaultPort) async throws {
        guard process == nil else { throw ServiceError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw ServiceError.binaryMissing(binaryPath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ServiceError.modelMissing(modelPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [modelPath, String(port)]
        let stdout = Pipe()
        process.standardOutput = stdout
        self.process = process

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation
            process.terminationHandler = { [weak self] _ in
                Task { await self?.failIfStillWaiting(.didNotBecomeReady) }
            }
            do {
                try process.run()
            } catch {
                self.process = nil
                continuation.resume(throwing: error)
                self.readyContinuation = nil
                return
            }
            Task { await self.watchForReadyLine(on: stdout) }
        }
    }

    public func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Ready signal

    /// The bridge writes exactly one JSON line ({"ready":true,...}) before it starts accepting
    /// connections. Reading line-by-line rather than waiting for EOF matters: the process keeps
    /// running and keeps writing nothing else to stdout for its entire lifetime.
    private func watchForReadyLine(on pipe: Pipe) async {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }  // Pipe closed: the process exited before signalling ready.
            buffer.append(chunk)
            guard let newlineRange = buffer.range(of: Data([0x0A])) else { continue }
            let line = buffer[..<newlineRange.lowerBound]
            if let text = String(data: line, encoding: .utf8),
               text.contains("\"ready\":true") || text.contains("\"ready\": true") {
                resumeReady()
                return
            }
            buffer.removeSubrange(...newlineRange.lowerBound)
        }
    }

    private func resumeReady() {
        readyContinuation?.resume()
        readyContinuation = nil
    }

    private func failIfStillWaiting(_ error: ServiceError) {
        guard let continuation = readyContinuation else { return }
        continuation.resume(throwing: error)
        readyContinuation = nil
        process = nil
    }
}

/// Where the bridge binary and model are expected to live, and whether they are actually there.
///
/// Nothing bundles them yet — see docs/spikes/litert-lm-server.md, "bundling the binary with a
/// signed build" is still an open product decision (a 3.6 GB model cannot ship the same way
/// `brain.html` does). Until that decision is made and shipped, `isAvailable` is false on every
/// real user's machine and the app starts up exactly as it did before this type existed. The env
/// var override exists so a Bazel-built binary and a manually-placed model file (the only way
/// this has been verified so far, per the spike doc) can be exercised without copying gigabytes
/// into Application Support first.
public enum LiteRTLMLocalCore {
    public static func binaryPath() -> String {
        ProcessInfo.processInfo.environment["LITERT_LM_BINARY_PATH"]
            ?? (root as NSString).appendingPathComponent("litert_lm_server_bridge")
    }

    public static func modelPath() -> String {
        ProcessInfo.processInfo.environment["LITERT_LM_MODEL_PATH"]
            ?? (root as NSString).appendingPathComponent("gemma-4-E4B-it.litertlm")
    }

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath())
            && FileManager.default.fileExists(atPath: modelPath())
    }

    private static var root: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/LocalCore", isDirectory: true).path
    }
}
