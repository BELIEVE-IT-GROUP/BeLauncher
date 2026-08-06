import Foundation

/// Getting the embeddings model onto the machine, without pretending that not having it is broken.
///
/// `Embedder.swift` measured why the model has to be `bge-m3`: on the same corpus it answered
/// four questions out of four, `nomic-embed-text` two, and nothing that ships with macOS more
/// than one. That number only helps someone who already has it. On a fresh Mac the headline
/// feature — search that understands meaning, not just words — simply does not exist, and a link
/// to documentation is not a fix for that.
///
/// This type holds no state and touches nothing: it turns "what is on this machine" into "what
/// has to happen next" and turns raw `ollama pull` output into a percentage a person can read. The
/// part that runs processes and downloads bytes is `ModelInstaller`, in the app layer, on purpose
/// — everything here can be checked without a network or a subprocess.
public enum ModelInstall {

    public static let modelName = "bge-m3"

    /// Measured at ~1.2 GB compressed on disk; the extra margin covers the manifest, the layer
    /// metadata Ollama also writes, and leaves room so the check does not pass right at the edge.
    public static let requiredDiskBytes: Int64 = 2_400_000_000

    /// What the whole pull weighs, measured on the published `bge-m3` manifest. Used only as the
    /// floor of the progress denominator: `ollama pull` announces one layer at a time, so a bar
    /// divided by "the layers seen so far" reads 100% after the first 20 MB blob and then falls
    /// off a cliff when the 1.2 GB one appears. Dividing by at least the real weight of the model
    /// keeps the number meaning the same thing from the first line to the last.
    public static let expectedModelBytes: Int64 = 1_200_000_000

    /// The one line that has to justify a 2 GB download. Said once, said honestly: what it is
    /// for, what it costs, and where it stays.
    public static let pitch = "El cerebro necesita un modelo que entienda significados: son unos "
        + "2 GB, se queda en tu Mac y no sale nada a internet."

    /// What the app is still able to do without this model. Not a footnote — every place that
    /// reports "no hay modelo" has to say this in the same breath, or it reads as broken.
    public static let wordSearchStillWorks = "Sin este modelo, BeLauncher sigue buscando por "
        + "palabras exactas y por relaciones: no está roto, solo no entiende sinónimos todavía."

    // MARK: - What is on the machine

    public struct MachineState: Sendable, Equatable {
        public var ollamaInstalled: Bool
        public var ollamaRunning: Bool
        public var modelPresent: Bool

        public init(ollamaInstalled: Bool, ollamaRunning: Bool, modelPresent: Bool) {
            self.ollamaInstalled = ollamaInstalled
            self.ollamaRunning = ollamaRunning
            self.modelPresent = modelPresent
        }

        public var isReady: Bool { ollamaInstalled && ollamaRunning && modelPresent }
    }

    // MARK: - What has to happen

    public enum Step: String, Sendable, Equatable, CaseIterable, Identifiable {
        case installOllama
        case startOllama
        case pullModel

        public var id: String { rawValue }

        /// "Poner en marcha" rather than "Abrir": installed through Homebrew there is no
        /// `Ollama.app` to open, and a button that said "Abrir Ollama" was pointing at an
        /// application the Homebrew path guarantees does not exist.
        public var title: String {
            switch self {
            case .installOllama: "Instalar Ollama"
            case .startOllama: "Poner Ollama en marcha"
            case .pullModel: "Descargar \(modelName) (~2 GB)"
            }
        }
    }

    // MARK: - How this particular Mac starts Ollama

    /// Ollama arrives on a Mac in two shapes and they do not start the same way. The disk image
    /// from ollama.com installs `Ollama.app`, which is opened. `brew install ollama` installs only
    /// the command line formula: there is no application anywhere, so opening one fails, and the
    /// old failure message ("Ábrelo desde Aplicaciones") sent people to look for something the
    /// Homebrew button itself guaranteed would not be there.
    public enum StartMethod: Sendable, Equatable {
        /// `/Applications/Ollama.app` is there: open it like any other app.
        case openApp
        /// Homebrew formula: `brew services start ollama` leaves the server running across logins.
        case brewService
        /// The binary exists but Homebrew does not: run `<path> serve` directly.
        case serveCommand(String)
        /// Nothing to start yet.
        case notInstalled
    }

    /// The app is preferred when both exist: it is the one that survives a reboot with the menu
    /// bar icon the person recognises.
    public static func startMethod(appPresent: Bool, brewPresent: Bool,
                                   binaryPath: String?) -> StartMethod {
        if appPresent { return .openApp }
        guard let binaryPath, !binaryPath.isEmpty else { return .notInstalled }
        return brewPresent ? .brewService : .serveCommand(binaryPath)
    }

    /// What to tell someone when starting did not work, per method. Never names Aplicaciones
    /// unless there is an application there to name.
    public static func startFailure(for method: StartMethod) -> String {
        switch method {
        case .openApp:
            "Ollama no arrancó. Ábrelo desde Aplicaciones y vuelve a intentarlo."
        case .brewService:
            "Ollama no arrancó. En una terminal: «brew services start ollama», y vuelve a "
            + "intentarlo aquí."
        case .serveCommand(let path):
            "Ollama no arrancó. En una terminal: «\(path) serve», y vuelve a intentarlo aquí."
        case .notInstalled:
            "Ollama todavía no está en este Mac. Instálalo primero."
        }
    }

    /// The steps missing, in the order they have to happen. Never assumes: a model that is
    /// present but whose server is stopped still needs starting before it can answer anything.
    public static func plan(for state: MachineState) -> [Step] {
        var steps: [Step] = []
        if !state.ollamaInstalled { steps.append(.installOllama) }
        if !state.ollamaRunning { steps.append(.startOllama) }
        if !state.modelPresent { steps.append(.pullModel) }
        return steps
    }

    // MARK: - Reporting it to the UI

    /// What the UI shows. Deliberately has no case that means "broken" — the worst this gets is
    /// `notReady`, and that case is required to say search still works.
    public enum Phase: Sendable, Equatable {
        /// Nobody has looked at the machine yet. Its own state, not a synonym for `checking`: the
        /// two used to be painted with the same spinner, so a screen that was doing nothing at all
        /// span forever under the words "Mirando qué hay en este Mac…".
        case idle
        case checking
        case ready(model: String)
        /// No model yet, or its server is stopped. Not a failure: `wordSearchStillWorks` is the
        /// message for this case everywhere it is shown, so the app never reads as broken here.
        case notReady(MachineState)
        case installingOllama
        case startingOllama
        case downloading(PullProgress)
        /// The person stopped the download. Not a failure and not `idle`: it needs its own words
        /// ("nothing was installed, you can pick it up again") and its own button back.
        case cancelled
        case insufficientSpace(freeBytes: Int64)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .checking, .installingOllama, .startingOllama, .downloading: true
            case .idle, .ready, .notReady, .cancelled, .insufficientSpace, .failed: false
            }
        }

        public var canCancel: Bool {
            if case .downloading = self { return true }
            return false
        }

        /// True while something the person started is running. A background re-check — the one
        /// every screen fires when it appears — must not overwrite these: a `check()` landing late
        /// used to repaint a download in progress as "falta descargar el modelo".
        public var isOperating: Bool {
            switch self {
            case .installingOllama, .startingOllama, .downloading: true
            case .idle, .checking, .ready, .notReady, .cancelled, .insufficientSpace, .failed: false
            }
        }
    }

    public static func message(for phase: Phase) -> String {
        return switch phase {
        case .idle:
            "Todavía no se ha mirado si el modelo está en este Mac."
        case .checking:
            "Comprobando si el modelo de significado está instalado…"
        case .ready(let model):
            "Listo. La búsqueda por significado usa \(model)."
        case .notReady(let state):
            "\(wordSearchStillWorks) Para activar la búsqueda por significado falta: "
                + "\(plan(for: state).map(\.title).joined(separator: " → "))."
        case .installingOllama:
            "Instalando Ollama…"
        case .startingOllama:
            "Poniendo Ollama en marcha…"
        case .downloading(let progress):
            describe(progress)
        case .cancelled:
            "Descarga cancelada. No se instaló nada y puedes retomarla cuando quieras: lo que ya "
                + "se había bajado se conserva."
        case .insufficientSpace(let free):
            spaceMessage(freeBytes: free)
        case .failed(let reason):
            reason
        }
    }

    // MARK: - Disk space, checked before the download starts

    public static func hasEnoughDiskSpace(freeBytes: Int64) -> Bool {
        freeBytes >= requiredDiskBytes
    }

    public static func spaceMessage(freeBytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let free = formatter.string(fromByteCount: freeBytes)
        let needed = formatter.string(fromByteCount: requiredDiskBytes)
        return "No caben los \(needed) del modelo: solo quedan \(free) libres en el disco."
    }

    // MARK: - Reading "ollama pull" as it streams

    /// One line of `POST /api/pull`'s newline-delimited JSON:
    /// `{"status":"pulling ...","total":123,"completed":45}`, ending in `{"status":"success"}`
    /// or, on failure, `{"error":"..."}`.
    public struct PullLine: Sendable, Equatable {
        public let status: String
        public let total: Int64
        public let completed: Int64
        public let error: String?
        /// Which blob this line is about. `ollama pull` interleaves several layers and repeats
        /// each one's counters as they grow; without the digest there is no way to tell "the same
        /// layer, further along" from "a different layer starting".
        public let digest: String

        public init(status: String, total: Int64, completed: Int64, error: String? = nil,
                    digest: String = "") {
            self.status = status
            self.total = total
            self.completed = completed
            self.error = error
            self.digest = digest
        }

        /// Several lines carry no size at all (`"pulling manifest"`, `"verifying sha256 digest"`):
        /// a bare status with no total is not a division by zero, it is 0% of an unknown size.
        public var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        }

        public var isDone: Bool { status == "success" }
    }

    /// Every batch of real output includes lines with no `total`, partial writes cut mid-line by
    /// the pipe, and the occasional blank keep-alive. None of those are a reason to abort a
    /// download that is otherwise going fine — they are simply skipped.
    public static func parsePullLine(_ raw: String) -> PullLine? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let status = object["status"] as? String ?? ""
        let error = object["error"] as? String
        guard !status.isEmpty || error != nil else { return nil }

        let total = (object["total"] as? NSNumber)?.int64Value ?? 0
        let completed = (object["completed"] as? NSNumber)?.int64Value ?? 0
        let digest = object["digest"] as? String ?? ""
        return PullLine(status: status, total: total, completed: completed, error: error,
                        digest: digest)
    }

    // MARK: - Adding the layers up

    /// The download as a whole, not the layer that happened to send the last line.
    ///
    /// What this replaces: the bar was fed `completed / total` of whichever line had just
    /// arrived. `ollama pull` downloads several blobs and starts each one's counter at zero, so a
    /// real pull painted 94% → 7% → 61% → 12%. A bar that goes backwards is worse than no bar:
    /// it tells the person the app lost their download.
    ///
    /// Two rules keep the number honest. Layers are summed by digest, so the denominator is the
    /// whole model and not one blob. And the fraction never goes down: the sum of known layers
    /// only grows as new ones are announced, which would still dip the ratio at the moment a
    /// layer appears. It can stall, it cannot lie backwards, and `completedBytes` underneath is
    /// always the literal truth.
    public struct PullProgress: Sendable, Equatable {
        private struct Layer: Sendable, Equatable {
            var total: Int64
            var completed: Int64
        }

        private var layers: [String: Layer] = [:]
        private var highWater: Double = 0
        private var finished = false

        /// Ollama's own last status word, kept raw so `describe` decides how to say it.
        public private(set) var status: String = ""

        public init() {}

        public mutating func absorb(_ line: PullLine) {
            status = line.status
            if line.isDone {
                finished = true
                highWater = 1
                return
            }
            // Lines with no size at all ("pulling manifest", "verifying sha256 digest") move the
            // wording, never the bar.
            guard line.total > 0 else { return }
            let key = line.digest.isEmpty ? line.status : line.digest
            layers[key] = Layer(total: line.total, completed: min(line.completed, line.total))
            highWater = max(highWater, rawFraction)
        }

        public var completedBytes: Int64 { layers.values.reduce(0) { $0 + $1.completed } }

        /// The layers announced so far. Smaller than the model until the last one shows up, which
        /// is exactly why it is not used alone as the denominator.
        public var knownTotalBytes: Int64 { layers.values.reduce(0) { $0 + $1.total } }

        private var rawFraction: Double {
            let denominator = max(knownTotalBytes, ModelInstall.expectedModelBytes)
            guard denominator > 0 else { return 0 }
            return min(1, Double(completedBytes) / Double(denominator))
        }

        public var fraction: Double { finished ? 1 : highWater }

        public var isDone: Bool { finished }
    }

    /// A status line into something worth reading. Ollama's own vocabulary
    /// (`pulling manifest`, `pulling <digest>`, `verifying sha256 digest`, `success`) is not
    /// meant for a person.
    public static func describe(status: String, fraction: Double) -> String {
        if status.hasPrefix("pulling manifest") { return "Preparando la descarga…" }
        if status.hasPrefix("pulling") { return "Descargando… \(Int((fraction * 100).rounded()))%" }
        if status.hasPrefix("verifying") { return "Verificando lo descargado…" }
        if status == "success" { return "Listo." }
        return status.isEmpty ? "Descargando…" : status
    }

    /// The same sentence with the bytes appended, because a percentage on its own cannot be
    /// checked against anything: 61% of what is the question the number underneath answers.
    public static func describe(_ progress: PullProgress) -> String {
        let headline = describe(status: progress.status, fraction: progress.fraction)
        guard progress.completedBytes > 0, !progress.isDone else { return headline }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: progress.completedBytes)
        let total = formatter.string(
            fromByteCount: max(progress.knownTotalBytes, expectedModelBytes))
        return "\(headline) (\(done) de \(total))"
    }

    // MARK: - Reading what went wrong

    public enum PullFailure: Error, Sendable, Equatable, CustomStringConvertible {
        case noDiskSpace
        case network
        case serverDown
        /// Ollama answered, and what it said was that this model does not exist. Its own case
        /// because the fix is nothing like the fix for a server that is down.
        case modelNotFound(String)
        case other(String)

        public var description: String {
            switch self {
            case .noDiskSpace:
                "No hay espacio suficiente en el disco para terminar la descarga."
            case .network:
                "No hay conexión a internet. Revisa la red e inténtalo de nuevo."
            case .serverDown:
                "Ollama no responde. Ponlo en marcha y vuelve a intentarlo."
            case .modelNotFound(let model):
                "Ollama respondió, pero no encuentra el modelo «\(model)». Actualiza Ollama: las "
                + "versiones viejas no conocen este modelo."
            case .other(let raw):
                "La descarga falló: \(raw)"
            }
        }

        /// What an HTTP status from `/api/pull` means.
        ///
        /// Everything from 400 up used to become `.serverDown`, so a 404 — Ollama answering
        /// perfectly well that it does not know `bge-m3` — was reported as "Ollama no responde",
        /// sending the person to restart a server that was already running.
        public static func forHTTP(status: Int, model: String) -> PullFailure {
            switch status {
            case 404: .modelNotFound(model)
            case 502, 503, 504: .serverDown
            default: .other("Ollama respondió \(status).")
            }
        }

        /// Classifies whatever text came back — an `{"error": ...}` line from the stream, or an
        /// `URLError`'s description — into one of the reasons a person can actually act on.
        public static func classify(_ raw: String) -> PullFailure {
            let text = raw.lowercased()
            if text.contains("no space") || text.contains("disk quota") || text.contains("espacio") {
                return .noDiskSpace
            }
            if text.contains("connection refused") || text.contains("could not connect")
                || text.contains("econnrefused") {
                return .serverDown
            }
            if text.contains("offline") || text.contains("not connected to the internet")
                || text.contains("timed out") || text.contains("network")
                || text.contains("nodename nor servname") {
                return .network
            }
            return .other(raw)
        }
    }
}
