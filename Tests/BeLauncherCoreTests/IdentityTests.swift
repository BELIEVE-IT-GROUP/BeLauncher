import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Reconocer que dos cosas son la misma")
struct IdentityTests {

    private func project(_ name: String, weight: Int = 1) -> Entity {
        Entity(kind: .project, canonical: name, weight: weight)
    }

    @Test("El mismo proyecto escrito de tres formas es uno solo")
    func sameProjectThreeWays() {
        // Así es como llega de verdad: de una carpeta, de una pestaña y de un archivo.
        #expect(Identity.fold("waw-trips") == Identity.fold("WAW Trips"))
        #expect(Identity.fold("waw_trips") == Identity.fold("waw-trips"))
        #expect(Identity.fold("  WAW   TRIPS  ") == "waw trips")
    }

    @Test("Los acentos no separan dos nombres iguales")
    func accents() {
        #expect(Identity.fold("Diseño") == Identity.fold("diseno"))
    }

    @Test("Una persona y un proyecto con el mismo nombre nunca se funden")
    func differentKindsNeverMerge() {
        // Es la peor fusión posible: cada pregunta sobre cualquiera de los dos devolvería una
        // mezcla de ambos, y desde fuera no se ve.
        let persona = Entity(kind: .person, canonical: "Acme")
        let proyecto = Entity(kind: .project, canonical: "Acme")
        #expect(Identity.decide(persona, proyecto) == .leaveAlone)
    }

    @Test("Dos nombres iguales salvo mayúsculas y guiones ni siquiera llegan a ser dos entidades")
    func sameNameIsAlreadyOne() {
        // La identidad se deriva del nombre plegado, así que "waw-trips" y "WAW Trips" nacen
        // con el mismo identificador. No hay nada que fundir porque nunca se separaron: es más
        // barato que cualquier fusión y no puede equivocarse.
        #expect(project("waw-trips").id == project("WAW Trips").id)
    }

    @Test("Dos entidades distintas que comparten un alias se funden sin preguntar")
    func conclusiveMergeByAlias() {
        // Aquí sí hay dos: una nació de una carpeta y otra de cómo la llama la gente, y solo
        // se descubre que son la misma cuando aparece el alias.
        let deLaCarpeta = Entity(kind: .project, canonical: "waw-trips-2026", aliases: ["WAW Trips"])
        let deLaGente = project("WAW Trips")
        #expect(Identity.decide(deLaCarpeta, deLaGente) == .merge(.sameName))
    }

    @Test("Una carpeta que contiene el nombre del proyecto también basta")
    func pathMerge() {
        let verdict = Identity.decide(project("developer waw trips"), project("WAW Trips"))
        #expect(verdict == .merge(.pathMatch))
    }

    @Test("Aparecer juntas mucho solo da para preguntar, nunca para fundir")
    func coOccurrenceOnlyAsks() {
        let verdict = Identity.decide(project("propuesta"), project("acme"), together: 12)
        guard case .ask(let proposal) = verdict else {
            Issue.record("debería preguntar, no decidir"); return
        }
        #expect(proposal.reason == .seenTogether)
        #expect(proposal.question.contains("turn up together"))
    }

    @Test("Aparecer juntas pocas veces no es nada")
    func weakCoOccurrence() {
        #expect(Identity.decide(project("propuesta"), project("acme"), together: 3) == .leaveAlone)
    }

    @Test("Una fusión rechazada no se vuelve a proponer nunca")
    func rejectionSticks() {
        let a = project("propuesta"), b = project("acme")
        guard case .ask(let proposal) = Identity.decide(a, b, together: 12) else {
            Issue.record("debería preguntar"); return
        }
        // Corregir tiene que servir de algo: volver a preguntar convierte enseñar en discutir.
        #expect(Identity.decide(a, b, together: 12, rejected: [proposal.id]) == .leaveAlone)
    }

    @Test("El rechazo vale en los dos sentidos")
    func rejectionIsSymmetric() {
        let a = project("propuesta"), b = project("acme")
        let proposal = MergeProposal(left: "acme", right: "propuesta", reason: .seenTogether)
        #expect(Identity.decide(a, b, together: 12, rejected: [proposal.id]) == .leaveAlone)
    }

    @Test("Al fundir gana el nombre más usado y el otro sobrevive como alias")
    func mergeKeepsBothNames() {
        let merged = Identity.merge(project("waw-trips", weight: 2), project("WAW Trips", weight: 9))
        #expect(merged.canonical == "WAW Trips")
        #expect(merged.answers(to: "waw-trips"))
        #expect(merged.weight == 11)
    }

    @Test("Las carpetas que tiene todo el mundo no son proyectos")
    func genericFolders() {
        for name in ["src", "docs", "build", "Desktop", "Descargas", "node_modules"] {
            #expect(Identity.isGeneric(name), "\(name) no debería ser una entidad")
        }
        #expect(!Identity.isGeneric("waw-trips"))
    }

    @Test("De una ruta sale el proyecto, no la carpeta genérica ni el archivo")
    func projectFromPath() {
        #expect(Identity.project(fromPath: "/Users/mac/Developer/waw-trips/src/index.ts") == "waw-trips")
        #expect(Identity.project(fromPath: "/Users/mac/Developer/belauncher/docs/manual.md") == "belauncher")
    }

    @Test("Una ruta sin nada significativo no inventa un proyecto")
    func pathWithoutProject() {
        #expect(Identity.project(fromPath: "/tmp/src/a.txt") == nil)
        #expect(Identity.project(fromPath: "a.txt") == nil)
    }

    @Test("Del correo de trabajo sale la empresa; del correo personal, nada")
    func companyFromEmail() {
        #expect(Identity.company(fromEmail: "jorge@believe-global.com") == "believe-global")
        #expect(Identity.company(fromEmail: "alguien@gmail.com") == nil)
        #expect(Identity.company(fromEmail: "sin-arroba") == nil)
    }

    @Test("Un trozo de palabra dentro de otra no cuenta como coincidencia")
    func noSubstringMatches() {
        // «waw» dentro de «wawa» es una casualidad. Fundir por ahí contamina el grafo entero.
        #expect(Identity.isPathwise("wawa", "waw") == false)
        #expect(Identity.isPathwise("developer waw trips", "waw trips"))
    }

    @Test("Una entidad reconoce todos sus nombres")
    func answersToAliases() {
        let entity = Entity(kind: .project, canonical: "WAW Trips", aliases: ["waw-trips", "waw"])
        #expect(entity.answers(to: "waw_trips"))
        #expect(entity.answers(to: "WAW TRIPS"))
        #expect(!entity.answers(to: "otro"))
    }
}
