import Foundation

/// Intent, executed: you say what you want, the app works out the steps, shows them, and only
/// then does anything.
///
/// The trust model is the feature, not a wrapper around it. Every mission has a plan you can read
/// before it runs, a receipt of what it actually did, and an undo where undoing is possible. An
/// agent that acts on your Mac without those three is a demo, not a product.
public struct Mission: Sendable, Equatable, Identifiable {

    public enum State: String, Sendable, Equatable {
        case planning
        /// Waiting for the person to approve the plan.
        case awaitingApproval
        case running
        case done
        case failed
        case cancelled
    }

    public var id: String
    public var intent: String
    public var state: State
    public var steps: [PlannedStep]
    public var createdAt: Date
    public var finishedAt: Date?
    public var failure: String?

    public init(id: String = UUID().uuidString, intent: String, state: State = .planning,
                steps: [PlannedStep] = [], createdAt: Date = .now, finishedAt: Date? = nil,
                failure: String? = nil) {
        self.id = id
        self.intent = intent
        self.state = state
        self.steps = steps
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.failure = failure
    }

    /// A mission needs approval when any step changes something outside the app.
    public var needsApproval: Bool {
        steps.contains { $0.action.changesSomething }
    }

    public var summary: String {
        steps.map(\.title).joined(separator: " → ")
    }
}

public struct PlannedStep: Sendable, Equatable, Identifiable {
    public enum Outcome: String, Sendable, Equatable {
        case pending
        case done
        case skipped
        case failed
    }

    public var id: String
    public var title: String
    public var action: LauncherModel.Action
    public var outcome: Outcome
    public var detail: String

    public init(id: String = UUID().uuidString, title: String, action: LauncherModel.Action,
                outcome: Outcome = .pending, detail: String = "") {
        self.id = id
        self.title = title
        self.action = action
        self.outcome = outcome
        self.detail = detail
    }
}

extension LauncherModel.Action {
    /// Whether carrying this out changes something the user would notice afterwards. Anything
    /// that does forces a mission to ask first.
    public var changesSomething: Bool {
        switch self {
        case .copyToClipboard, .openURL, .openFile, .revealInFinder, .launchApplication,
             .quickLook, .openWith, .dismiss, .wait, .openSettings, .runVerb, .openCanvas,
             .runAgent:
            // An agent asks before it touches anything; handing it the job changes nothing yet.
            // A canvas is a proposal on screen. Nothing outside the app moves until the person
            // runs one of its blocks.
            return false
        case .moveToTrash, .systemCommand, .runShortcut, .startTimer, .arrangeWindow,
             .remember, .confirmCommit, .discardCommit, .runFlow, .assignAlias, .runMission,
             .quitProcess, .forceQuit, .stayAwake, .writeNote, .saveWorkspace, .restoreWorkspace:
            return true
        case .missionCancelled, .cancelAI:
            return false
        }
    }

    /// What a receipt says this step did.
    public var receiptLine: String {
        switch self {
        case .launchApplication(let path): "Abrir \((path as NSString).lastPathComponent)"
        case .openURL(let url): "Abrir \(url.host() ?? url.absoluteString)"
        case .openFile(let path): "Abrir \((path as NSString).lastPathComponent)"
        case .revealInFinder(let path): "Mostrar \((path as NSString).lastPathComponent)"
        case .copyToClipboard(let text, _): "Copiar \(text.count) caracteres"
        case .moveToTrash(let path): "Mover a la papelera \((path as NSString).lastPathComponent)"
        case .systemCommand(let kind): "Comando del sistema: \(kind)"
        case .runShortcut(let name): "Ejecutar el atajo “\(name)”"
        case .startTimer(let minutes, _): "Temporizador de \(minutes) min"
        case .arrangeWindow(let layout): "Colocar la ventana: \(layout)"
        case .remember(let text, _): "Proponer memoria: \(text.prefix(40))"
        case .confirmCommit: "Confirmar una memoria"
        case .discardCommit: "Descartar una propuesta"
        case .runFlow(let steps): "Ejecutar un flujo de \(steps.count) pasos"
        case .runVerb(let id, _): "Pedir a la IA: \(id)"
        case .quickLook: "Vista rápida"
        case .openWith: "Abrir con otra app"
        case .openSettings: "Abrir ajustes"
        case .wait(let seconds): "Esperar \(Int(seconds))s"
        case .assignAlias(_, let suggestion): "Asignar un alias a \(suggestion)"
        case .runMission(let mission): "Ejecutar la misión “\(mission.intent)”"
        case .missionCancelled: "Misión cancelada"
        case .cancelAI: "Petición cancelada"
        case .quitProcess(let pid): "Cerrar el proceso \(pid)"
        case .forceQuit(let pid): "Forzar la salida del proceso \(pid)"
        case .stayAwake(let minutes):
            minutes.map { "Mantener despierto \($0) min" } ?? "Mantener despierto"
        case .writeNote(let text): "Guardar una nota: \(text.prefix(40))"
        case .saveWorkspace(let name): "Guardar el reparto de ventanas «\(name)»"
        case .restoreWorkspace(let name): "Colocar el reparto «\(name)»"
        case .openCanvas(_, let brief): "Abrir un lienzo: \(brief.prefix(40))"
        case .runAgent(let id, _): "Encargar «\(id)»"
        case .dismiss: "Cerrar la ventana"
        }
    }
}

/// What a mission actually did, written after the fact.
///
/// Boring until it prevents a disaster, and then it is the reason people trust the thing. It says
/// what was asked, what ran, what changed and what can be undone — never a summary written by the
/// same model that did the work.
public struct MissionReceipt: Sendable, Equatable {
    public let missionID: String
    public let intent: String
    public let requestedBy: String
    public let startedAt: Date
    public let finishedAt: Date
    public let lines: [String]
    public let changed: [String]
    public let undoable: [String]

    public init(missionID: String, intent: String, requestedBy: String, startedAt: Date,
                finishedAt: Date, lines: [String], changed: [String], undoable: [String]) {
        self.missionID = missionID
        self.intent = intent
        self.requestedBy = requestedBy
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lines = lines
        self.changed = changed
        self.undoable = undoable
    }

    public static func of(_ mission: Mission, requestedBy: String) -> MissionReceipt {
        let done = mission.steps.filter { $0.outcome == .done }
        return MissionReceipt(
            missionID: mission.id,
            intent: mission.intent,
            requestedBy: requestedBy,
            startedAt: mission.createdAt,
            finishedAt: mission.finishedAt ?? .now,
            lines: mission.steps.map { step in
                "\(symbol(step.outcome)) \(step.title)"
                    + (step.detail.isEmpty ? "" : " — \(step.detail)")
            },
            changed: done.filter { $0.action.changesSomething }.map { $0.action.receiptLine },
            undoable: done.compactMap { step in
                if case .moveToTrash(let path) = step.action {
                    return "Recuperar \((path as NSString).lastPathComponent) de la papelera"
                }
                if case .confirmCommit = step.action { return "Revertir la memoria confirmada" }
                return nil
            }
        )
    }

    static func symbol(_ outcome: PlannedStep.Outcome) -> String {
        switch outcome {
        case .pending: "·"
        case .done: "✓"
        case .skipped: "–"
        case .failed: "✗"
        }
    }

    public func render() -> String {
        var text = ["# \(intent)", "", "Pedido por \(requestedBy)", ""]
        text += lines
        if !changed.isEmpty {
            text += ["", "Cambió:"] + changed.map { "- \($0)" }
        }
        if !undoable.isEmpty {
            text += ["", "Se puede deshacer:"] + undoable.map { "- \($0)" }
        }
        return text.joined(separator: "\n")
    }
}

/// Turns an intent into a plan, from a closed catalogue of outcomes.
///
/// Five things done well rather than a universal agent done badly. Each outcome is a named recipe
/// the app knows how to carry out; the model, when there is one, only fills in the blanks.
public enum MissionPlanner {

    public struct Outcome: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let triggers: [String]
        public let describe: @Sendable (String) -> String

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool { lhs.id == rhs.id }

        public init(id: String, title: String, triggers: [String],
                    describe: @escaping @Sendable (String) -> String) {
            self.id = id
            self.title = title
            self.triggers = triggers
            self.describe = describe
        }
    }

    /// What the app knows how to get done.
    ///
    /// Every one of these is an *outcome*, phrased the way someone would say it out loud, never the
    /// name of a tool. "Organiza mis descargas", not "abre Finder". The catalogue is closed on
    /// purpose: nine things it does properly beats a universal agent that produces something
    /// plausible for anything and something useful for nothing.
    public static let outcomes: [Outcome] = [
        .init(id: "focus", title: "Ponerme a trabajar",
              triggers: ["enfoque", "concentrar", "focus", "ponerme a trabajar"],
              describe: { _ in "Silencia, abre lo tuyo y arranca un bloque de trabajo." }),
        .init(id: "close-day", title: "Cerrar el día",
              triggers: ["cerrar el dia", "cerrar dia", "close my day"],
              describe: { _ in "Repasa lo pendiente y guarda lo aprendido." }),
        .init(id: "capture-meeting", title: "Convertir notas en memoria",
              triggers: ["guardar notas", "capturar reunion", "capture meeting"],
              describe: { _ in "Saca decisiones y compromisos de tus notas y los propone." }),
        .init(id: "tidy-downloads", title: "Ordenar las descargas",
              triggers: ["ordenar descargas", "limpiar descargas", "organiza mis descargas",
                         "tidy downloads"],
              describe: { _ in "Enseña qué hay y te deja moverlo o tirarlo." }),
        .init(id: "make-proposal", title: "Convertir esto en una propuesta",
              triggers: ["convierte esto en una propuesta", "haz una propuesta",
                         "convertir en propuesta", "make a proposal"],
              describe: { subject in
                  subject.isEmpty
                      ? "Monta la propuesta con lo que tengas copiado."
                      : "Monta la propuesta para \(subject)."
              }),
        .init(id: "answer-urgent", title: "Responder lo urgente",
              triggers: ["responde lo urgente", "responder lo urgente", "que es urgente",
                         "answer what is urgent"],
              describe: { _ in "Mira qué está vencido o a punto y te dice por dónde empezar." }),
        .init(id: "publish-idea", title: "Publicar esta idea",
              triggers: ["publica esta idea", "publicar esta idea", "publish this"],
              describe: { _ in "Convierte la nota en algo publicable y te lo deja copiado." }),
        .init(id: "clean-desktop", title: "Limpiar el escritorio",
              triggers: ["limpia el escritorio", "limpiar escritorio", "clean desktop"],
              describe: { _ in "Abre el escritorio para que veas qué sobra." }),
        .init(id: "start-week", title: "Arrancar la semana",
              triggers: ["arrancar la semana", "empezar la semana", "start my week"],
              describe: { _ in "Repasa compromisos abiertos y lo que se está pudriendo." }),
    ]

    public static func outcome(for intent: String) -> (outcome: Outcome, argument: String)? {
        let folded = intent.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                    locale: .current)
        for outcome in outcomes {
            for trigger in outcome.triggers where folded.contains(trigger) {
                let argument = folded
                    .replacingOccurrences(of: trigger, with: "")
                    .trimmingCharacters(in: .whitespaces)
                return (outcome, argument)
            }
        }
        return nil
    }

    /// Builds the plan for an intent. Returns nil when nothing in the catalogue fits, which is
    /// the honest answer: better no mission than a made-up one.
    public static func plan(_ intent: String, clipboard: String = "") -> Mission? {
        guard let (outcome, argument) = outcome(for: intent) else { return nil }

        var steps: [PlannedStep] = []
        switch outcome.id {
        case "focus":
            steps = [
                .init(title: "Activar No molestar",
                      action: .systemCommand(SystemCommand.Kind.toggleDoNotDisturb.rawValue)),
                .init(title: "Temporizador de 50 minutos",
                      action: .startTimer(minutes: 50, label: "Bloque de enfoque")),
            ]

        case "close-day":
            steps = [
                .init(title: "Sacar lo pendiente de hoy",
                      action: .runVerb(id: "extract-tasks", text: clipboard)),
                .init(title: "Proponerlo como memoria",
                      action: .remember(text: clipboard, source: "Cierre del día")),
            ]

        case "capture-meeting":
            steps = [
                .init(title: "Sacar decisiones y compromisos",
                      action: .runVerb(id: "extract-tasks", text: clipboard)),
                .init(title: "Proponerlas al cerebro",
                      action: .remember(text: clipboard, source: "Notas de reunión")),
            ]

        case "tidy-downloads":
            steps = [
                .init(title: "Abrir Descargas",
                      action: .systemCommand(SystemCommand.Kind.openDownloads.rawValue)),
            ]

        case "make-proposal":
            // A proposal is not one answer, it is six pieces, so this opens a canvas rather than
            // producing a wall of text nobody can edit piece by piece.
            steps = [
                .init(title: "Montar la propuesta",
                      action: .openCanvas(template: "proposal", brief: argument.isEmpty
                          ? clipboard : argument)),
            ]

        case "answer-urgent":
            steps = [
                .init(title: "Mirar qué está vencido o a punto",
                      action: .runVerb(id: "extract-tasks", text: clipboard)),
            ]

        case "publish-idea":
            steps = [
                .init(title: "Convertirlo en algo publicable",
                      action: .runVerb(id: "publish", text: clipboard)),
            ]

        case "clean-desktop":
            steps = [
                .init(title: "Abrir el escritorio",
                      action: .systemCommand(SystemCommand.Kind.openDesktop.rawValue)),
            ]

        case "start-week":
            steps = [
                .init(title: "Repasar lo que se está pudriendo",
                      action: .runVerb(id: "week-review", text: clipboard)),
            ]

        default:
            return nil
        }

        return Mission(intent: intent,
                       state: steps.contains { $0.action.changesSomething } ? .awaitingApproval : .running,
                       steps: steps)
    }
}
