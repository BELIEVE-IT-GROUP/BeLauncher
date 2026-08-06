import Testing
import Foundation
@testable import BeLauncherCore

/// Slash commands: unambiguous on purpose, because the alternative is firing an agent because
/// somebody typed a noun.
@Suite("Commands that are agents")
struct AgentCommandTests {

    static let commands = OutcomePack.builtIn.map(\.command)

    @Test("a slash command is recognised, and its argument comes through whole")
    func parses() throws {
        let parsed = try #require(AgentCommand.parse("/prepare Nike el viernes",
                                                     in: Self.commands))
        #expect(parsed.command.verb == "prepare")
        #expect(parsed.argument == "Nike el viernes")
    }

    @Test("without a slash nothing is a command, however much it looks like one")
    func requiresTheSlash() {
        #expect(AgentCommand.parse("prepare Nike", in: Self.commands) == nil)
        #expect(AgentCommand.parse("cierre", in: Self.commands) == nil)
        // Otherwise searching for the word "prepare" would launch an agent.
        #expect(AgentCommand.parse("/", in: Self.commands) == nil)
        #expect(AgentCommand.parse("/noexiste algo", in: Self.commands) == nil)
    }

    @Test("a lone slash lists everything, and typing narrows it")
    func suggests() {
        #expect(AgentCommand.suggestions(for: "/", in: Self.commands).count == Self.commands.count)
        let narrowed = AgentCommand.suggestions(for: "/pre", in: Self.commands)
        #expect(narrowed.allSatisfy { $0.verb.hasPrefix("pre") })
        // Once there is an argument it is a command being written, not a menu being browsed.
        #expect(AgentCommand.suggestions(for: "/prepare Nike", in: Self.commands).isEmpty)
    }

    @Test("accents and capitals never stop a command from being found")
    func foldsInput() throws {
        let parsed = try #require(AgentCommand.parse("/PREPARE Acme", in: Self.commands))
        #expect(parsed.command.verb == "prepare")
    }

    @Test("a command declares the permissions it needs, without repeating them")
    func declaresPermissions() {
        let command = AgentCommand(id: "x", verb: "x", title: "X", summary: "",
                                   reads: [.calendar, .screen, .selection, .clipboard])
        #expect(command.requiredPermissions == [.calendar, .accessibility])
    }
}

@Suite("Driving a run through its stages")
struct AgentDriverTests {

    static func run(reads: [AgentCommand.ContextSource] = [.clipboard]) -> AgentRun {
        AgentRun(command: AgentCommand(id: "x", verb: "x", title: "X", summary: "", reads: reads),
                 argument: "algo")
    }

    @Test("a missing permission stops it before anything is planned")
    func stopsOnPermission() {
        let stopped = AgentDriver.afterInspecting(Self.run(reads: [.calendar]), granted: { _ in false })
        #expect(stopped.stage == .awaitingPermission)
        #expect(stopped.missingPermission == .calendar)
    }

    @Test("with permission it moves on to planning")
    func proceeds() {
        let going = AgentDriver.afterInspecting(Self.run(reads: [.calendar]), granted: { _ in true })
        #expect(going.stage == .planning)
        #expect(going.missingPermission == nil)
    }

    @Test("anything that changes the world waits for approval")
    func destructiveWaits() {
        var planned = Self.run()
        planned.plan = [PlannedStep(title: "Vaciar la papelera",
                                    action: .systemCommand("emptyTrash"))]
        #expect(AgentDriver.afterPlanning(planned).stage == .awaitingApproval)
    }

    @Test("a harmless plan runs without asking")
    func harmlessRuns() {
        var planned = Self.run()
        planned.plan = [PlannedStep(title: "Copiar", action: .copyToClipboard(text: "x",
                                                                              cursorOffset: nil))]
        #expect(AgentDriver.afterPlanning(planned).stage == .executing)
    }

    @Test("a canvas always waits, because a canvas is a proposal")
    func canvasWaits() {
        var planned = Self.run()
        planned.canvas = CanvasTemplate.canvas(CanvasTemplate.all[0], brief: "x")
        #expect(AgentDriver.afterPlanning(planned).stage == .awaitingApproval)
    }

    @Test("an empty plan fails out loud instead of inventing something")
    func emptyPlanFails() {
        let failed = AgentDriver.afterPlanning(Self.run())
        #expect(failed.stage == .failed)
        #expect(failed.failure?.contains("Better to say so") == true)
    }

    @Test("approving only works from the stage that was waiting for it")
    func approvalIsNotABackDoor() {
        var running = Self.run()
        running.stage = .executing
        // Approving something already running must not restart it.
        #expect(AgentDriver.approve(running).stage == .executing)
    }

    @Test("a finished run cannot be cancelled back into life")
    func cancelIsFinal() {
        let done = AgentDriver.finish(Self.run(), result: "listo")
        #expect(AgentDriver.cancel(done).stage == .done)
    }

    @Test("what it learns is that the outcome was useful, never what was said")
    func learnsShapeNotContent() throws {
        let done = AgentDriver.finish(Self.run(), result: "el texto secreto del cliente")
        let lesson = try #require(AgentDriver.lesson(from: done))
        #expect(!lesson.trait.contains("secreto"))
        #expect(!lesson.value.contains("secreto"))
        // A run that failed teaches nothing.
        #expect(AgentDriver.lesson(from: AgentDriver.fail(Self.run(), "no")) == nil)
    }
}

@Suite("Canvases: pieces, not walls of text")
struct CanvasTests {

    @Test("every template produces blocks with something to ask for")
    func templatesAreComplete() {
        for definition in CanvasTemplate.all {
            #expect(!definition.blocks.isEmpty, "\(definition.id) no tiene bloques")
            for block in definition.blocks {
                #expect(block.instruction.count > 20,
                        "\(definition.id)/\(block.title) no dice qué pedir")
            }
        }
    }

    @Test("a fresh canvas is empty and knows it")
    func startsEmpty() {
        let canvas = CanvasTemplate.canvas(CanvasTemplate.all[0], brief: "MAAS")
        #expect(!canvas.isComplete)
        #expect(canvas.progress == 0)
        #expect(canvas.title.contains("MAAS"))
    }

    @Test("filling a block moves the progress, and an empty answer does not")
    func fillingCounts() {
        var canvas = CanvasTemplate.canvas(CanvasTemplate.all[0], brief: "x")
        let first = canvas.blocks[0].id
        canvas.fill(first, body: "  ")
        #expect(canvas.progress == 0, "una respuesta en blanco no es un bloque hecho")
        canvas.fill(first, body: "Gente que compra online")
        #expect(canvas.progress > 0)
    }

    @Test("regenerating never writes over what the person wrote")
    func handEditsWin() {
        var canvas = CanvasTemplate.canvas(CanvasTemplate.all[0], brief: "x")
        let first = canvas.blocks[0].id
        canvas.edit(first, body: "Esto lo puso la persona")
        canvas.fill(first, body: "Lo escribió el modelo")
        #expect(canvas.blocks[0].body == "Esto lo puso la persona",
                "pisar las palabras de alguien es como se pierde su confianza")
        #expect(canvas.blocks[0].editedByHand)
    }

    @Test("only ready action blocks are ever carried out")
    func onlyReadyActionsRun() {
        var canvas = Canvas(title: "t", brief: "b", blocks: [
            .init(kind: .action, title: "Crear carpeta", isReady: false,
                  action: .systemCommand("openHome")),
            .init(kind: .draft, title: "Texto", body: "algo", isReady: true),
        ])
        #expect(canvas.actions.isEmpty, "un paso a medias no se ejecuta")
        canvas.blocks[0].isReady = true
        #expect(canvas.actions.count == 1)
        #expect(canvas.actions.first?.changesSomething == true)
    }

    @Test("the instruction carries the brief, so every block answers the same question")
    func instructionsCarryTheBrief() throws {
        let definition = try #require(CanvasTemplate.named("proposal"))
        let prompt = try #require(CanvasTemplate.instruction(
            for: definition, blockTitle: "Problema", brief: "Nike quiere una tienda",
            context: "Ya trabajamos con ellos"
        ))
        #expect(prompt.contains("Nike quiere una tienda"))
        #expect(prompt.contains("Ya trabajamos con ellos"))
    }

    @Test("rendering gives something a person can paste somewhere else")
    func rendersReadably() {
        var canvas = CanvasTemplate.canvas(CanvasTemplate.all[1], brief: "Nike")
        canvas.fill(canvas.blocks[1].id, body: "No venden online.")
        let text = canvas.render()
        #expect(text.contains("## Problema"))
        #expect(text.contains("No venden online."))
        #expect(text.contains("_(empty)_"), "un hueco se ve como hueco, no se disimula")
    }
}

@Suite("A store of outcomes, not of plugins")
struct OutcomePackTests {

    @Test("every built-in pack says what you get, not which tool it uses")
    func packsSellOutcomes() {
        for pack in OutcomePack.builtIn {
            #expect(pack.outcome.count > 30, "\(pack.id) no explica qué te da")
            #expect(!pack.verb.isEmpty)
            #expect(pack.verb == pack.verb.lowercased(), "los verbos se escriben en minúscula")
            #expect(!pack.verb.contains(" "), "un verbo con espacio no se puede escribir tras «/»")
        }
    }

    @Test("no two built-in packs answer to the same slash command")
    func verbsAreUnique() {
        let verbs = OutcomePack.builtIn.map(\.verb)
        #expect(Set(verbs).count == verbs.count)
    }

    @Test("house rules end up in the instruction, or a shared pack changes nothing")
    func rulesReachTheModel() {
        let pack = OutcomePack(
            id: "x", name: "X", outcome: "algo", verb: "x",
            instruction: "Escribe una propuesta.",
            rules: [.init(name: "Tono", value: "directo, sin adjetivos de relleno")]
        )
        let instruction = pack.instruction(with: "para Nike")
        #expect(instruction.contains("directo, sin adjetivos"))
        #expect(instruction.contains("para Nike"))
        #expect(instruction.contains("not optional"))
    }

    @Test("a pack survives a round trip through a file")
    func encodesAndDecodes() throws {
        let data = try OutcomePack.encode(OutcomePack.builtIn)
        let back = try OutcomePack.decode(data)
        #expect(back.count == OutcomePack.builtIn.count)
        #expect(back.first?.verb == OutcomePack.builtIn.first?.verb)
    }

    @Test("a pack from a newer version is refused instead of half-read")
    func refusesTheFuture() throws {
        var pack = OutcomePack.builtIn[0]
        pack.version = OutcomePack.currentVersion + 5
        let data = try OutcomePack.encode([pack])
        #expect(throws: PackError.unsupportedVersion(OutcomePack.currentVersion + 5)) {
            try OutcomePack.decode(data)
        }
    }

    @Test("junk is refused as junk")
    func refusesJunk() {
        #expect(throws: PackError.malformed) {
            try OutcomePack.decode(Data("no soy un paquete".utf8))
        }
    }

    @Test("two commands with the same name are a collision, not a merge")
    func detectsCollisions() {
        let mine = OutcomePack.builtIn[0]
        var theirs = OutcomePack.builtIn[0]
        theirs = OutcomePack(id: "other", name: "Otro", outcome: "otra cosa", verb: mine.verb)
        let conflicts = OutcomePack.conflicts([theirs], with: [mine])
        #expect(conflicts == [.verbTaken(mine.verb)])
    }
}

@Suite("Work that runs while you do something else")
struct MissionTrayTests {

    @Test("the badge counts only what is waiting on you")
    func badgeMeansAttention() {
        var tray = MissionTray()
        tray.add(TrayMission(intent: "a", state: .working))
        tray.add(TrayMission(intent: "b", state: .needsDecision))
        tray.add(TrayMission(intent: "c", state: .awaitingPermission))
        tray.add(TrayMission(intent: "d", state: .completed))
        #expect(tray.attentionCount == 2,
                "contar lo que ya trabaja solo enseña a ignorar el contador")
    }

    @Test("only so many run at once")
    func concurrencyIsBounded() {
        var tray = MissionTray()
        for index in 0..<MissionTray.concurrencyLimit {
            tray.add(TrayMission(intent: "\(index)", state: .working))
        }
        #expect(!tray.canStartAnother)
        tray.cancel(tray.missions[0].id)
        #expect(tray.canStartAnother)
    }

    @Test("finishing stamps the time exactly once")
    func stampsFinish() throws {
        var tray = MissionTray()
        let mission = TrayMission(intent: "a")
        tray.add(mission)
        tray.update(mission.id) { $0.state = .completed }
        let first = try #require(tray.missions[0].finishedAt)
        tray.update(mission.id) { $0.result = "algo" }
        #expect(tray.missions[0].finishedAt == first)
    }

    @Test("a finished mission cannot be cancelled")
    func cancelDoesNotResurrect() {
        var tray = MissionTray()
        let mission = TrayMission(intent: "a", state: .completed)
        tray.add(mission)
        tray.cancel(mission.id)
        #expect(tray.missions[0].state == .completed)
    }

    @Test("clearing keeps whatever is still running")
    func clearingIsSafe() {
        var tray = MissionTray()
        tray.add(TrayMission(intent: "hecho", state: .completed))
        tray.add(TrayMission(intent: "en marcha", state: .working))
        tray.clearFinished()
        #expect(tray.missions.map(\.intent) == ["en marcha"])
    }

    @Test("the receipt carries the six things a mission owes you")
    func receiptIsComplete() {
        let mission = TrayMission(
            intent: "Investiga alternativas", state: .completed,
            plan: [PlannedStep(title: "Buscar", action: .dismiss)],
            sources: [.init(title: "la web", detail: "3 páginas")],
            performed: ["Leyó 3 páginas"], tokensUsed: 1_200,
            permissionsUsed: ["calendar"], result: "Comparativa",
            undoable: [UndoableStep(kind: .restoreClipboard, target: "",
                                    label: "Recuperar el portapapeles")]
        )
        let receipt = mission.receipt()
        for expected in ["## Plan", "## Where it came from", "## What it did", "## Cost",
                         "## Permissions used", "## Can be undone", "## Result"] {
            #expect(receipt.contains(expected), "al recibo le falta \(expected)")
        }
        #expect(receipt.contains("1200 tokens"))
    }

    @Test("a local model costs nothing, and the receipt says so plainly")
    func localCostsNothing() {
        let mission = TrayMission(intent: "x", state: .completed)
        #expect(mission.receipt().contains("done with a local model"))
    }
}

@Suite("Turning a habit into a command")
struct AutopilotTests {

    static func log(_ signatures: [String]) -> [LoggedAction] {
        signatures.enumerated().map { index, signature in
            LoggedAction(id: Int64(index), signature: signature,
                         label: signature.replacingOccurrences(of: "app:", with: "Abrir "),
                         at: Date().addingTimeInterval(Double(index)))
        }
    }

    @Test("a sequence repeated four times is offered, three times is not")
    func onlyOffersRealHabits() {
        let three = Self.log(Array(repeating: ["app:A", "app:B", "app:C"], count: 3).flatMap { $0 })
        #expect(Autopilot.recipes(from: three, alreadyOffered: { _ in false }).isEmpty,
                "tres veces es coincidencia lo bastante a menudo como para molestar")

        let four = Self.log(Array(repeating: ["app:A", "app:B", "app:C"], count: 4).flatMap { $0 })
        #expect(!Autopilot.recipes(from: four, alreadyOffered: { _ in false }).isEmpty)
    }

    @Test("something already refused is never offered again")
    func respectsARefusal() {
        let log = Self.log(Array(repeating: ["app:A", "app:B", "app:C"], count: 5).flatMap { $0 })
        #expect(Autopilot.recipes(from: log, alreadyOffered: { _ in true }).isEmpty)
    }

    @Test("the suggested name is something a person could guess and type")
    func namesAreTypeable() {
        let keyword = Autopilot.keyword(for: ["Abrir Notion", "Abrir Terminal"])
        #expect(!keyword.isEmpty)
        #expect(!keyword.contains(" "))
        #expect(keyword == keyword.lowercased())
        #expect(keyword != "rutina", "un nombre genérico es un comando que nadie ejecuta")
    }

    @Test("a habit becomes a flow whose steps the app can actually replay")
    func buildsARunnableFlow() {
        let recipe = Autopilot.Recipe(
            steps: ["app:/Applications/Notion.app", "system:toggleDoNotDisturb",
                    "url:https://linear.app"],
            labels: ["Abrir Notion", "No molestar", "Abrir Linear"], times: 4,
            suggestedKeyword: "notion-molestar"
        )
        let flow = Autopilot.flow(from: recipe)
        #expect(flow.steps.count == 3)
        #expect(flow.keyword == "notion-molestar")
    }

    @Test("a step the app cannot replay is dropped, never faked")
    func dropsWhatItCannotDo() {
        let recipe = Autopilot.Recipe(steps: ["app:/A.app", "misterio:algo", "flow:otra"],
                                      labels: ["A", "?", "otra"], times: 4,
                                      suggestedKeyword: "x")
        // A flow inside a flow is a loop waiting to happen, and an unknown kind is not guessable.
        #expect(Autopilot.flow(from: recipe).steps.count == 1)
    }

    @Test("the signatures the app writes are the ones the detector reads")
    func signaturesMatch() {
        #expect(Autopilot.signature(forApplication: "/A.app") == "app:/A.app")
        #expect(Autopilot.signature(forSystemCommand: "lock") == "system:lock")
        // The whole feature dies quietly if these two ever disagree.
        #expect(Autopilot.step(from: Autopilot.signature(forSystemCommand: "lockScreen"))
                == .systemCommand(kind: "lockScreen"))
    }
}

@Suite("Learning how this person works")
struct OperatingModelTests {

    @Test("a trait steers nothing until enough observations agree")
    func needsEvidence() {
        var trait = OperatingModel.fold(nil, named: "writing.length", observing: "corto")
        #expect(!trait.isUsable, "una sola observación no es un estilo")
        for _ in 0..<4 {
            trait = OperatingModel.fold(trait, named: "writing.length", observing: "corto")
        }
        #expect(trait.isUsable)
    }

    @Test("being contradicted lowers confidence, and enough contradiction flips it")
    func changesWithThePerson() {
        var trait = Trait(name: "writing.length", value: "largo", confidence: 0.9, observations: 8)
        for _ in 0..<4 {
            trait = OperatingModel.fold(trait, named: trait.name, observing: "corto")
        }
        #expect(trait.value == "corto", "la gente cambia; un modelo que no puede cambiar se queda mal")
    }

    @Test("an edit that cuts the draft in half says «escribe corto»")
    func learnsFromEdits() {
        let before = String(repeating: "palabra ", count: 60)
        let after = String(repeating: "palabra ", count: 15)
        let observed = OperatingModel.observeEdit(before: before, after: after)
        #expect(observed.contains { $0.name == "writing.length" && $0.value == "corto" })
    }

    @Test("greetings are noticed, because everyone has a firm opinion about them")
    func noticesGreetings() {
        let withGreeting = OperatingModel.observeWriting(
            "Hola Andrés, te escribo para contarte cómo va el proyecto y qué necesitamos ahora.")
        #expect(withGreeting.contains { $0.name == "writing.greeting" && $0.value == "some" })

        let without = OperatingModel.observeWriting(
            "El proyecto va bien. Necesitamos los accesos antes del viernes para seguir avanzando.")
        #expect(without.contains { $0.name == "writing.greeting" && $0.value == "none" })
    }

    @Test("how you name files is learned from the names you use")
    func learnsFilenames() {
        #expect(OperatingModel.observeFilename("propuesta-nike-2026.pdf")
            .contains { $0.value == "con-guiones" })
        #expect(OperatingModel.observeFilename("Propuesta Nike.pdf")
            .contains { $0.value == "con espacios" })
        #expect(OperatingModel.observeFilename("a.pdf").isEmpty, "un nombre de tres letras no dice nada")
    }

    @Test("only settled traits reach the model")
    func halfLearnedTraitsStayOut() {
        let unsure = Trait(name: "writing.length", value: "corto", confidence: 0.5, observations: 2)
        #expect(OperatingModel.systemPrompt(from: [unsure]).isEmpty,
                "una preferencia a medias dirigiendo el trabajo es peor que ninguna")

        let settled = Trait(name: "writing.length", value: "corto", confidence: 0.9, observations: 6)
        #expect(OperatingModel.systemPrompt(from: [settled]).contains("short"))
    }

    @Test("every trait can be explained in a sentence the person would recognise")
    func traitsAreExplainable() {
        for name in ["writing.length", "writing.formality", "writing.greeting", "files.naming"] {
            let trait = Trait(name: name, value: "corto", confidence: 1, observations: 9)
            #expect(trait.explanation.count > 12)
            #expect(!trait.explanation.contains(name),
                    "si hay que enseñar la clave interna, no está explicado")
        }
    }

    @Test("urgency is this person's idea of urgent, not a general one")
    func urgencyIsPersonal() {
        let trait = Trait(name: "priority.urgent", value: "factura, contrato",
                          confidence: 0.9, observations: 8)
        #expect(OperatingModel.isUrgent("llegó la factura de marzo", traits: [trait]))
        #expect(!OperatingModel.isUrgent("comida el jueves", traits: [trait]))
        // Without evidence it never guesses.
        #expect(!OperatingModel.isUrgent("factura", traits: []))
    }
}

@Suite("Reading what is on screen")
struct ScreenReaderTests {

    @Test("an error is recognised as an error")
    func recognisesErrors() {
        let context = ScreenContext(text: "Traceback (most recent call last):\nTypeError: x",
                                    origin: .selection)
        #expect(ScreenReader.subject(of: context) == .error)
    }

    @Test("an invoice needs more than one clue, so a mention of VAT is not an invoice")
    func invoicesNeedTwoSignals() {
        let one = ScreenContext(text: "Aquí hablamos del IVA en general y de nada más",
                                origin: .selection)
        #expect(ScreenReader.subject(of: one) != .invoice)

        let real = ScreenContext(text: "Factura Nº 22\nSubtotal 100\nIVA 21\nTotal a pagar 121",
                                 origin: .recognised)
        #expect(ScreenReader.subject(of: real) == .invoice)
    }

    @Test("a table is rows that repeat, not two lines with a pipe")
    func tablesNeedRows() {
        let short = ScreenContext(text: "a | b\nc | d", origin: .selection)
        #expect(ScreenReader.subject(of: short) != .table)

        let real = ScreenContext(text: (0..<6).map { "col\($0) | val\($0) | otro" }
            .joined(separator: "\n"), origin: .selection)
        #expect(ScreenReader.subject(of: real) == .table)
    }

    @Test("a design file is recognised from the file, not from its text")
    func designsComeFromTheFile() {
        let context = ScreenContext(text: "pantalla.fig", origin: .file, path: "/x/pantalla.fig")
        #expect(ScreenReader.subject(of: context) == .design)
    }

    @Test("every subject offers exactly three things, never a menu")
    func alwaysThreeOffers() {
        for subject in ScreenReader.Subject.allCases {
            let offers = ScreenReader.offers(for: subject)
            #expect(offers.count == 3, "\(subject) ofrece \(offers.count)")
            #expect(Set(offers.map(\.id)).count == 3)
        }
    }

    @Test("scraps of interface are never worth offering to work on")
    func ignoresNoise() {
        #expect(!ScreenReader.isWorthOffering(ScreenContext(text: "Archivo", origin: .recognised)))
        #expect(!ScreenReader.isWorthOffering(ScreenContext(text: "", origin: .selection)))
        #expect(!ScreenReader.isWorthOffering(
            ScreenContext(text: "unapalabramuylargaperounasola", origin: .recognised)))
        #expect(ScreenReader.isWorthOffering(
            ScreenContext(text: "esto sí es una frase entera", origin: .selection)))
        // A file is always worth offering, whatever its name.
        #expect(ScreenReader.isWorthOffering(ScreenContext(text: "a", origin: .file, path: "/a.pdf")))
    }

    @Test("offers that are not ordinary verbs carry their own instruction")
    func customVerbsAreDefined() {
        let verbs = Set(ScreenReader.Subject.allCases.flatMap(ScreenReader.offers).map(\.verb))
        let handledElsewhere: Set<String> = ["open", "remember", "search-web"]
        for verb in verbs where !handledElsewhere.contains(verb) {
            let known = AIVerb.named(verb) != nil || ScreenReader.instruction(for: verb) != nil
            #expect(known, "«\(verb)» se ofrece y no sabe hacer nada")
        }
    }
}

@Suite("Sharing commands, not only memory")
struct TeamCommandTests {

    static func bundle(packs: [OutcomePack] = [], flows: [Flow] = [],
                       standards: [OutcomePack.Rule] = []) -> TeamBrain.Bundle {
        TeamBrain.Bundle(team: "Believe", exportedBy: "jorge", objects: [], members: [],
                         packs: packs, flows: flows, standards: standards)
    }

    @Test("the team's standards travel with every command they share")
    func standardsReachTheCommands() throws {
        let pack = OutcomePack(id: "p", name: "Propuesta", outcome: "una propuesta", verb: "prop")
        let merge = TeamBrain.planCommands(
            Self.bundle(packs: [pack],
                        standards: [.init(name: "Tono", value: "directo")]),
            installedPacks: [], flows: [], snippets: []
        )
        let shared = try #require(merge.packs.first)
        #expect(shared.rules.contains { $0.name == "Tono" },
                "sin las reglas, un comando compartido es solo un nombre compartido")
    }

    @Test("a command whose name you already use is refused, not merged")
    func refusesCollisions() {
        let mine = OutcomePack(id: "mine", name: "Mío", outcome: "lo mío", verb: "prop")
        let theirs = OutcomePack(id: "theirs", name: "Suyo", outcome: "lo suyo", verb: "prop")
        let merge = TeamBrain.planCommands(Self.bundle(packs: [theirs]),
                                           installedPacks: [mine], flows: [], snippets: [])
        #expect(merge.packs.isEmpty)
        #expect(merge.refused == ["/prop"])
    }

    @Test("a flow of your own is never replaced by a colleague's")
    func yoursAlwaysWins() {
        let mine = Flow(id: 1, keyword: "enfoque", title: "El mío", steps: [.wait(seconds: 1)])
        let theirs = Flow(id: 0, keyword: "enfoque", title: "El suyo", steps: [.wait(seconds: 2)])
        let merge = TeamBrain.planCommands(Self.bundle(flows: [theirs]),
                                           installedPacks: [], flows: [mine], snippets: [])
        #expect(merge.flows.isEmpty)
        #expect(merge.refused == ["enfoque"])
    }

    @Test("an update to a command you already have from them is not a collision")
    func updatesAreAllowed() {
        let installed = OutcomePack(id: "same", name: "V1", outcome: "algo", verb: "prop")
        let updated = OutcomePack(id: "same", name: "V2", outcome: "algo mejor", verb: "prop")
        let merge = TeamBrain.planCommands(Self.bundle(packs: [updated]),
                                           installedPacks: [installed], flows: [], snippets: [])
        #expect(merge.packs.first?.name == "V2")
        #expect(merge.refused.isEmpty)
    }
}
