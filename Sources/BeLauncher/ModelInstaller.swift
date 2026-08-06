import Foundation
import AppKit
import BeLauncherCore

/// Carries out the plan `ModelInstall` works out.
///
/// The one rule this exists to enforce: nothing here installs Ollama on someone's Mac without
/// them choosing to. Downloading and running a program the person did not ask for, however good
/// the reason, is the kind of thing that makes people uninstall an app and tell their friends
/// not to try it. So `installOllama` never runs `brew install` or a curl-pipe-to-shell on its
/// own — it opens the official page, or, when Homebrew is already on the machine, offers the one
/// command it would run and asks first.
///
/// Two rules the rest of this file keeps. No subprocess is ever waited on from the main actor:
/// `brew install ollama` takes minutes on a slow line and the app has to stay usable throughout.
/// And every operation takes a ticket, so a result may only be written while it is still the
/// newest thing the person asked for.
@MainActor
@Observable
final class ModelInstaller {
    private(set) var phase: ModelInstall.Phase = .idle

    private var task: Task<Void, Never>?

    /// Bumped by every operation. Three different flows used to assign `phase` from three tasks
    /// that knew nothing about each other: pressing "Descargar" twice left the first download
    /// running and writing phases nobody could cancel, and a slow `check()` landing mid-download
    /// repainted it as "falta el modelo". A stale ticket now writes nothing.
    private var generation = 0

    /// Where a Homebrew-managed Ollama actually lives, on both chip architectures. Checked as a
    /// file rather than shelling out to `which`, which depends on a login shell's `PATH` that a
    /// GUI app launched from Finder never sources.
    private static let ollamaBinaryPaths = [
        "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]
    private static let homebrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private static let ollamaAppPath = "/Applications/Ollama.app"
    private static let ollamaBaseURL = "http://127.0.0.1:11434"

    // MARK: - Who gets to write the phase

    private func newTicket() -> Int {
        generation += 1
        return generation
    }

    private func set(_ phase: ModelInstall.Phase, ticket: Int) {
        guard ticket == generation else { return }
        self.phase = phase
    }

    /// Starts an operation: cancels whatever was running, takes the newest ticket, and paints the
    /// starting phase before the work begins so the screen never sits on the old one.
    private func begin(_ starting: ModelInstall.Phase,
                       _ work: @escaping @MainActor (Int) async -> Void) {
        task?.cancel()
        let ticket = newTicket()
        phase = starting
        task = Task { @MainActor in await work(ticket) }
    }

    // MARK: - Looking at the machine

    /// Never touches the network for the "installed" and "has Homebrew" parts — those are file
    /// checks. Only "is it running" and "is the model pulled" ask the local Ollama server, with a
    /// short timeout so a stopped server does not stall whatever screen asked for this.
    func check() async {
        // Every screen fires this when it appears. Left ungated it would repaint an install or a
        // download that the person started from another screen.
        guard !phase.isOperating else { return }
        let ticket = newTicket()
        set(.checking, ticket: ticket)
        set(await Self.inspect(), ticket: ticket)
    }

    var hasHomebrew: Bool {
        Self.homebrewPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func inspect() async -> ModelInstall.Phase {
        let installed = ollamaBinaryPaths.contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        let running = await isOllamaRunning()
        let modelPresent = running ? await hasModel() : false
        let state = ModelInstall.MachineState(
            ollamaInstalled: installed, ollamaRunning: running, modelPresent: modelPresent)
        return state.isReady ? .ready(model: ModelInstall.modelName) : .notReady(state)
    }

    // MARK: - Step 1: Ollama itself, only with the person's say-so

    /// Opens the download page. The person installs it the way every other Mac app gets
    /// installed — nothing here runs on their machine until they do.
    func openOllamaDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
    }

    /// Runs the one Homebrew command this ever runs, and only because the person just pressed a
    /// button that named it. `brew` is already on the machine and already trusted with software
    /// installs; this is not a new trust decision, it is using one that exists.
    ///
    /// What this leaves behind is the command line formula, not `Ollama.app` — which is why the
    /// next step is `startOllama`, and why that one no longer tries to open an application. The
    /// old pair of them was a trap: this button guaranteed there was no app, and the next screen
    /// told the person to open it from Aplicaciones.
    func installWithHomebrew() {
        guard let brew = Self.brewPath() else { return }
        begin(.installingOllama) { [weak self] ticket in
            let outcome = await Self.run(brew, ["install", "ollama"])
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .exited(0):
                self.set(await Self.inspect(), ticket: ticket)
            case .exited(let code):
                self.set(.failed("Homebrew no pudo instalar Ollama (código \(code)). Prueba "
                                 + "desde ollama.com."), ticket: ticket)
            case .couldNotStart(let reason):
                self.set(.failed("No se pudo ejecutar Homebrew: \(reason)"), ticket: ticket)
            }
        }
    }

    // MARK: - Step 2: starting it

    /// Starts whatever shape of Ollama this Mac has: the application, the Homebrew service, or
    /// the binary directly. `ModelInstall.startMethod` decides which, and the failure message
    /// comes from the same place, so it can never again point at an app that is not there.
    func startOllama() {
        let method = Self.startMethod()
        begin(.startingOllama) { [weak self] ticket in
            await Self.start(method)
            guard let self else { return }
            // Ollama takes a moment to bind its port; poll briefly rather than declare failure on
            // the first missed check.
            for _ in 0..<12 {
                if Task.isCancelled { return }
                if await Self.isOllamaRunning() {
                    self.set(await Self.inspect(), ticket: ticket)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self.set(.failed(ModelInstall.startFailure(for: method)), ticket: ticket)
        }
    }

    private static func startMethod() -> ModelInstall.StartMethod {
        ModelInstall.startMethod(
            appPresent: FileManager.default.fileExists(atPath: ollamaAppPath),
            brewPresent: brewPath() != nil,
            binaryPath: installedBinaryPath()
        )
    }

    private static func start(_ method: ModelInstall.StartMethod) async {
        switch method {
        case .openApp:
            NSWorkspace.shared.open(URL(fileURLWithPath: ollamaAppPath))

        case .brewService:
            guard let brew = brewPath() else { return }
            let outcome = await run(brew, ["services", "start", "ollama"])
            // `brew services` is a tap, and on a machine that never installed it the command
            // exits non-zero. Running the binary is the fallback that still leaves a server
            // listening, which is all the model download needs.
            if outcome != .exited(0), let binary = installedBinaryPath() {
                await detach(binary, ["serve"])
            }

        case .serveCommand(let path):
            await detach(path, ["serve"])

        case .notInstalled:
            break
        }
    }

    // MARK: - Step 3: the model itself

    /// Cancelling lands on its own phase. It used to land on `.idle`, which the screen painted as
    /// a spinner reading "Mirando qué hay en este Mac…" — so someone who stopped a 2 GB download
    /// was left watching a spinner that lied, with no button back, until they closed Ajustes.
    func cancelDownload() {
        task?.cancel()
        task = nil
        _ = newTicket()
        phase = .cancelled
    }

    /// Downloads `bge-m3` through Ollama's own streaming pull endpoint, which is what lets this
    /// show real progress instead of a spinner: each line names how many of how many bytes of one
    /// layer are down, and `ModelInstall.PullProgress` adds the layers up into one number.
    func downloadModel() {
        // Both answers below are final, so they take a ticket too: a check still in flight has no
        // business overwriting "no cabe en el disco" a second later.
        guard let freeBytes = Self.freeDiskSpace() else {
            _ = newTicket()
            phase = .failed("No pude comprobar el espacio libre en disco.")
            return
        }
        guard ModelInstall.hasEnoughDiskSpace(freeBytes: freeBytes) else {
            _ = newTicket()
            phase = .insufficientSpace(freeBytes: freeBytes)
            return
        }

        begin(.downloading(ModelInstall.PullProgress())) { [weak self] ticket in
            guard let self else { return }
            do {
                try await self.pull(ticket: ticket)
                guard !Task.isCancelled else { return }
                self.set(await Self.inspect(), ticket: ticket)
            } catch is CancellationError {
                // `cancelDownload` already said what happened, and it holds a newer ticket.
            } catch let failure as ModelInstall.PullFailure {
                self.set(.failed(failure.description), ticket: ticket)
            } catch {
                let failure = ModelInstall.PullFailure.classify(error.localizedDescription)
                self.set(.failed(failure.description), ticket: ticket)
            }
        }
    }

    private func pull(ticket: Int) async throws {
        var request = URLRequest(url: URL(string: "\(Self.ollamaBaseURL)/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": ModelInstall.modelName])
        // A 2 GB pull on a slow connection genuinely takes minutes; the timeout is per-line
        // inactivity via URLSession's default behaviour, not a hard ceiling on the whole pull.
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ModelInstall.PullFailure.forHTTP(status: http.statusCode,
                                                   model: ModelInstall.modelName)
        }

        var progress = ModelInstall.PullProgress()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let parsed = ModelInstall.parsePullLine(line) else { continue }
            if let error = parsed.error {
                throw ModelInstall.PullFailure.classify(error)
            }
            progress.absorb(parsed)
            set(.downloading(progress), ticket: ticket)
        }
    }

    // MARK: - Running things without freezing the app

    private enum RunOutcome: Sendable, Equatable {
        case exited(Int32)
        case couldNotStart(String)
    }

    /// Waits for a command with the main actor free.
    ///
    /// What this replaces: `process.waitUntilExit()` inside a `Task { @MainActor in }`. That held
    /// the main actor for the whole of `brew install ollama` — minutes on a slow connection — so
    /// the hot key was dead, the window did not repaint, and the "Instalando Ollama…" line never
    /// even reached the screen before the freeze started. The termination handler gives the same
    /// answer without holding anything.
    private nonisolated static func run(_ launchPath: String,
                                        _ arguments: [String]) async -> RunOutcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            // Nothing reads these, and a pipe nobody drains blocks the child once it fills.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: .exited(finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .couldNotStart(error.localizedDescription))
            }
        }
    }

    /// Starts something that is not supposed to end. `ollama serve` only exits when it is killed,
    /// so waiting on it would wait forever; whether it worked is answered by polling the port.
    ///
    /// `nonisolated async` so even the fork and exec happen off the main actor: launching is
    /// milliseconds rather than minutes, but nothing in this file gets to spend the main actor on
    /// a subprocess any more.
    private nonisolated static func detach(_ launchPath: String, _ arguments: [String]) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Reading the machine

    private static func brewPath() -> String? {
        homebrewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func installedBinaryPath() -> String? {
        ollamaBinaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func isOllamaRunning() async -> Bool {
        var request = URLRequest(url: URL(string: "\(ollamaBaseURL)/api/tags")!)
        request.timeoutInterval = 1.5
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    private static func hasModel() async -> Bool {
        var request = URLRequest(url: URL(string: "\(ollamaBaseURL)/api/tags")!)
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return LocalModels.models(in: data).contains { $0.hasPrefix(ModelInstall.modelName) }
    }

    private static func freeDiskSpace() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
