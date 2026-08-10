import Foundation

/// What it takes to get Gemma running locally through the LiteRT-LM bridge, without pretending
/// this is a small download. Mirrors the shape of `ModelInstall` (the embeddings model installer)
/// but for two flat files fetched over plain HTTPS — no service to start, no layered pull
/// protocol underneath, because there is exactly one binary and one model file, not a manifest of
/// blobs.
public enum LiteRTLMInstall {
    public static let modelName = "gemma-4-E4B-it"

    /// Published by Google under litert-community on Hugging Face: no auth required, resolves to
    /// a single file, supports Range requests (verified via HEAD, see docs/spikes/litert-lm-server.md).
    public static let modelURL = URL(
        string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm"
    )!

    /// Built, signed and notarized by the `litert-lm-server` release workflow and published to
    /// Believe's own R2 bucket — see Scripts/release-litert-lm-server.sh. "latest" is a stable
    /// alias the workflow overwrites on every publish, same convention as BeLauncher-latest.dmg.
    public static let binaryURL = URL(
        string: "https://files.believe-global.com/apps/belauncher/litert-lm/litert_lm_server_bridge-latest"
    )!

    /// The bridge links this one library through `@rpath` and carries a plain `@loader_path`
    /// rpath, so it loads as long as the file sits next to the executable — which is why it is
    /// fetched as a second flat file rather than an archive that would need unpacking. Re-signed
    /// with our own Developer ID by the release script: dyld refuses to map a library whose Team
    /// ID differs from the hardened-runtime process loading it.
    public static let dylibName = "libGemmaModelConstraintProvider.dylib"
    public static let dylibURL = URL(
        string: "https://files.believe-global.com/apps/belauncher/litert-lm/libGemmaModelConstraintProvider.dylib"
    )!

    /// Measured via HEAD against `modelURL` on 2026-08-10; used only as a fallback denominator
    /// when a response carries no Content-Length, so the bar never divides by zero.
    public static let modelBytes: Int64 = 3_659_530_240
    public static let binaryBytes: Int64 = 31_200_000
    public static let requiredDiskBytes: Int64 = modelBytes + binaryBytes + 300_000_000

    /// One line justifying a 3.6 GB download. Said once, said honestly: what it is, what it
    /// costs, why it stays private.
    public static var pitch: String {
        L("A full local model that answers without leaving this Mac: no conversation, no document ever reaches a server. About 3.6 GB, downloaded once.")
    }

    // MARK: - What is on the machine

    public struct MachineState: Sendable, Equatable {
        public var binaryPresent: Bool
        public var modelPresent: Bool

        public init(binaryPresent: Bool, modelPresent: Bool) {
            self.binaryPresent = binaryPresent
            self.modelPresent = modelPresent
        }

        public var isReady: Bool { binaryPresent && modelPresent }
    }

    // MARK: - Reporting UI

    public struct Progress: Sendable, Equatable {
        public var completedBytes: Int64
        public var totalBytes: Int64

        public init(completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
            self.completedBytes = completedBytes
            self.totalBytes = totalBytes
        }

        public var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(completedBytes) / Double(totalBytes))
        }
    }

    /// Deliberately no case means "broken": the worst state a person who skips this entirely
    /// sees is `notReady`, which reads as "not set up yet", not as a failure of the app.
    public enum Phase: Sendable, Equatable {
        case idle
        case checking
        case ready
        case notReady(MachineState)
        case downloadingBinary(Progress)
        case downloadingModel(Progress)
        /// Person cancelled. Not `notReady`: needs its own words ("nothing lost, pick it up
        /// again") and its own button back, same as `ModelInstall.Phase.cancelled`.
        case cancelled
        case insufficientSpace(freeBytes: Int64)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .checking, .downloadingBinary, .downloadingModel: true
            case .idle, .ready, .notReady, .cancelled, .insufficientSpace, .failed: false
            }
        }

        public var canCancel: Bool {
            switch self {
            case .downloadingBinary, .downloadingModel: true
            default: false
            }
        }
    }

    public static func message(for phase: Phase) -> String {
        switch phase {
        case .idle:
            L("Nobody looked yet whether Gemma is on this Mac.")
        case .checking:
            L("Checking whether Gemma is installed…")
        case .ready:
            L("Ready. Gemma answers with no internet connection.")
        case .notReady:
            L("Gemma is not installed. Every other model keeps working while you decide.")
        case .downloadingBinary(let progress):
            describe(L("Downloading the engine…"), progress)
        case .downloadingModel(let progress):
            describe(L("Downloading the model (~3.6 GB)…"), progress)
        case .cancelled:
            L("Download cancelled. Nothing installed, and what came down already is kept: resuming continues where it left off instead of starting over.")
        case .insufficientSpace(let free):
            InstallDiagnostics.diskMessage(requiredBytes: requiredDiskBytes, freeBytes: free)
        case .failed(let reason):
            reason
        }
    }

    private static func describe(_ headline: String, _ progress: Progress) -> String {
        guard progress.completedBytes > 0 else { return headline }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: progress.completedBytes)
        let total = formatter.string(
            fromByteCount: progress.totalBytes > 0 ? progress.totalBytes : modelBytes)
        let percent = String(Int((progress.fraction * 100).rounded()))
        return L("%1$@ %2$@%% (%3$@ of %4$@)", headline, percent, done, total)
    }
}
