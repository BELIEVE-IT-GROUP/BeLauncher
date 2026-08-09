import Testing
import Foundation
@testable import BeLauncherCore

/// Killing things: the feature where the judgement matters more than the code.
@Suite("Qué está comiendo el Mac")
struct ProcessListTests {

    static let sample = """
          170  50.3  88496 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
        34196  25.9  76080 /Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper
        44255  16.3 754176 claude bg-spare
          501   0.0    900 /usr/sbin/notifyd
        """

    @Test("reads pid, cpu, memory and the app behind a helper")
    func parses() throws {
        let processes = ProcessList.parse(Self.sample)
        #expect(processes.count == 4)

        let server = try #require(processes.first { $0.name == "WindowServer" })
        #expect(server.id == 170)
        #expect(server.cpu == 50.3)
        #expect(server.memory == 88_496 * 1024)
        #expect(!server.isApplication, "un binario dentro de un framework no es una app")

        // A name with a space in it survives, and its bundle is found.
        let helper = try #require(processes.first { $0.name == "Orca Helper" })
        #expect(helper.bundlePath.hasSuffix("Orca Helper.app"))
        #expect(helper.isApplication)
    }

    @Test("la basura no se convierte en filas")
    func ignoresJunk() {
        #expect(ProcessList.parse("").isEmpty)
        #expect(ProcessList.parse("no soy una tabla").isEmpty)
        #expect(ProcessList.parse("abc  def  ghi  /bin/x").isEmpty)
    }

    @Test("lo más pesado primero, y lo que no consume nada no aparece")
    func sortsAndTrims() {
        let processes = ProcessList.parse(Self.sample)
        let byCPU = ProcessList.top(processes, order: .cpu)
        #expect(byCPU.first?.name == "WindowServer")
        #expect(!byCPU.contains { $0.name == "notifyd" },
                "una lista de 400 demonios en reposo no responde a «qué me está calentando el Mac»")

        let byMemory = ProcessList.top(processes, order: .memory)
        #expect(byMemory.first?.name == "claude bg-spare", "por memoria el orden es otro")
    }

    @Test("al filtrar por nombre sí aparece lo que no consume nada")
    func filterShowsEverything() {
        let found = ProcessList.top(ProcessList.parse(Self.sample), filter: "notifyd")
        #expect(found.map(\.name) == ["notifyd"], "si lo buscas por su nombre, lo quieres ver")
    }

    @Test("WindowServer y kernel_task nunca se pueden cerrar desde aquí")
    func refusesToLoseYourSession() throws {
        let server = RunningProcess(id: 170, name: "WindowServer", cpu: 50, memory: 1)
        let refusal = try #require(ProcessList.refusal(for: server))
        #expect(refusal.contains("throws you out of the session"),
                "hay que decir qué pasaría, no solo negarse")

        let kernel = RunningProcess(id: 0, name: "kernel_task", cpu: 300, memory: 1)
        #expect(ProcessList.refusal(for: kernel) != nil)
        // Y estos salen los primeros al ordenar por CPU, que es justo el peligro.
        #expect(ProcessList.isProtected(server))
        #expect(ProcessList.isProtected(kernel))
    }

    @Test("una app normal sí se puede cerrar")
    func ordinaryAppsAreFair() {
        let app = RunningProcess(id: 500, name: "Orca Helper", cpu: 25, memory: 1)
        #expect(ProcessList.refusal(for: app) == nil)
        #expect(!ProcessList.isProtected(app))
    }

    @Test("el Finder y el Dock se explican en vez de negarse a secas")
    func desktopPiecesExplainThemselves() throws {
        let finder = RunningProcess(id: 300, name: "Finder", cpu: 1, memory: 1)
        let refusal = try #require(ProcessList.refusal(for: finder))
        #expect(refusal.contains("Force Quit"), "hay que decir dónde sí se puede")
    }

    @Test("se escribe como se dice, y «memoria» ordena distinto")
    func recognisesTyping() throws {
        #expect(ProcessList.order(for: "cpu")?.order == .cpu)
        #expect(ProcessList.order(for: "procesos")?.order == .cpu)
        #expect(ProcessList.order(for: "memoria")?.order == .memory)
        #expect(ProcessList.order(for: "ram")?.order == .memory)

        let filtered = try #require(ProcessList.order(for: "cpu chrome"))
        #expect(filtered.filter == "chrome")

        #expect(ProcessList.order(for: "cp") == nil)
        #expect(ProcessList.order(for: "notion") == nil)
    }

    @Test("la fila dice lo que cuesta, y avisa cuando es del sistema")
    func subtitleIsHonest() {
        let server = RunningProcess(id: 170, name: "WindowServer", cpu: 50.3, memory: 90_000_000)
        #expect(ProcessList.subtitle(for: server, order: .cpu).contains("system"))
        #expect(ProcessList.subtitle(for: server, order: .cpu).hasPrefix("CPU 50.3%"))
        // Por memoria, lo que se pregunta va primero.
        #expect(!ProcessList.subtitle(for: server, order: .memory).hasPrefix("CPU"))
    }
}

@Suite("No dejar dormir el Mac")
struct StayAwakeTests {

    @Test("se ofrece desde quince minutos hasta indefinido")
    func offersRealDurations() throws {
        let offers = try #require(StayAwake.offers(for: "cafeina"))
        #expect(offers.first?.minutes == nil, "«hasta que lo apague» es la respuesta más común")
        #expect(offers.contains { $0.minutes == 60 })
    }

    @Test("decir la duración salta el menú")
    func skipsTheMenu() throws {
        let direct = try #require(StayAwake.offers(for: "cafeina 2 horas"))
        #expect(direct.count == 1)
        #expect(direct[0].minutes == 120)
    }

    @Test("las formas en que se escribe una duración")
    func parsesDurations() {
        #expect(StayAwake.minutes(fromPhrase: "45 min") == 45)
        #expect(StayAwake.minutes(fromPhrase: "2 horas") == 120)
        #expect(StayAwake.minutes(fromPhrase: "1h") == 60)
        #expect(StayAwake.minutes(fromPhrase: "3 hours") == 180)
        // Más de un día es indefinido con otro nombre, y una asertiva olvidada cuece un portátil.
        #expect(StayAwake.minutes(fromPhrase: "40 horas") == nil)
        #expect(StayAwake.minutes(fromPhrase: "un rato") == nil)
        #expect(StayAwake.minutes(fromPhrase: "0 min") == nil)
    }

    @Test("escribir otra cosa no activa nada")
    func noFalsePositives() {
        #expect(StayAwake.offers(for: "café") == nil)
        #expect(StayAwake.offers(for: "no") == nil)
        #expect(StayAwake.offers(for: "documentos") == nil)
    }

    @Test("la barra de menús dice cuánto queda, no solo que está activo")
    func showsRemaining() {
        let now = Date()
        #expect(StayAwake.remaining(until: nil).contains("no end"))
        #expect(StayAwake.remaining(until: now.addingTimeInterval(1_800), now: now).contains("30 min"))
        #expect(StayAwake.remaining(until: now.addingTimeInterval(5_400), now: now).contains("1 h"))
    }
}

@Suite("Apuntar algo sin pensarlo")
struct QuickNoteTests {

    @Test("se reconoce como se escribe")
    func recognisesTyping() {
        #expect(QuickNote.text(from: "nota llamar a Andrés") == "llamar a Andrés")
        #expect(QuickNote.text(from: "apunta comprar café") == "comprar café")
        #expect(QuickNote.text(from: "anota la idea del carrusel") == "la idea del carrusel")
        // Sin texto detrás no hay nota que guardar.
        #expect(QuickNote.text(from: "nota") == nil)
        #expect(QuickNote.text(from: "nota   ") == nil)
        #expect(QuickNote.text(from: "notion") == nil)
    }

    @Test("el nombre del archivo ordena por fecha y dice de qué va")
    func filenameIsUseful() {
        let name = QuickNote.filename(for: "llamar a Andrés sobre el precio",
                                      at: Date(timeIntervalSince1970: 1_770_000_000))
        #expect(name.hasSuffix(".md"))
        #expect(name.contains("llamar"))
        #expect(name.hasPrefix("2026-"))
        #expect(!name.contains("/"), "un nombre con barra crea carpetas por accidente")
    }

    @Test("el archivo es Markdown legible con datos aprovechables")
    func renderIsReadable() {
        let text = QuickNote.render("una idea", at: Date(timeIntervalSince1970: 0))
        #expect(text.hasPrefix("---"))
        #expect(text.contains("kind: nota"))
        #expect(text.contains("una idea"))
        #expect(QuickNote.body(from: text) == "una idea")
    }

    @Test("las notas caen en el inbox, que es la carpeta que se vacía")
    func landsInTheInbox() {
        #expect(QuickNote.folder(inVaultAt: "/x/Vault") == "/x/Vault/inbox")
    }

    @Test("revisar una nota queda registrado sin sacarla del inbox")
    func reviewIsPersistent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-note-review-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = inbox.appendingPathComponent("2026-08-07 1200 revisar.md")
        try QuickNote.render("revisar el acuerdo", at: Date(timeIntervalSince1970: 0))
            .write(to: path, atomically: true, encoding: .utf8)
        guard let record = QuickNote.records(inVaultAt: root.path).first else {
            Issue.record("la nota de prueba no apareció en el inbox")
            return
        }

        #expect(record.reviewed == false)
        try QuickNote.markReviewed(record)
        let reviewed = try #require(QuickNote.records(inVaultAt: root.path).first)
        #expect(reviewed.reviewed)
        #expect(FileManager.default.fileExists(atPath: reviewed.path))
    }

    @Test("editar una nota conserva su front matter y cambia solo el Markdown")
    func bodyEditIsPersistent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-note-edit-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = inbox.appendingPathComponent("note.md")
        try QuickNote.render("texto original", at: Date(timeIntervalSince1970: 0))
            .write(to: path, atomically: true, encoding: .utf8)
        let record = try #require(QuickNote.records(inVaultAt: root.path).first)
        try QuickNote.markReviewed(record)
        let reviewed = try #require(QuickNote.records(inVaultAt: root.path).first)
        try QuickNote.updateBody(reviewed, body: "# Texto corregido\n\n- una línea")
        let raw = try String(contentsOfFile: path.path, encoding: .utf8)
        #expect(raw.contains("reviewed: true"))
        #expect(raw.contains("# Texto corregido"))
        #expect(!raw.contains("texto original"))
    }

    @Test("editar Markdown conserva separadores horizontales del cuerpo")
    func bodyEditPreservesHorizontalRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-note-horizontal-rule-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = inbox.appendingPathComponent("note.md")
        let raw = QuickNote.render("primera parte\n\n---\n\nsegunda parte",
                                   at: Date(timeIntervalSince1970: 0))
        try raw.write(to: path, atomically: true, encoding: .utf8)
        let record = try #require(QuickNote.records(inVaultAt: root.path).first)

        #expect(QuickNote.body(from: raw).contains("---"))
        try QuickNote.markReviewed(record)
        let reviewed = try #require(QuickNote.records(inVaultAt: root.path).first)
        #expect(QuickNote.body(from: try String(contentsOf: path, encoding: .utf8))
                == "primera parte\n\n---\n\nsegunda parte")
        try QuickNote.updateBody(reviewed, body: "primera parte\n\n---\n\ntexto editado")
        let updated = try String(contentsOf: path, encoding: .utf8)
        #expect(updated.contains("reviewed: true"))
        #expect(updated.contains("---\n\ntexto editado"))
        #expect(QuickNote.body(from: updated) == "primera parte\n\n---\n\ntexto editado")
    }

    @Test("el inbox conserva procedencia y detecta transcripción pendiente")
    func recordCarriesProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-note-provenance-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = inbox.appendingPathComponent("call.md")
        try QuickNote.renderEvidence(title: "Call", text: "Voice note awaiting transcription",
                                     at: Date(timeIntervalSince1970: 0), sourcePath: "/tmp/call.m4a")
            .write(to: path, atomically: true, encoding: .utf8)
        let record = try #require(QuickNote.records(inVaultAt: root.path).first)
        #expect(record.kind == .evidence)
        #expect(record.state == .needsTranscription)
        #expect(record.createdAt == Date(timeIntervalSince1970: 0))
        let item = InboxItem(record: record)
        #expect(item.kind == .evidence)
        #expect(item.sourcePath == "/tmp/call.m4a")
    }

    @Test("solo un clip fijado se convierte en candidato del Brain")
    func pinnedClipIsReviewable() {
        let clip = Clip(text: "decisión importante", sourceApp: "Mail", isPinned: true)
        let item = InboxItem(clip: clip)
        #expect(item.kind == .clipboard)
        #expect(item.clipID == clip.id)
        #expect(item.sourceApp == "Mail")
    }
}
