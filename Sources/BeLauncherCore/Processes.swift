import Foundation

/// What is eating the Mac, and how to make it stop.
///
/// The moment this exists for: the fans are loud, something is chewing a core, and finding out
/// what means opening Activity Monitor, waiting for it to sort itself out and reading a table.
/// Two keystrokes is the right answer.
///
/// The judgement that matters here is what *not* to offer. A process list sorted by CPU puts
/// `WindowServer` and `kernel_task` at the top on a busy Mac, and killing either throws you out of
/// your session and loses whatever was unsaved. A launcher that offers those on the first row with
/// Enter bound to Kill is handing someone a loaded gun and calling it a feature.
public struct RunningProcess: Sendable, Equatable, Identifiable {
    public let id: Int32
    public let name: String
    /// Percentage of one core. Above 100 on a machine with more than one.
    public let cpu: Double
    /// Resident memory in bytes.
    public let memory: Int64
    /// Set when this is an app with an icon and a Dock presence, rather than a daemon.
    public let bundlePath: String

    public init(id: Int32, name: String, cpu: Double, memory: Int64, bundlePath: String = "") {
        self.id = id
        self.name = name
        self.cpu = cpu
        self.memory = memory
        self.bundlePath = bundlePath
    }

    public var isApplication: Bool { !bundlePath.isEmpty }

    public var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)
    }

    public var cpuLabel: String { String(format: "%.1f%%", cpu) }
}

public enum ProcessList {

    public enum Order: String, Sendable, CaseIterable {
        case cpu
        case memory

        public var label: String {
            switch self {
            case .cpu: "Por CPU"
            case .memory: "Por memoria"
            }
        }
    }

    /// What must never be offered for killing, whatever it is doing to the CPU.
    ///
    /// These are not "advanced" or "at your own risk". Ending `WindowServer` logs you out
    /// instantly and loses every unsaved document on the Mac; `kernel_task` is the kernel
    /// answering for the whole machine and often sits at the top precisely because the Mac is
    /// hot. Anything here is shown so a person can see what is happening, and refused politely
    /// when they try to end it.
    public static let protected: Set<String> = [
        "kernel_task", "WindowServer", "launchd", "loginwindow", "systemstats", "logd",
        "opendirectoryd", "securityd", "syslogd", "coreaudiod", "distnoted", "notifyd",
        "diskarbitrationd", "configd", "powerd", "hidd", "mds", "mds_stores", "kextd",
        "watchdogd", "UserEventAgent", "Finder", "Dock", "SystemUIServer",
    ]

    public static func isProtected(_ process: RunningProcess) -> Bool {
        protected.contains(process.name)
    }

    /// Why a particular one is refused, in words that say what would happen.
    public static func refusal(for process: RunningProcess) -> String? {
        switch process.name {
        case "WindowServer":
            "WindowServer dibuja todo lo que ves. Cerrarlo te saca de la sesión al instante y "
            + "pierdes lo que no hayas guardado. Suele estar arriba porque el Mac está ocupado, "
            + "no porque esté colgado."
        case "kernel_task":
            "kernel_task es el propio macOS. No se puede cerrar, y cuando sube suele ser el "
            + "sistema gestionando el calor: se baja solo."
        case "Finder", "Dock", "SystemUIServer":
            "\(process.name) es parte del escritorio. Si de verdad quieres reiniciarlo, hazlo "
            + "desde Forzar salida de macOS, que lo vuelve a abrir solo."
        case "launchd", "loginwindow":
            "\(process.name) sostiene tu sesión entera. Cerrarlo te desconecta."
        default:
            isProtected(process)
                ? "\(process.name) es un servicio del sistema. Cerrarlo deja el Mac en un estado "
                + "raro hasta que reinicies."
                : nil
        }
    }

    /// The heaviest first, filtered by whatever was typed.
    ///
    /// Processes using nothing are dropped: a list of 445 idle daemons is not an answer to "what
    /// is making the fans spin", it is the same haystack in a different window.
    public static func top(_ processes: [RunningProcess], order: Order = .cpu,
                           filter: String = "", limit: Int = 8) -> [RunningProcess] {
        let folded = filter
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)

        return processes
            .filter { process in
                guard !folded.isEmpty else {
                    return order == .cpu ? process.cpu >= 0.5 : process.memory >= 50_000_000
                }
                return process.name
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .contains(folded)
            }
            .sorted { first, second in
                order == .cpu ? first.cpu > second.cpu : first.memory > second.memory
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Typing it

    /// What someone types when the Mac is hot. `memoria` sorts the other way, because "what is
    /// eating my RAM" is a different question with a different answer.
    public static func order(for query: String) -> (order: Order, filter: String)? {
        let folded = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
        guard folded.count >= 3 else { return nil }

        let byMemory = ["memoria", "ram", "memory"]
        let byCPU = ["procesos", "cpu", "kill", "matar", "forzar", "que consume",
                     "que esta lento", "activity"]

        for trigger in byMemory where folded == trigger || folded.hasPrefix(trigger + " ") {
            return (.memory, String(folded.dropFirst(trigger.count)).trimmingCharacters(in: .whitespaces))
        }
        for trigger in byCPU where folded == trigger || folded.hasPrefix(trigger + " ") {
            return (.cpu, String(folded.dropFirst(trigger.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The line under the name: what it is costing, and a word when it is untouchable.
    public static func subtitle(for process: RunningProcess, order: Order) -> String {
        var parts = ["CPU \(process.cpuLabel)", process.memoryLabel]
        if order == .memory { parts.reverse() }
        if isProtected(process) { parts.append("del sistema") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Parsing

    /// Reads `ps -Aeo pid=,pcpu=,rss=,comm=`.
    ///
    /// `ps` rather than a sampling API on purpose: it is one cheap call that already accounts for
    /// every process on the machine, and this list is read for two seconds and thrown away.
    public static func parse(_ output: String) -> [RunningProcess] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rss = Int64(fields[2]) else { return nil }

            // comm is the last field and can contain spaces, so it is everything that is left.
            let path = fields[3...].joined(separator: " ")
            guard !path.isEmpty else { return nil }

            // "/Applications/Safari.app/Contents/MacOS/Safari" → "Safari", and the bundle with it.
            let name = (path as NSString).lastPathComponent
            let bundle = path.range(of: ".app/Contents/MacOS/").map { range in
                String(path[path.startIndex..<range.lowerBound]) + ".app"
            } ?? ""

            return RunningProcess(id: pid, name: name, cpu: cpu, memory: rss * 1024,
                                  bundlePath: bundle)
        }
    }
}
