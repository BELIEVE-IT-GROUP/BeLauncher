import Foundation

/// The words and the verdicts the brain screens show, kept out of the views.
///
/// Two things were being decided inside SwiftUI bodies and neither of them belongs there. The
/// first is the wording: "conectado" used to be printed next to a green dot the moment a config
/// file mentioned BeLauncher, which is a claim the app could not back. The second is the verdict
/// itself — deciding whether a set of health checks reads as working, broken or simply unchecked
/// is a rule, and a rule that only exists inside a `View` cannot be tested, so it drifts.
///
/// Everything here is pure: strings in, strings out, no store, no process, no clock.
public enum BrainSetupCopy {

    // MARK: - Numbers, so it stops being a black box

    /// What the brain has, said in numbers a person can check against reality.
    public struct IndexReadout: Sendable, Equatable {
        /// The single line that answers "does this thing have anything in it".
        public let headline: String
        /// What is left to do, or why nothing is.
        public let detail: String
        /// Which model answers, and whether the text leaves the Mac to reach it.
        public let engineLine: String
        public let passages: Int
        public let vectorised: Int
        /// 0…1. Only meaningful when there is something indexed.
        public let percent: Double
        /// True when meaning search is not available yet. Drives whether the setup screen shows.
        public let needsModel: Bool
        /// True when every passage already carries a vector.
        public let isComplete: Bool
    }

    public static func readout(passages: Int, vectorised: Int,
                               engine: String?, isLocal: Bool) -> IndexReadout {
        let percent = passages == 0 ? 0 : min(1, Double(vectorised) / Double(passages))
        let complete = passages > 0 && vectorised >= passages

        let headline: String
        if passages == 0 {
            headline = "Todavía no hay nada indexado."
        } else {
            headline = "\(number(passages)) \(passages == 1 ? "fragmento" : "fragmentos") "
                + "de tus notas, tu trabajo y tu portapapeles."
        }

        let detail: String
        if passages == 0 {
            detail = "En cuanto guardes algo o copies un texto, aparece aquí."
        } else if engine == nil {
            detail = "Se buscan por palabras exactas. Ninguno entiende significado todavía: "
                + "falta el modelo."
        } else if complete {
            detail = "Todos entienden significado."
        } else if vectorised == 0 {
            detail = "Ninguno entiende significado todavía. Empieza a procesarlos y esta cifra sube."
        } else {
            let left = passages - vectorised
            detail = "\(number(vectorised)) entienden significado. Faltan \(number(left)) "
                + "por procesar."
        }

        let engineLine: String
        if let engine {
            engineLine = isLocal
                ? "Modelo \(engine), corriendo en tu Mac. No sale nada a internet."
                : "Modelo \(engine), en un servidor. El texto que buscas sale de tu Mac para "
                    + "llegar hasta él."
        } else {
            engineLine = "Sin modelo instalado. " + ModelInstall.wordSearchStillWorks
        }

        return IndexReadout(headline: headline, detail: detail, engineLine: engineLine,
                            passages: passages, vectorised: vectorised, percent: percent,
                            needsModel: engine == nil, isComplete: complete)
    }

    /// Fixed Spanish grouping rather than the system locale: the same numbers have to read the
    /// same way in a screenshot, in a support ticket and in a test that runs on a machine set to
    /// English.
    public static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Rebuilding the index

    public static let rebuildTitle = "Rehacer el índice"
    public static let rebuildExplanation =
        "Vuelve a cortar todo y a procesarlo desde cero. Tarda, no borra ninguna nota y solo hace "
        + "falta si los resultados dejan de tener sentido."
    public static let rebuildRunning = "Rehaciendo el índice…"

    public static func rebuildFinished(passages: Int, vectorised: Int) -> String {
        "Índice rehecho: \(number(passages)) fragmentos, \(number(vectorised)) con significado."
    }

    // MARK: - The setup screen

    public static let setupTitle = "Que entienda lo que quieres decir"

    /// The reason, with the example that makes it obvious. A number of gigabytes without a reason
    /// is a request; with the example it is an offer.
    public static let setupWhy =
        "Ahora mismo encuentra por las palabras que escribes. Con este modelo encuentra también "
        + "por lo que significan: preguntas «cuánto cobramos por el Pro» y aparece «el precio "
        + "base es 1000 EUR», aunque no compartan ni una palabra."

    public static let setupCost = ModelInstall.pitch
    public static let setupSkip = "Seguir sin él"
    public static let setupLater =
        "Puedes ponerlo más tarde desde Ajustes, en «Mi cerebro»."
    /// Said while the bytes are moving, because the honest answer to "do I have to wait" is no.
    public static let setupKeepUsing =
        "Sigue usando BeLauncher mientras se descarga. Cuando termine te lo decimos aquí."
    public static let setupDone = "Listo. Ya busca por significado."

    /// The two ways to get Ollama, worded so neither one runs anything behind the person's back.
    public static let installByHand = "Descargar Ollama"
    public static let installByHomebrew = "Instalar con Homebrew"
    public static let installExplanation =
        "El modelo se descarga a través de Ollama, que es gratis y también se queda en tu Mac. "
        + "Elige cómo instalarlo: nada se ejecuta sin que lo pulses."

    // MARK: - Whether "conectado" means anything

    /// Three levels, and `unknown` is one of them on purpose. Before this existed the panel had
    /// only two states and defaulted to the good one, so an assistant that answered nothing still
    /// showed green. Never having checked is now its own answer.
    public enum Level: String, Sendable, Equatable {
        case unknown
        case working
        case broken
    }

    public struct Verdict: Sendable, Equatable {
        public let level: Level
        /// The pill text. Short enough to sit next to a client name.
        public let label: String
        /// One sentence naming what failed. Empty when nothing did.
        public let headline: String
        /// What to do about it. Empty when there is nothing to do.
        public let whatToDo: String
    }

    public static func verdict(for report: MCPHealth.Report?) -> Verdict {
        guard let report else {
            return Verdict(level: .unknown, label: "sin comprobar",
                           headline: "Todavía no se ha probado la conexión.",
                           whatToDo: "Pulsa «Comprobar de verdad» y se ejecutan los cinco pasos.")
        }
        if report.isConnected {
            return Verdict(level: .working, label: "responde con datos",
                           headline: "Los cinco pasos pasan: una llamada real trae contenido.",
                           whatToDo: "")
        }
        guard let failure = report.firstFailure else {
            return Verdict(level: .unknown, label: "sin comprobar",
                           headline: "Todavía no se ha probado la conexión.",
                           whatToDo: "Pulsa «Comprobar de verdad» y se ejecutan los cinco pasos.")
        }
        return Verdict(level: .broken, label: shortFailure(failure.step),
                       headline: failure.outcome.reason ?? failure.step.title,
                       whatToDo: whatToDo(about: failure.step))
    }

    /// The pill wording per failing step. Deliberately never the word "conectado" and never a
    /// bare "error": it names the thing that is not happening, because "falla en el paso 4" sends
    /// nobody anywhere.
    public static func shortFailure(_ step: MCPHealth.Step) -> String {
        switch step {
        case .configured: "sin configurar"
        case .launched: "no arranca"
        case .handshake: "no contesta"
        case .toolsListed: "sin herramientas"
        case .toolCalled: "responde vacío"
        }
    }

    /// Each failure has exactly one fix, and it is different for every step. This is the whole
    /// reason the five checks are separate: one green dot could only ever say "algo va mal".
    public static func whatToDo(about step: MCPHealth.Step) -> String {
        switch step {
        case .configured:
            "Pulsa «Conectar» aquí al lado. Se añade la entrada a la configuración de esa app sin "
            + "tocar lo que ya tuviera."
        case .launched:
            "La ruta guardada en ese asistente ya no lleva a BeLauncher, normalmente porque la app "
            + "se movió de carpeta. Pulsa «Conectar» otra vez para escribir la ruta actual."
        case .handshake:
            "El proceso arranca pero no responde. Cierra el asistente, ábrelo de nuevo y vuelve a "
            + "comprobar. Si sigue igual, reinstala BeLauncher."
        case .toolsListed:
            "Esta versión arranca pero no anuncia ninguna herramienta. Actualiza BeLauncher desde "
            + "Ajustes › General."
        case .toolCalled:
            "La tubería funciona y el contenido no llega. Rehaz el índice en «Estado del cerebro» "
            + "y vuelve a comprobar; si sigue vacío, manda el diagnóstico."
        }
    }

    /// The one line above the client list. It answers "can I trust the row below" before anyone
    /// reads the rows.
    public static func summary(of reports: [MCPHealth.Report]) -> Verdict {
        guard !reports.isEmpty else {
            return Verdict(level: .unknown, label: "sin comprobar",
                           headline: "Nadie ha comprobado esta conexión todavía.",
                           whatToDo: "Pulsa «Comprobar de verdad»: arranca BeLauncher como lo "
                                   + "haría tu asistente y hace una pregunta real.")
        }
        let broken = reports.filter { !$0.isConnected }
        guard !broken.isEmpty else {
            let count = reports.count
            return Verdict(level: .working, label: "todo responde",
                           headline: "\(number(count)) \(count == 1 ? "asistente recibe" : "asistentes reciben") "
                                   + "datos de verdad.",
                           whatToDo: "")
        }
        let names = broken.map(\.clientName).joined(separator: ", ")
        return Verdict(level: .broken, label: "\(broken.count) sin datos",
                       headline: "No llega nada a: \(names).",
                       whatToDo: "Abre cada uno para ver en qué paso se corta.")
    }

    // MARK: - What pressing «Conectar» is allowed to claim

    /// Connecting writes a line into another app's configuration file. That is all it does, and
    /// that is all this says.
    ///
    /// The old message was "X ya puede consultar tu cerebro. Reinícialo para que lo vea" — the
    /// exact unverified claim the five-step probe exists to replace. A path in a JSON file does
    /// not prove the assistant launches it: the most common failure in the probe is `launched`,
    /// on machines whose config file said everything was fine.
    public static func connectWrote(client: String) -> String {
        "Escrita la configuración de \(client). Eso es lo único que se puede afirmar por ahora: "
        + "reinicia \(client) y pulsa «\(checkButton)» para ver si de verdad le llegan datos."
    }

    public static func connectAlreadyThere(client: String) -> String {
        "\(client) ya tenía la entrada de BeLauncher. Que el archivo la mencione no prueba que "
        + "reciba nada: pulsa «\(checkButton)» para comprobarlo."
    }

    /// The label on the button that runs the probe. It promises what it does, because the old
    /// button promised connection and delivered a file write.
    public static let checkButton = "Comprobar de verdad"
    public static let checkRunning = "Comprobando…"
    public static let checkExplanation =
        "Arranca BeLauncher igual que lo haría tu asistente, le hace una pregunta cuya respuesta "
        + "conocemos y comprueba que vuelva con contenido. No basta con que el archivo de "
        + "configuración nos mencione."
}
