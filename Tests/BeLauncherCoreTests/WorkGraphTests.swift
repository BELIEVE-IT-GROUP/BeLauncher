import Testing
import Foundation
@testable import BeLauncherCore

/// Operational memory: what you were doing, not only what the company believes.
@Suite("The graph of work")
@MainActor
struct WorkGraphTests {

    private func temporaryStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("graph-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        return try Store(path: path)
    }

    @Test("the same person seen twice is one node, however it was written")
    func identityIsStable() {
        #expect(WorkNode.identifier(kind: .person, name: "Andrés")
                == WorkNode.identifier(kind: .person, name: "andres"))
        #expect(WorkNode.identifier(kind: .person, name: " Andrés ")
                == WorkNode.identifier(kind: .person, name: "Andres"))
        // Kind is part of the identity: a project called Acme is not the company Acme.
        #expect(WorkNode.identifier(kind: .person, name: "Acme")
                != WorkNode.identifier(kind: .company, name: "Acme"))
    }

    @Test("seeing something again makes it heavier, never duplicated")
    func upsertAccumulates() throws {
        let store = try temporaryStore()
        let node = WorkNode(id: "person:andres", kind: .person, name: "Andrés")
        store.upsertNode(node)
        store.upsertNode(node)
        store.upsertNode(node)

        let people = store.nodes(kind: .person)
        #expect(people.count == 1)
        #expect(people[0].weight == 3)
    }

    @Test("a later sighting never rewinds when something was last seen")
    func lastSeenOnlyMovesForward() throws {
        let store = try temporaryStore()
        let now = Date()
        store.upsertNode(WorkNode(id: "file:x", kind: .file, name: "x", lastSeen: now))
        store.upsertNode(WorkNode(id: "file:x", kind: .file, name: "x",
                                  lastSeen: now.addingTimeInterval(-9_000)))

        let seen = try #require(store.node(id: "file:x")).lastSeen
        #expect(abs(seen.timeIntervalSince(now)) < 1, "un dato viejo no puede envejecer el nodo")
    }

    @Test("an empty detail never erases one we already had")
    func partialUpdatesDoNotDestroy() throws {
        let store = try temporaryStore()
        store.upsertNode(WorkNode(id: "person:a", kind: .person, name: "A",
                                  detail: "a@acme.com", target: "/x"))
        store.upsertNode(WorkNode(id: "person:a", kind: .person, name: "A"))

        let node = try #require(store.node(id: "person:a"))
        #expect(node.detail == "a@acme.com")
        #expect(node.target == "/x")
    }

    @Test("edges survive being written twice and are readable from either end")
    func edgesAreIdempotent() throws {
        let store = try temporaryStore()
        let edge = WorkEdge(source: "person:a", target: "meeting:m", kind: .partOf)
        store.link(edge)
        store.link(edge)

        #expect(store.edges(from: "person:a").count == 1)
        #expect(store.edges(from: "meeting:m").count == 1)
    }
}

@Suite("Asking the graph what you promised")
struct PromisedTests {

    static let meetingID = WorkNode.identifier(kind: .meeting, name: "Revisión Acme")
    static let andresID = WorkNode.identifier(kind: .person, name: "Andrés")

    @Test("a commitment naming the person is found")
    func directCommitment() {
        let promise = MemoryObject(level: .committed, kind: .commitment,
                                   statement: "Enviar la propuesta a Andrés el viernes")
        let answer = WorkQuery.promised(to: "Andrés", nodes: [], edges: [], memories: [promise])
        #expect(answer.body.contains("Enviar la propuesta"))
    }

    @Test("a commitment that never names them is found through the meeting they were in")
    func indirectThroughMeeting() {
        // The whole reason this is a graph and not a tag search: nothing here says "Andrés".
        let commitment = WorkNode(id: "commitment:1", kind: .commitment,
                                  name: "Mandar el presupuesto revisado",
                                  detail: "salió de la revisión")
        let edges = [
            WorkEdge(source: Self.andresID, target: Self.meetingID, kind: .partOf),
            WorkEdge(source: "commitment:1", target: Self.meetingID, kind: .cameFrom),
        ]
        let answer = WorkQuery.promised(to: "Andrés", nodes: [commitment], edges: edges,
                                        memories: [])
        #expect(answer.body.contains("presupuesto revisado"),
                "un compromiso que salió de su reunión también es suyo")
    }

    @Test("an overdue commitment is marked, not just listed")
    func overdueIsFlagged() {
        let yesterday = Date().addingTimeInterval(-86_400)
        let promise = MemoryObject(level: .committed, kind: .commitment,
                                   statement: "Enviar a Andrés", validUntil: yesterday)
        let answer = WorkQuery.promised(to: "Andrés", nodes: [], edges: [], memories: [promise])
        #expect(answer.body.contains("overdue"))
    }

    @Test("nothing pending says so plainly instead of inventing a summary")
    func nothingPending() {
        let answer = WorkQuery.promised(to: "Nadie", nodes: [], edges: [], memories: [])
        #expect(answer.headline.contains("Nothing outstanding"))
        #expect(answer.nodes.isEmpty)
    }

    @Test("a commitment already fulfilled stops counting")
    func fulfilledIsExcluded() {
        var promise = MemoryObject(level: .committed, kind: .commitment,
                                   statement: "Enviar a Andrés")
        promise.status = .superseded
        let answer = WorkQuery.promised(to: "Andrés", nodes: [], edges: [], memories: [promise])
        #expect(answer.headline.contains("Nothing outstanding"))
    }
}

@Suite("Picking work back up")
struct ResumeTests {

    @Test("what you had open before the last meeting is what you get back")
    func beforeTheCall() {
        let start = Date()
        let meeting = CalendarEvent(id: "1", title: "Llamada con Nike",
                                    start: start, end: start.addingTimeInterval(1_800))
        let nodes = [
            WorkNode(id: "file:a", kind: .file, name: "propuesta.pdf", target: "/a.pdf",
                     lastSeen: start.addingTimeInterval(-300)),
            WorkNode(id: "file:b", kind: .file, name: "viejo.pdf", target: "/b.pdf",
                     lastSeen: start.addingTimeInterval(-90_000)),
        ]
        let answer = WorkQuery.resume(nodes: nodes, meetings: [meeting],
                                      at: start.addingTimeInterval(3_600))
        #expect(answer.nodes.map(\.name) == ["propuesta.pdf"],
                "lo de ayer no es lo que estabas haciendo antes de la llamada")
    }

    @Test("nothing openable is never offered as something to reopen")
    func onlyOpenableThings() {
        let start = Date()
        let meeting = CalendarEvent(id: "1", title: "Llamada", start: start, end: start)
        let concept = WorkNode(id: "project:x", kind: .project, name: "Atlas",
                               lastSeen: start.addingTimeInterval(-60))
        let answer = WorkQuery.resume(nodes: [concept], meetings: [meeting],
                                      at: start.addingTimeInterval(60))
        #expect(answer.nodes.isEmpty, "un proyecto no se «abre»; un archivo sí")
    }

    @Test("no meetings means saying so, not guessing")
    func noMeetings() {
        let answer = WorkQuery.resume(nodes: [], meetings: [])
        #expect(answer.headline.contains("no recent meeting"))
    }
}

@Suite("Filling the graph from what already happens")
struct CaptureTests {

    @Test("a meeting brings its people, and its people bring their company")
    func meetingsBringPeople() {
        let meeting = CalendarEvent(id: "1", title: "Revisión Acme", start: Date(), end: Date(),
                                    attendees: ["andres.lopez@acme.com"])
        let events = Capture.events(from: [meeting])

        #expect(events.contains { $0.node.kind == .meeting })
        let person = events.first { $0.node.kind == .person }
        #expect(person?.node.name == "Andres Lopez", "una dirección no es un nombre")
        #expect(person?.links.contains { $0.kind == .worksAt } == true)
        #expect(person?.links.contains { $0.kind == .partOf } == true)
    }

    @Test("a free mail address is not a company")
    func freeMailIsNotACompany() {
        #expect(Capture.company(fromEmail: "alguien@gmail.com") == nil)
        #expect(Capture.company(fromEmail: "alguien@icloud.com") == nil)
        #expect(Capture.company(fromEmail: "alguien@acme.co.uk") == "Acme")
        #expect(Capture.company(fromEmail: "sin arroba") == nil)
    }

    @Test("the folder is the project, unless the folder is just a place")
    func foldersBecomeProjects() {
        #expect(Capture.project(forPath: "/Users/x/Clientes/Acme/propuesta.pdf") == "Acme")
        // These say where a file lives, not what it is about.
        #expect(Capture.project(forPath: "/Users/x/Downloads/factura.pdf") == nil)
        #expect(Capture.project(forPath: "/Users/x/Desktop/nota.txt") == nil)
        #expect(Capture.project(forPath: "/Users/x/Escritorio/nota.txt") == nil)
    }

    @Test("things touched in the same stretch are linked, things hours apart are not")
    func sessionsLinkNeighbours() {
        let now = Date()
        let nodes = [
            WorkNode(id: "a", kind: .file, name: "a", lastSeen: now),
            WorkNode(id: "b", kind: .file, name: "b", lastSeen: now.addingTimeInterval(120)),
            WorkNode(id: "c", kind: .file, name: "c", lastSeen: now.addingTimeInterval(50_000)),
        ]
        let edges = Capture.sessions(nodes)
        #expect(edges.contains { $0.source == "a" && $0.target == "b" })
        #expect(!edges.contains { $0.target == "c" }, "cinco horas después no es la misma tarea")
    }

    @Test("a commitment can be tied to the meeting it came out of")
    func commitmentsRememberTheirOrigin() {
        let object = MemoryObject(level: .extracted, kind: .commitment,
                                  statement: "Mandar el presupuesto")
        let event = Capture.memory(object, fromMeeting: "Revisión Acme")
        #expect(event.links.first?.kind == .cameFrom)
    }
}

@Suite("Recognising the questions people type")
struct WorkIntentTests {

    @Test("each question is recognised in the words someone would use")
    func detectsIntents() {
        #expect(WorkQuery.Intent.detect("qué prometimos a Andrés") == .promisedTo("andres"))
        #expect(WorkQuery.Intent.detect("abre lo último de Project Atlas")
                == .lastAbout("project atlas"))
        #expect(WorkQuery.Intent.detect("retoma lo que estaba haciendo antes de la llamada")
                == .resumeBefore)
        #expect(WorkQuery.Intent.detect("quién es Acme") == .about("acme"))
    }

    @Test("ordinary searching is never mistaken for a question")
    func noFalsePositives() {
        #expect(WorkQuery.Intent.detect("notion") == nil)
        #expect(WorkQuery.Intent.detect("que") == nil)
        #expect(WorkQuery.Intent.detect("") == nil)
    }
}

@Suite("The log that makes learning possible")
@MainActor
struct ActionLogTests {

    private func temporaryStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        return try Store(path: path)
    }

    @Test("nothing is recorded until the person turns it on")
    func offByDefault() throws {
        let store = try temporaryStore()
        #expect(!store.habitsEnabled)
        store.recordAction(signature: "app:Notion", label: "Abrir Notion")
        #expect(store.actionLog().isEmpty, "grabar sin permiso es vigilancia, no una función")
    }

    @Test("with it on, actions come back oldest first, which is what a detector needs")
    func recordsInOrder() throws {
        let store = try temporaryStore()
        store.setSetting("habits_enabled", true)
        let now = Date()
        store.recordAction(signature: "a", label: "A", at: now)
        store.recordAction(signature: "b", label: "B", at: now.addingTimeInterval(1))
        store.recordAction(signature: "c", label: "C", at: now.addingTimeInterval(2))

        #expect(store.actionLog().map(\.signature) == ["a", "b", "c"])
    }

    @Test("old history is dropped instead of accumulating forever")
    func trims() throws {
        let store = try temporaryStore()
        store.setSetting("habits_enabled", true)
        let old = Date().addingTimeInterval(-Double(Store.habitRetentionDays + 5) * 86_400)
        store.recordAction(signature: "viejo", label: "Viejo", at: old)
        store.recordAction(signature: "nuevo", label: "Nuevo")

        #expect(store.actionLog().map(\.signature) == ["nuevo"])
    }

    @Test("the person can wipe it, and wiping means gone")
    func clearable() throws {
        let store = try temporaryStore()
        store.setSetting("habits_enabled", true)
        store.recordAction(signature: "a", label: "A")
        store.clearActionLog()
        #expect(store.actionLog().isEmpty)
    }

    @Test("a habit already offered is not offered again")
    func offersAreRemembered() throws {
        let store = try temporaryStore()
        #expect(!store.recipeAlreadyOffered("a|b|c"))
        store.markRecipeOffered("a|b|c", accepted: false)
        #expect(store.recipeAlreadyOffered("a|b|c"),
                "repetir una sugerencia rechazada es como se desactiva una función")
    }
}

/// The wiring, tested where it is easy to leave a promise unconnected.
@Suite("What the graph learns from what happens")
struct CaptureWiringTests {

    @Test("an address becomes a person with a readable name and a company")
    func personFromAddress() {
        let event = Capture.person(named: "jorge.beltran@believe-global.com")
        #expect(event.node.name == "Jorge Beltran")
        #expect(event.node.kind == .person)
        #expect(event.links.first?.kind == .worksAt)

        // A plain name stays a plain name and carries no company.
        let plain = Capture.person(named: "Andrés")
        #expect(plain.node.name == "Andrés")
        #expect(plain.links.isEmpty)
    }

    @Test("authorized contacts project into person nodes without copying the source database")
    func contactsBecomePeople() {
        let events = Capture.contacts([
            ContactItem(id: "c1", name: "Ana López", email: "ana@example.com", phone: "")
        ])
        #expect(events.count == 1)
        #expect(events[0].node.kind == .person)
        #expect(events[0].node.name == "Ana López")
        #expect(events[0].node.detail == "ana@example.com")
        #expect(events[0].node.target.isEmpty)
    }

    @Test("a file remembers where it can be opened from")
    func filesAreOpenable() {
        let event = Capture.file(at: "/Users/x/Clientes/Acme/propuesta.pdf")
        #expect(event.node.target == "/Users/x/Clientes/Acme/propuesta.pdf")
        #expect(event.node.name == "propuesta.pdf")
        #expect(event.links.first?.kind == .partOf, "la carpeta es el proyecto")
    }
}

@Suite("Urgency is personal")
struct PersonalUrgencyTests {

    static func overdue(_ statement: String) -> MemoryObject {
        MemoryObject(level: .committed, kind: .commitment, statement: statement,
                     validUntil: Date().addingTimeInterval(-86_400))
    }

    @Test("what this person calls urgent comes first")
    func learnedUrgencyReorders() {
        let objects = [Self.overdue("Revisar el diseño del logo"), Self.overdue("Pagar la factura de marzo")]
        let neutral = Pulse.signals(for: objects)
        let trait = Trait(name: "priority.urgent", value: "factura", confidence: 0.9,
                          observations: 9)
        let personal = Pulse.signals(for: objects, traits: [trait])

        #expect(neutral.count == personal.count, "no se inventa ni se pierde ninguna señal")
        #expect(personal.first?.detail.localizedCaseInsensitiveContains("factura") == true,
                "dos personas con el mismo cerebro no deberían recibir el mismo orden")
    }

    @Test("without anything learned, the order is the ordinary one")
    func noTraitsNoChange() {
        let objects = [Self.overdue("A"), Self.overdue("B")]
        #expect(Pulse.signals(for: objects).map(\.detail)
                == Pulse.signals(for: objects, traits: []).map(\.detail))
    }
}
