import Testing
import Foundation
@testable import BeLauncherCore

@Suite("El corpus en Markdown")
struct CorpusFilesTests {

    /// Un mediodía fijo. Una prueba que depende de la hora del sistema falla de madrugada y pasa
    /// por la tarde, que es el peor rojo posible: enseña a reintentar en vez de a mirar.
    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    private func episode() -> Episode {
        let signals = [
            Episode.Signal(at: noon, kind: .file, subject: "auth.swift", title: "auth.swift"),
            Episode.Signal(at: noon.addingTimeInterval(600), kind: .conversation,
                           subject: "chat:1", title: "Cómo cerrar la sesión"),
            Episode.Signal(at: noon.addingTimeInterval(1_800), kind: .file,
                           subject: "auth.swift", title: "auth.swift"),
        ]
        return EpisodeBuilder.episodes(from: signals, now: noon.addingTimeInterval(7_200))[0]
    }

    @Test("Un episodio se escribe como un Markdown que una persona puede leer")
    func episodeReads() {
        let text = CorpusFiles.render(CorpusFiles.document(for: episode(), links: ["BeLauncher"]))
        #expect(text.hasPrefix("---\n"))
        #expect(text.contains("kind: episode"))
        #expect(text.contains("## What you touched"))
        #expect(text.contains("auth.swift"))
        #expect(text.contains("[[BeLauncher]]"))
    }

    @Test("Lo que se escribe se vuelve a leer igual")
    func roundTrip() throws {
        let written = CorpusFiles.document(for: episode(), links: ["BeLauncher", "auth"])
        let parsed = try #require(CorpusFiles.parse(CorpusFiles.render(written)))
        #expect(parsed.id == written.id)
        #expect(parsed.kind == .episode)
        #expect(parsed.title == written.title)
        #expect(parsed.links == written.links)
        #expect(parsed.body == written.body)
    }

    @Test("Una entidad viaja con todos los nombres a los que responde")
    func entityRoundTrip() throws {
        let entity = Entity(kind: .project, canonical: "WAW Trips",
                            aliases: ["waw-trips", "waw_trips"], weight: 12)
        let document = CorpusFiles.document(for: entity, seenAt: noon)
        let onDisk = try #require(CorpusFiles.parse(CorpusFiles.render(document)))
        let recovered = try #require(CorpusFiles.entity(from: onDisk))
        #expect(recovered.canonical == "WAW Trips")
        #expect(recovered.aliases == entity.aliases)
        #expect(recovered.weight == 12)
        #expect(recovered.answers(to: "waw trips"))
    }

    @Test("Lo que escribiste a mano no lo pisa la máquina nunca")
    func handEditWins() {
        let machine = CorpusFiles.document(for: episode())
        let mine = CorpusFiles.handEdit(machine, body: "# La tarde que arreglé el login\n\nFue el token.",
                                        at: noon)
        let decision = CorpusFiles.write(machine, over: CorpusFiles.render(mine))
        #expect(decision == .keepHandEdit)
    }

    @Test("Al editar a mano, el título pasa a ser el que escribiste tú")
    func handEditRenames() {
        let edited = CorpusFiles.handEdit(CorpusFiles.document(for: episode()),
                                          body: "# La tarde que arreglé el login\n\nFue el token.",
                                          at: noon)
        #expect(edited.title == "La tarde que arreglé el login")
        #expect(edited.corrections.editedByHand)
    }

    @Test("Una corrección sobrevive a que la máquina vuelva a escribir el archivo")
    func correctionsSurvive() throws {
        // Es lo único del corpus que no se puede recalcular: si se pierde al regenerar, corregir
        // el cerebro no sirve de nada porque la corrección dura hasta la siguiente pasada.
        let machine = CorpusFiles.document(for: episode())
        let marked = CorpusFiles.apply(.markImportant(true), to: machine, at: noon)

        // El episodio crece: la máquina vuelve a escribirlo con una señal más.
        var grown = machine
        grown.body += "- 13:20 · Archivo · auth.swift\n"

        guard case .write(let contents) = CorpusFiles.write(grown, over: CorpusFiles.render(marked)) else {
            Issue.record("Debería reescribirse conservando la marca")
            return
        }
        #expect(contents.contains("13:20"))
        #expect(try #require(CorpusFiles.parse(contents)).corrections.pinned)
    }

    @Test("Marcar algo como importante no congela el archivo")
    func markingIsNotAHandEdit() {
        // Decir «esto importa» no es reescribir el texto. Si lo tratáramos como edición a mano, el
        // episodio nunca volvería a recoger el resto de sus propias señales.
        let marked = CorpusFiles.apply(.markImportant(true), to: CorpusFiles.document(for: episode()))
        #expect(!marked.corrections.editedByHand)
    }

    @Test("Volver a escribir lo mismo no toca el archivo")
    func unchanged() {
        let document = CorpusFiles.document(for: episode())
        #expect(CorpusFiles.write(document, over: CorpusFiles.render(document)) == .unchanged)
    }

    @Test("Un rechazo de fusión se recuerda para siempre y el motor lo respeta")
    func rejectionReachesTheEngine() {
        let carpeta = Entity(kind: .project, canonical: "/Users/mac/Developer/waw-trips")
        let proyecto = Entity(kind: .project, canonical: "WAW Trips")
        guard case .merge = Identity.decide(carpeta, proyecto) else {
            Issue.record("Sin rechazo previo, estas dos se funden solas")
            return
        }

        let proposal = MergeProposal(left: carpeta.canonical, right: proyecto.canonical,
                                     reason: .pathMatch)
        let corrected = CorpusFiles.apply(.rejectMerge(proposal),
                                          to: CorpusFiles.document(for: carpeta, seenAt: noon))
        let rejected = CorpusFiles.rejected(in: [corrected])
        #expect(rejected.contains(proposal.id))
        #expect(Identity.decide(carpeta, proyecto, rejected: rejected) == .leaveAlone)
    }

    @Test("El rechazo sigue ahí después de guardar y volver a leer")
    func rejectionPersists() throws {
        let proposal = MergeProposal(left: "Acme", right: "Acme Corp", reason: .sameName)
        let document = CorpusFiles.apply(
            .rejectMerge(proposal),
            to: CorpusFiles.document(for: Entity(kind: .company, canonical: "Acme"), seenAt: noon))
        let reread = try #require(CorpusFiles.parse(CorpusFiles.render(document)))
        #expect(reread.corrections.rejectedMerges.contains(proposal.id))
    }

    @Test("Un archivo ajeno en la carpeta no se lee como memoria")
    func strayFileIsIgnored() {
        // Estas carpetas se leen enteras, así que una nota suelta se convertiría en algo que el
        // cerebro cree. Es el mismo agujero por el que la bóveda no deja notas en objects.
        #expect(CorpusFiles.parse("# Lista de la compra\n\n- pan\n") == nil)
        #expect(CorpusFiles.parse("---\ntitle: algo\n---\n\ncuerpo") == nil)
    }

    @Test("El corpus no escribe en las carpetas que la bóveda lee como memoria")
    func doesNotCollideWithTheVault() {
        #expect(CorpusFiles.machineRead.isDisjoint(with: VaultGuide.machineRead))
    }

    @Test("Los enlaces del cuerpo se pueden volver a leer, sin repetirlos")
    func linksComeBack() {
        let found = CorpusFiles.links(in: "Trabajé en [[WAW Trips]] con [[Ana]] y otra vez [[Ana]].")
        #expect(found == ["WAW Trips", "Ana"])
    }

    @Test("Un nombre con corchetes no rompe el enlace")
    func brokenLinkIsSanitised() {
        #expect(CorpusFiles.wikilink("informe [borrador]") == "[[informe (borrador)]]")
    }

    @Test("El archivo se encuentra por su id aunque cambie el título")
    func filenameKeepsTheHandle() {
        var document = CorpusFiles.document(for: episode())
        let before = CorpusFiles.filename(for: document)
        document.title = "Otro título completamente distinto"
        let after = CorpusFiles.filename(for: document)
        #expect(before != after)
        #expect(after.hasSuffix("-" + CorpusFiles.handle(for: document.id) + ".md"))
    }

    @Test("Una frase destilada lleva encima de dónde salió")
    func statementCarriesItsCitation() throws {
        let statement = Distillation.Statement(text: "Cerraste el login con un token corto",
                                               sources: ["episode:abc"], day: noon)
        let document = CorpusFiles.document(for: statement, titles: ["episode:abc": "auth.swift"])
        #expect(document.lists["sources"] == ["episode:abc"])
        #expect(document.body.contains("[[auth.swift]]"))
    }
}

@Suite("La carpeta del corpus")
@MainActor
struct CorpusFolderTests {

    private let noon = Date(timeIntervalSince1970: 1_785_240_000)

    private func temporaryRoot() -> String {
        let path = NSTemporaryDirectory() + "belauncher-corpus-" + UUID().uuidString
        return path
    }

    private func episode() -> Episode {
        EpisodeBuilder.episodes(from: [
            Episode.Signal(at: noon, kind: .file, subject: "auth.swift", title: "auth.swift"),
            Episode.Signal(at: noon.addingTimeInterval(900), kind: .file,
                           subject: "login.swift", title: "login.swift"),
        ], now: noon.addingTimeInterval(7_200))[0]
    }

    @Test("La carpeta se explica sola desde el primer día")
    func scaffold() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try CorpusFolder(root: root)

        for folder in CorpusFiles.folders {
            #expect(FileManager.default.fileExists(
                atPath: (root as NSString).appendingPathComponent(folder.name)))
        }
        #expect(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent("LÉEME — corpus.md")))
    }

    @Test("Lo que editas a mano sigue ahí después de que el cerebro vuelva a pasar")
    func handEditSurvivesRegeneration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)

        let machine = CorpusFiles.document(for: episode())
        try folder.save(machine)
        _ = try folder.saveHandEdit(machine, body: "# Lo del login\n\nEra el token, no la sesión.",
                                    at: noon)

        // El cerebro vuelve a pasar por el mismo episodio, como hace cada noche.
        #expect(try folder.save(machine) == .keepHandEdit)

        let onDisk = try #require(folder.load(id: machine.id, kind: .episode))
        #expect(onDisk.body.contains("Era el token, no la sesión."))
        #expect(onDisk.title == "Lo del login")
        #expect(folder.documents(kind: .episode).count == 1)
    }

    @Test("Editar a mano no deja dos archivos peleando por el mismo episodio")
    func handEditDoesNotDuplicate() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)

        let machine = CorpusFiles.document(for: episode())
        try folder.save(machine)
        _ = try folder.saveHandEdit(machine, body: "# Otro nombre\n\nTexto mío.", at: noon)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.folder(.episode))
        #expect(names.filter { $0.hasSuffix(".md") }.count == 1)
    }

    @Test("Una corrección se guarda aunque el archivo sea tuyo")
    func correctionAppliesOverHandEdit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)

        let machine = CorpusFiles.document(for: episode())
        let mine = try folder.saveHandEdit(machine, body: "# Mío\n\nTexto mío.", at: noon)
        _ = try folder.apply(.markImportant(true), to: mine, at: noon)

        let onDisk = try #require(folder.load(id: machine.id, kind: .episode))
        #expect(onDisk.corrections.pinned)
        #expect(onDisk.body.contains("Texto mío."))
    }

    /// Las cuatro que siguen cubren el camino de vuelta: lo que corriges en el grafo se escribe en
    /// el front matter, y el motor tiene que leerlo de ahí. Antes lo leía de un ajuste que nadie
    /// escribía, así que corregir era decorativo.

    @Test("Un rechazo escrito en la carpeta llega al motor y deja de proponerse")
    func rejectionReachesTheEngine() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)

        let mine = Entity(kind: .project, canonical: "waw-trips")
        let theirs = Entity(kind: .project, canonical: "WAW Trips")
        let refused = MergeProposal(left: mine.canonical, right: theirs.canonical, reason: .sameName)
        _ = try folder.apply(.rejectMerge(refused),
                             to: CorpusFiles.document(for: mine, seenAt: noon), at: noon)

        // Reinicio: nadie recuerda nada, solo queda la carpeta.
        let learned = CorpusFiles.learned(inFolderAt: root)
        #expect(learned.rejectedMerges.contains(refused.id))
        #expect(Identity.decide(mine, theirs, rejected: learned.rejectedMerges) == .leaveAlone)
    }

    @Test("Marcar algo importante cambia lo que pesa en la búsqueda")
    func markReachesRelevance() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)

        let marked = episode()
        _ = try folder.apply(.markImportant(true, subjects: marked.subjects),
                             to: CorpusFiles.document(for: marked), at: noon)

        let learned = CorpusFiles.learned(inFolderAt: root)
        #expect(learned.markedByHand.contains("auth.swift"))

        // Un episodio flojo: dos archivos y quince minutos. Sin la marca no llega ni al umbral.
        let signals = Relevance.signals(for: marked, daysSeen: 1, neighbours: 1,
                                        markedByHand: marked.subjects
                                            .contains { learned.markedByHand.contains($0) })
        #expect(Relevance.score(signals) == 1)
    }

    @Test("Quitar la marca la quita también del motor")
    func unmarkClearsTheSubjects() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)

        let marked = episode()
        let document = CorpusFiles.document(for: marked)
        let pinned = try folder.apply(.markImportant(true, subjects: ["auth.swift"]),
                                      to: document, at: noon)
        _ = try folder.apply(.markImportant(false), to: pinned, at: noon)

        #expect(CorpusFiles.learned(inFolderAt: root).markedByHand.isEmpty)
    }

    @Test("Lo que sacas del grafo queda anotado para que no vuelva")
    func hiddenIsRemembered() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)

        let gone = CorpusFiles.document(for: Entity(kind: .person, canonical: "Alguien"),
                                        seenAt: noon)
        _ = try folder.apply(.hide(true), to: gone, at: noon)

        #expect(CorpusFiles.learned(inFolderAt: root).hidden.contains(gone.id))
    }

    @Test("Un archivo suelto en la carpeta se ignora en vez de creerse")
    func strayFileIsSkipped() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = try CorpusFolder(root: root)
        try folder.save(CorpusFiles.document(for: episode()))

        let stray = (folder.folder(.episode) as NSString).appendingPathComponent("apuntes.md")
        try "# Apuntes sueltos\n\nnada que ver".write(toFile: stray, atomically: true, encoding: .utf8)

        #expect(folder.documents(kind: .episode).count == 1)
    }
}
