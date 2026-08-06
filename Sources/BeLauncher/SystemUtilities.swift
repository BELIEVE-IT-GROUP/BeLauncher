import AppKit
import IOKit.pwr_mgt
import BeLauncherCore

/// Reading what is running, ending it, and keeping the Mac awake.
///
/// The three things people keep a menu-bar app around for. Each one here is small enough that
/// the standalone app stops earning its place, which is the actual product goal: not the feature,
/// the app you get to delete.
@MainActor
enum SystemUtilities {

    // MARK: - What is running

    /// Reads every process once. `ps` rather than a sampling API: one cheap call that already
    /// accounts for the whole machine, read for two seconds and thrown away.
    static func processes() -> [RunningProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aeo", "pid=,pcpu=,rss=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessList.parse(String(decoding: data, as: UTF8.self))
            .filter { $0.id != ProcessInfo.processInfo.processIdentifier }
    }

    /// Asks it to quit, the way ⌘Q does, so it gets to save.
    static func quit(pid: String, force: Bool) -> String? {
        guard let identifier = Int32(pid) else { return "Ese proceso ya no existe." }

        let all = processes()
        guard let target = all.first(where: { $0.id == identifier }) else {
            return "Ese proceso ya no está corriendo."
        }
        // The one judgement that matters in this feature.
        if let refusal = ProcessList.refusal(for: target) { return refusal }

        // An app gets the polite request first: it can save, ask about unsaved changes and close
        // its windows. A signal cannot do any of that.
        if let application = NSRunningApplication(processIdentifier: identifier) {
            if force {
                guard confirmForce(named: target.name) else { return nil }
                return application.forceTerminate()
                    ? nil : "macOS no dejó cerrar «\(target.name)»."
            }
            return application.terminate() ? nil : "«\(target.name)» no quiso cerrarse. "
                + "Prueba con ⌘K → Forzar la salida."
        }

        // A daemon with no application object: signals are all there is.
        if force { guard confirmForce(named: target.name) else { return nil } }
        let result = kill(identifier, force ? SIGKILL : SIGTERM)
        return result == 0 ? nil : "No se pudo cerrar «\(target.name)» (¿es de otro usuario?)."
    }

    /// Forcing loses unsaved work, so it asks, every time. This is the one place in the app where
    /// a confirmation is worth the friction.
    private static func confirmForce(named name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "¿Forzar la salida de «\(name)»?"
        alert.informativeText = "No podrá guardar nada. Lo que tenga sin guardar se pierde."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forzar la salida")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Staying awake

    private static var assertion: IOPMAssertionID = 0
    private(set) static var awakeUntil: Date?
    private(set) static var isAwake = false
    private static var timer: Timer?

    /// Holds the Mac awake for a while, or until told otherwise.
    ///
    /// `PreventUserIdleSystemSleep` and not `NoDisplaySleep`: keeping the machine working is the
    /// point, and keeping a laptop's screen lit for five hours in a bag is not.
    @discardableResult
    static func stayAwake(minutes: Int?) -> String {
        stopStayingAwake()

        var identifier: IOPMAssertionID = 0
        let reason = "BeLauncher: no dejar dormir el Mac" as CFString
        let created = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &identifier
        )
        guard created == kIOReturnSuccess else {
            return "macOS no dejó activar el modo despierto."
        }
        assertion = identifier
        isAwake = true

        guard let minutes else {
            awakeUntil = nil
            return "El Mac no se dormirá hasta que lo apagues desde la barra de menús."
        }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        awakeUntil = end
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { _ in
            Task { @MainActor in stopStayingAwake() }
        }
        return "El Mac no se dormirá durante \(StayAwake.label(forMinutes: minutes))."
    }

    static func stopStayingAwake() {
        timer?.invalidate()
        timer = nil
        guard isAwake else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        isAwake = false
        awakeUntil = nil
    }

    // MARK: - Quick notes

    /// Writes the note and returns where it landed, so the person can be told rather than left
    /// wondering whether it worked.
    enum NoteResult {
        case saved(path: String)
        /// A sentence for the person; nothing rethrows it.
        case failed(String)
    }

    static func write(note text: String, inVaultAt root: String) -> NoteResult {
        let folder = QuickNote.folder(inVaultAt: root)
        do {
            try FileManager.default.createDirectory(atPath: folder,
                                                    withIntermediateDirectories: true)
        } catch {
            return .failed("No se pudo abrir la carpeta de notas: \(error.localizedDescription)")
        }
        let path = (folder as NSString).appendingPathComponent(QuickNote.filename(for: text))
        do {
            try QuickNote.render(text).write(toFile: path, atomically: true, encoding: .utf8)
            return .saved(path: path)
        } catch {
            return .failed("No se pudo guardar la nota: \(error.localizedDescription)")
        }
    }
}
