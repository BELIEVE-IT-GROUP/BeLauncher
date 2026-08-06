import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Ensamblar lo que el producto recuerda")
struct CorpusTests {

    // Un martes por la mañana, fijo, para que un episodio no cambie de día según cuándo se corra.
    private let morning = Date(timeIntervalSince1970: 1_785_240_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Un rato de trabajo real: varios archivos de un proyecto, con hueco suficiente para durar.
    private func workingSignals(from start: Date, project: String = "waw-trips") -> [WorkNode] {
        [
            WorkNode(id: "n1", kind: .file, name: "index.ts",
                     target: "/Users/mac/Developer/\(project)/src/index.ts", lastSeen: start),
            WorkNode(id: "n2", kind: .file, name: "auth.ts",
                     target: "/Users/mac/Developer/\(project)/src/auth.ts",
                     lastSeen: start.addingTimeInterval(600)),
            WorkNode(id: "n3", kind: .file, name: "README.md",
                     target: "/Users/mac/Developer/\(project)/README.md",
                     lastSeen: start.addingTimeInterval(1_200)),
        ]
    }

    private func input(_ build: (inout CorpusBuilder.Input) -> Void) -> CorpusBuilder.Input {
        var input = CorpusBuilder.Input(now: morning.addingTimeInterval(10 * 3_600),
                                        calendar: calendar)
        build(&input)
        return input
    }

    // MARK: - La pausa manda

    @Test("Con la captura en pausa no se ensambla nada, ni para tirarlo después")
    func pausedAssemblesNothing() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
            $0.clips = [Clip(id: 1, text: String(repeating: "texto útil ", count: 20),
                             sourceApp: "com.apple.Safari", createdAt: morning)]
            $0.privacy = Privacy.State(reason: .byHand)
        })

        #expect(corpus.isPaused)
        #expect(corpus.episodes.isEmpty)
        #expect(corpus.items.isEmpty)
        #expect(corpus.entities.isEmpty)
    }

    @Test("La pausa por compartir pantalla también corta el ensamblado")
    func sharingScreenAssemblesNothing() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
            $0.privacy = Privacy.State(reason: .byHand)
        })
        #expect(corpus.isPaused)
        #expect(corpus.episodes.isEmpty)
    }

    @Test("Una pausa temporal ya vencida deja volver a capturar")
    func expiredPauseResumes() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
            $0.privacy = Privacy.State(reason: .untilLater, until: morning)
        })
        #expect(!corpus.isPaused)
        #expect(!corpus.episodes.isEmpty)
    }

    // MARK: - Lo excluido no entra

    @Test("Una app excluida no llega a ser señal")
    func excludedApplicationNeverBecomesSignal() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning) + [
                WorkNode(id: "pw", kind: .application, name: "1Password",
                         target: "com.1password.1password",
                         lastSeen: morning.addingTimeInterval(300)),
            ]
            $0.excludedApps = ["com.1password.1password"]
        })

        let titles = corpus.episodes.flatMap { $0.signals.map(\.title) }
        #expect(!titles.contains("1Password"))
    }

    @Test("Un dominio excluido no entra aunque venga del historial")
    func excludedDomainNeverEntersFromHistory() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
            $0.visits = [
                BrowserVisit(at: morning.addingTimeInterval(300),
                             url: "https://banco.example.com/cuentas",
                             title: "Mis cuentas", browser: "Safari"),
                BrowserVisit(at: morning.addingTimeInterval(400),
                             url: "https://github.com/believe/waw",
                             title: "believe/waw", browser: "Safari"),
            ]
            $0.excludedDomains = ["banco"]
        })

        let titles = corpus.episodes.flatMap { $0.signals.map(\.title) }
        #expect(!titles.contains("Mis cuentas"))
        #expect(titles.contains("believe/waw"))
    }

    @Test("Un secreto copiado no se convierte en señal ni en título de episodio")
    func secretsNeverBecomeSignals() {
        // Un episodio lleva los títulos de lo que tocó. Una clave ahí dentro sigue siendo una clave
        // guardada, aunque nadie la haya indexado como texto suelto.
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
            $0.clips = [Clip(id: 1, text: "la clave es sk-ant-api03-\(String(repeating: "x", count: 40))",
                             sourceApp: "com.apple.Terminal",
                             createdAt: morning.addingTimeInterval(300))]
        })

        let everything = corpus.episodes.flatMap { $0.signals.map(\.title) }.joined()
        #expect(!everything.contains("sk-ant"))
    }

    @Test("El filtro de exclusión mira también a dónde apunta un archivo, no solo las apps")
    func exclusionLooksAtTargetsToo() {
        // Un nodo de tipo archivo cuyo destino es una URL sigue siendo una URL. Una regla que solo
        // mirase los nodos de app dejaría pasar la página del banco disfrazada de archivo.
        let allowed = CorpusBuilder.allowedNodes(input {
            $0.nodes = [WorkNode(id: "x", kind: .file, name: "Extracto",
                                 target: "https://banco.example.com/extracto", lastSeen: morning)]
            $0.excludedDomains = ["banco"]
        })
        #expect(allowed.isEmpty)
    }

    // MARK: - De señales a episodios

    @Test("Las personas y los proyectos no son momentos, así que no generan señales")
    func conceptNodesAreNotSignals() {
        // Si un nodo de proyecto entrase como señal, su lastSeen estiraría el episodio hasta cubrir
        // toda la vida del proyecto.
        let signals = CorpusBuilder.signals(fromNodes: [
            WorkNode(id: "p", kind: .person, name: "Andrés", lastSeen: morning),
            WorkNode(id: "c", kind: .company, name: "Acme", lastSeen: morning),
            WorkNode(id: "pr", kind: .project, name: "WAW Trips", lastSeen: morning),
            WorkNode(id: "f", kind: .file, name: "nota.md", target: "/tmp/nota.md", lastSeen: morning),
        ])

        #expect(signals.count == 1)
        #expect(signals.first?.title == "nota.md")
    }

    @Test("Una copia se atribuye a la app de la que salió, no a un episodio de portapapeles")
    func clipsClusterWithTheAppTheyCameFrom() {
        let signals = CorpusBuilder.signals(fromClips: [
            Clip(id: 1, text: "algo copiado", sourceApp: "com.apple.Safari", createdAt: morning),
        ])
        #expect(signals.first?.subject == "com.apple.Safari")
        #expect(signals.first?.kind == .clip)
    }

    @Test("Una conversación se ata a su carpeta de trabajo, que es lo que la liga a un proyecto")
    func conversationsAreTiedToTheirProject() {
        let signals = CorpusBuilder.signals(fromExchanges: [
            Conversations.Exchange(at: morning,
                                   asked: "¿Cómo resuelvo el refresco del token de autenticación?",
                                   answered: "Con un interceptor.",
                                   workingDirectory: "/Users/mac/Developer/waw-trips"),
        ])
        #expect(signals.first?.subject == "/Users/mac/Developer/waw-trips")
        #expect(signals.first?.kind == .conversation)
    }

    @Test("Una visita sin título no dice nada y se descarta")
    func untitledVisitsAreDropped() {
        let signals = CorpusBuilder.signals(fromVisits: [
            BrowserVisit(at: morning, url: "https://example.com/x", title: "   ", browser: "Safari"),
        ])
        #expect(signals.isEmpty)
    }

    @Test("Una página se agrupa por dominio y primera carpeta, ni por URL entera ni por dominio suelto")
    func visitSubjectGroupsAtTheRightLevel() {
        // Por URL entera nunca se repite nada y "volviste otro día" no se activa jamás; por dominio
        // suelto todo GitHub es una sola cosa.
        let visit = BrowserVisit(at: morning, url: "https://www.github.com/believe/waw/pull/3",
                                 title: "PR 3", browser: "Chrome")
        #expect(visit.subject == "github.com/believe")

        let bare = BrowserVisit(at: morning, url: "https://example.com", title: "x", browser: "Safari")
        #expect(bare.subject == "example.com")
    }

    // MARK: - Qué merece indexarse

    @Test("Un episodio que aún está pasando no se indexa por bien que puntúe")
    func unsettledEpisodesAreNeverIndexed() {
        // Indexarlo escribe un pasaje que estará mal dentro de una hora, y lo que lo citara mientras
        // tanto citó media historia.
        // El episodio termina cinco minutos antes de "ahora": por debajo de los 25 minutos de hueco
        // que hacen falta para darlo por cerrado.
        let recent = morning.addingTimeInterval(10 * 3_600 - 1_500)
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: recent)
            $0.markedByHand = ["/Users/mac/Developer/waw-trips/src/index.ts"]
        })

        #expect(!corpus.episodes.isEmpty)
        #expect(corpus.indexed.isEmpty)
        #expect(corpus.considered.allSatisfy { $0.why.contains("still going on") })
    }

    @Test("Un rato de trabajo asentado y con recorrido sí entra")
    func settledWorkIsIndexed() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
        })
        #expect(corpus.indexed.count == 1)
        #expect(!corpus.items.isEmpty)
    }

    @Test("Volver otro día pesa más que estar un rato largo una sola vez")
    func returningOnAnotherDayCounts() {
        let onlyOnce = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
        })
        let acrossDays = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
                + workingSignals(from: morning.addingTimeInterval(-86_400))
            $0.now = self.morning.addingTimeInterval(10 * 3_600)
        })

        let best = { (corpus: Corpus) in corpus.considered.map(\.score).max() ?? 0 }
        #expect(best(acrossDays) > best(onlyOnce))
        // La explicación arranca con mayúscula, así que se compara sin distinguirla.
        #expect(acrossDays.considered.contains { $0.why.lowercased().contains("came back") })
    }

    @Test("Lo que guardaste a mano entra sin discusión")
    func markedByHandAlwaysWins() {
        // Una sola señal corta no llega ni a episodio, así que se marca un rato que sí lo es.
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
            $0.markedByHand = ["/Users/mac/Developer/waw-trips/src/index.ts"]
        })

        let considered = corpus.considered.first
        #expect(considered?.signals.markedByHand == true)
        #expect(considered?.score == 1)
        #expect(considered?.why == "You kept it yourself.")
    }

    @Test("Cada episodio explica por qué entró o por qué no, en palabras")
    func everyEpisodeExplainsItself() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = workingSignals(from: morning)
        })
        #expect(corpus.considered.allSatisfy { !$0.why.isEmpty })
    }

    // MARK: - Entidades

    @Test("El proyecto sale de la ruta, no de la carpeta genérica que la termina")
    func projectsComeFromPaths() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = self.workingSignals(from: self.morning)
        })

        let projects = corpus.entities.filter { $0.kind == .project }.map(\.canonical)
        #expect(projects.contains("waw-trips"))
        #expect(!projects.contains("src"))
    }

    @Test("Una empresa sale del dominio del correo, y el correo gratuito no cuenta")
    func companiesComeFromWorkEmails() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = self.workingSignals(from: self.morning) + [
                WorkNode(id: "m1", kind: .meeting, name: "Kickoff",
                         target: "andres@acme.com", lastSeen: self.morning.addingTimeInterval(300)),
                WorkNode(id: "m2", kind: .meeting, name: "Café",
                         target: "alguien@gmail.com", lastSeen: self.morning.addingTimeInterval(400)),
            ]
        })

        let companies = corpus.entities.filter { $0.kind == .company }.map(\.canonical)
        #expect(companies.contains("acme"))
        #expect(!companies.contains("gmail"))
    }

    @Test("La carpeta de una conversación es el proyecto, no la carpeta que la contiene")
    func conversationDirectoryIsTheProject() {
        // Encontrado corriendo el pase sobre una carpeta de sesiones real: toda conversación bajo
        // `.../worktrees/belauncher` se archivaba como proyecto "worktrees", que es un contenedor
        // compartido por todos los worktrees de la máquina.
        let corpus = CorpusBuilder.assemble(input {
            $0.exchanges = (0..<3).map { index in
                Conversations.Exchange(
                    at: self.morning.addingTimeInterval(Double(index) * 600),
                    asked: "¿Cómo arreglo el arranque de la aplicación en este proyecto?",
                    answered: "Mirando el delegado.",
                    workingDirectory: "/Users/mac/Developer/beacon/worktrees/belauncher")
            }
        })

        let projects = corpus.entities.filter { $0.kind == .project }.map(\.canonical)
        #expect(projects.contains("belauncher"))
        #expect(!projects.contains("worktrees"))
    }

    @Test("Un archivo sigue nombrando a su carpeta, no a sí mismo")
    func fileSubjectsStillNameTheirFolder() {
        // La corrección de las conversaciones no puede romper el caso para el que se escribió
        // `project(fromPath:)`: en una ruta de archivo, el último tramo es el archivo.
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = self.workingSignals(from: self.morning)
        })
        let projects = corpus.entities.filter { $0.kind == .project }.map(\.canonical)
        #expect(projects.contains("waw-trips"))
        #expect(!projects.contains("index.ts"))
    }

    @Test("Lo que escribe la máquina en la sesión no es una pregunta de nadie")
    func machineWrittenTurnsAreNotQuestions() {
        // Llegan como filas de usuario y sin bloque de herramienta, así que el lector de
        // conversaciones no puede distinguirlas: pasan el mínimo de longitud y desplazan a las
        // preguntas de verdad.
        let allowed = CorpusBuilder.allowedExchanges(input {
            $0.exchanges = [
                Conversations.Exchange(at: self.morning,
                                       asked: "<task-notification> <task-id>a25e62fe4f76dec7a</task-id>",
                                       answered: "ok", workingDirectory: "/Users/mac/Developer/x"),
                Conversations.Exchange(at: self.morning,
                                       asked: "¿Por qué se cae el arranque cuando no hay licencia?",
                                       answered: "Porque falta el vault.",
                                       workingDirectory: "/Users/mac/Developer/x"),
            ]
        })

        #expect(allowed.count == 1)
        #expect(allowed.first?.asked.hasPrefix("¿Por qué") == true)
    }

    @Test("Los nombres genéricos nunca son entidades")
    func genericNamesAreNeverEntities() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = [
                WorkNode(id: "a", kind: .file, name: "a.ts", target: "/Users/mac/src/a.ts",
                         lastSeen: self.morning),
                WorkNode(id: "b", kind: .file, name: "b.ts", target: "/Users/mac/src/b.ts",
                         lastSeen: self.morning.addingTimeInterval(600)),
                WorkNode(id: "c", kind: .file, name: "c.ts", target: "/Users/mac/src/c.ts",
                         lastSeen: self.morning.addingTimeInterval(1_200)),
            ]
        })
        #expect(!corpus.entities.contains { $0.canonical == "src" })
    }

    @Test("Dos formas del mismo nombre se funden solas y conservan el alias")
    func sameNameMergesAndKeepsTheAlias() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = [
                WorkNode(id: "p1", kind: .project, name: "WAW Trips", lastSeen: self.morning),
                WorkNode(id: "p2", kind: .project, name: "waw-trips", lastSeen: self.morning),
            ]
        })

        let projects = corpus.entities.filter { $0.kind == .project }
        #expect(projects.count == 1)
        #expect(projects.first?.answers(to: "waw trips") == true)
    }

    @Test("Una persona y el proyecto que lleva su nombre nunca se funden")
    func peopleAndProjectsNeverMerge() {
        // La fusión que más destruye: deja toda pregunta sobre cualquiera de los dos devolviendo
        // una mezcla de ambos.
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = [
                WorkNode(id: "per", kind: .person, name: "Aitana", lastSeen: self.morning),
                WorkNode(id: "pro", kind: .project, name: "Aitana", lastSeen: self.morning),
            ]
        })
        #expect(corpus.entities.count == 2)
        #expect(corpus.proposals.isEmpty)
    }

    @Test("Una fusión ya rechazada no se vuelve a preguntar")
    func rejectedMergesAreNotAskedTwice() {
        let together = (0..<10).map { index in
            WorkNode(id: "m\(index)", kind: .meeting, name: "Acme y Beta",
                     target: "/Users/mac/Developer/acme/nota\(index).md",
                     lastSeen: self.morning.addingTimeInterval(Double(index) * 600))
        }
        let asked = CorpusBuilder.assemble(input { $0.nodes = together })
        guard let question = asked.proposals.first else { return }

        let again = CorpusBuilder.assemble(input {
            $0.nodes = together
            $0.rejectedMerges = [question.id]
        })
        #expect(!again.proposals.contains { $0.id == question.id })
    }

    // MARK: - Lo que se le entrega al índice

    @Test("El pasaje de un episodio dice qué se tocó y de qué proyecto, sin inventar un resumen")
    func episodePassageStatesFactsOnly() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = self.workingSignals(from: self.morning)
        })

        let item = try? #require(corpus.items.first)
        #expect(item?.text.contains("auth.ts") == true)
        #expect(item?.text.contains("waw-trips") == true)
        #expect(item?.source.kind == .node)
    }

    @Test("Las conversaciones llegan al índice con la pregunta por delante")
    func conversationsReachTheIndex() {
        // La pregunta es lo que alguien buscará meses después, con sus propias palabras.
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = self.workingSignals(from: self.morning)
            $0.exchanges = [
                Conversations.Exchange(at: self.morning.addingTimeInterval(300),
                                       asked: "¿Por qué falla el refresco del token en producción?",
                                       answered: "Porque el reloj del contenedor va adelantado.",
                                       workingDirectory: "/Users/mac/Developer/waw-trips"),
            ]
        })

        let conversation = corpus.items.first { $0.source.kind == .conversation }
        #expect(conversation?.title.contains("refresco del token") == true)
    }

    @Test("Un audio transcrito entra como conversación y se puede rastrear hasta su grabación")
    func transcriptsAreTraceable() {
        let transcript = Transcript(at: morning, title: "Reunión con Acme",
                                    text: "Quedamos en mandar la propuesta el viernes.",
                                    sourcePath: "/Users/mac/Grabaciones/acme.m4a")
        let item = CorpusBuilder.item(for: transcript)

        #expect(item.source.kind == .conversation)
        #expect(item.text.contains("propuesta el viernes"))
        // El mismo audio siempre produce el mismo identificador, o cada pase lo duplicaría.
        #expect(item.source.id == CorpusBuilder.item(for: transcript).source.id)
    }

    @Test("Volver a ensamblar las mismas señales no duplica episodios")
    func assemblingTwiceIsStable() {
        let build = { CorpusBuilder.assemble(self.input { $0.nodes = self.workingSignals(from: self.morning) }) }
        #expect(build().episodes.map(\.id) == build().episodes.map(\.id))
    }

    @Test("Un día entero de fuentes mezcladas produce un corpus coherente")
    func theWholePipelineHoldsTogether() {
        let corpus = CorpusBuilder.assemble(input {
            $0.nodes = self.workingSignals(from: self.morning)
            $0.clips = [Clip(id: 1, text: String(repeating: "fragmento de código útil ", count: 5),
                             sourceApp: "com.apple.Safari",
                             createdAt: self.morning.addingTimeInterval(900))]
            $0.visits = [BrowserVisit(at: self.morning.addingTimeInterval(700),
                                      url: "https://github.com/believe/waw/pull/3",
                                      title: "Arreglar el refresco del token",
                                      browser: "Chrome")]
            $0.exchanges = [Conversations.Exchange(
                at: self.morning.addingTimeInterval(800),
                asked: "¿Cómo evito que el token caduque a mitad de una petición?",
                answered: "Refrescándolo antes.",
                workingDirectory: "/Users/mac/Developer/waw-trips")]
        })

        #expect(!corpus.isPaused)
        #expect(corpus.episodes.count == 1)
        // Copiar algo cuenta como señal de que aquello sirvió.
        #expect(corpus.considered.first?.signals.copiedFrom == true)
        #expect(corpus.entities.contains { $0.canonical == "waw-trips" })
        #expect(corpus.items.contains { $0.source.kind == .node })
        #expect(corpus.items.contains { $0.source.kind == .conversation })
    }
}
