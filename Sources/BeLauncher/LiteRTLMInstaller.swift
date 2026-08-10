import Foundation
import BeLauncherCore

/// Downloads the LiteRT-LM binary and Gemma model into place, on request only — never on launch,
/// never silently. Mirrors `QwenASRInstaller`'s shape (singleton, `@Observable` phase, task
/// cancellation that actually stops the transfer), simplified because there is no Python runtime
/// to bootstrap here: just two files fetched with `URLSession`, resumed with `Range` when a
/// previous attempt was cancelled partway through.
@MainActor
@Observable
final class LiteRTLMInstaller {
    static let shared = LiteRTLMInstaller()

    private(set) var phase: LiteRTLMInstall.Phase = .idle
    private(set) var installProgress = InstallProgressStore.load(providerID: "litertlm")
    private var task: Task<Void, Never>?

    private init() {}

    var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeLauncher/LocalCore", isDirectory: true)
    }

    private var binaryURL: URL { root.appendingPathComponent("litert_lm_server_bridge") }
    private var modelURL: URL { root.appendingPathComponent("gemma-4-E4B-it.litertlm") }

    var isBusy: Bool { phase.isBusy }
    var canCancel: Bool { phase.canCancel }
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    func refresh() {
        let state = LiteRTLMInstall.MachineState(
            binaryPresent: FileManager.default.isExecutableFile(atPath: binaryURL.path),
            modelPresent: FileManager.default.fileExists(atPath: modelURL.path))
        phase = state.isReady ? .ready : .notReady(state)
        persist(state.isReady ? .ready : .idle)
    }

    func install() {
        guard !isBusy else { return }
        let freeBytes = QwenASRInstaller.freeDiskSpace(at: root.path)
        guard case .enough = InstallDiagnostics.disk(
            requiredBytes: LiteRTLMInstall.requiredDiskBytes, freeBytes: freeBytes) else {
            let free = freeBytes ?? 0
            phase = .insufficientSpace(freeBytes: free)
            persist(.failed, message: LiteRTLMInstall.message(for: phase))
            return
        }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

                if !FileManager.default.isExecutableFile(atPath: binaryURL.path) {
                    try await self.download(from: LiteRTLMInstall.binaryURL, to: binaryURL) { progress in
                        Task { @MainActor in
                            self.phase = .downloadingBinary(progress)
                            self.persist(.downloading, message: LiteRTLMInstall.message(for: self.phase))
                        }
                    }
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
                }
                guard !Task.isCancelled else { throw CancellationError() }

                if !FileManager.default.fileExists(atPath: modelURL.path) {
                    try await self.download(from: LiteRTLMInstall.modelURL, to: modelURL) { progress in
                        Task { @MainActor in
                            self.phase = .downloadingModel(progress)
                            self.persist(.downloading, message: LiteRTLMInstall.message(for: self.phase))
                        }
                    }
                }
                guard !Task.isCancelled else { throw CancellationError() }

                self.phase = .ready
                self.persist(.ready)
            } catch is CancellationError {
                self.phase = .cancelled
                self.persist(.cancelled)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.phase = .failed(message)
                self.persist(.failed, message: message)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .cancelled
        persist(.cancelled)
    }

    private func persist(_ phase: InstallProgressSnapshot.Phase, message: String? = nil) {
        let snapshot = InstallProgressSnapshot(
            providerID: "litertlm", model: LiteRTLMInstall.modelName,
            phase: phase, step: nil, message: message)
        installProgress = snapshot
        try? InstallProgressStore.save(snapshot)
    }

    /// Uses `URLSessionDownloadTask` rather than reading the byte stream by hand: at 3.6 GB, a
    /// manual `for try await byte in bytes` loop would drive hundreds of millions of `Data.append`
    /// calls and never finish in practical time. The resume-data file next to the destination lets
    /// a cancelled or interrupted transfer continue instead of restarting from zero.
    private func download(from source: URL, to destination: URL,
                          onProgress: @escaping @Sendable (LiteRTLMInstall.Progress) -> Void) async throws {
        let resumeDataURL = destination.appendingPathExtension("resume")
        let resumeData = try? Data(contentsOf: resumeDataURL)

        let downloader = LiteRTLMDownloader(onProgress: onProgress)
        let temporary: URL
        do {
            temporary = try await downloader.run(source: source, resumeData: resumeData)
        } catch {
            if let resumeData = await downloader.resumeData {
                try? resumeData.write(to: resumeDataURL)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: resumeDataURL)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// Bridges `URLSessionDownloadDelegate`'s callback-based progress and completion into structured
/// concurrency, the same shape `QwenASRInstaller.ProcessRun` uses for subprocess lifecycles.
/// Cancelling the owning `Task` calls `cancelByProducingResumeData`, so partial progress survives
/// as `resumeData` instead of being discarded.
private actor LiteRTLMDownloader: NSObject, URLSessionDownloadDelegate {
    private nonisolated let onProgress: @Sendable (LiteRTLMInstall.Progress) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private(set) var resumeData: Data?

    init(onProgress: @escaping @Sendable (LiteRTLMInstall.Progress) -> Void) {
        self.onProgress = onProgress
    }

    func run(source: URL, resumeData: Data?) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                Task {
                    await self.start(source: source, resumeData: resumeData, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func start(source: URL, resumeData: Data?,
                       continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: source)
        self.task = task
        task.resume()
    }

    /// Plain `cancel()`, not `cancel(byProducingResumeData:)`: the completion handler variant
    /// would run on an arbitrary queue, and `didCompleteWithError` below already receives resume
    /// data in its `userInfo` for a cancelled task, so nothing here would add.
    private func cancel() {
        task?.cancel()
    }

    private func storeResumeData(_ data: Data?) {
        resumeData = data
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        onProgress(LiteRTLMInstall.Progress(
            completedBytes: totalBytesWritten,
            totalBytes: max(totalBytesExpectedToWrite, 0)))
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-litertlm-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { await self.finish(.failure(error)) }
            return
        }
        Task { await self.finish(.success(destination)) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            Task { await self.storeResumeData(data) }
        }
        let reported: Error = nsError.code == NSURLErrorCancelled ? CancellationError() : error
        Task { await self.finish(.failure(reported)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let url): continuation.resume(returning: url)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private enum LiteRTLMDownloadFailure: LocalizedError {
    case badResponse(Int)
    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            L("The download failed (HTTP %@). Retry to try again.", String(status))
        }
    }
}
