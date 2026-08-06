import Testing
import Foundation
@testable import BeLauncherCore

/// La regla que ordena todo este archivo: **el idioma de la interfaz y el del usuario que escribe
/// son cosas distintas.** Quien vive en Miami trabaja en inglés y le escribe a su familia en
/// español; su Mac está en un idioma y su cabeza en dos. Cada prueba de aquí comprueba que el
/// lanzador entiende las dos sin que nadie configure nada.
@Suite("Frases y idioma en la lógica")
struct PhrasesTests {

    // MARK: - Lo que se puede escribir

    @Test("guardar un espacio se pide igual en inglés que en español")
    func guardarEspacio() {
        #expect(WorkspaceLayouts.Intent.detect("save workspace escritura") == .save("escritura"))
        #expect(WorkspaceLayouts.Intent.detect("guardar espacio escritura") == .save("escritura"))
        #expect(WorkspaceLayouts.Intent.detect("save layout writing") == .save("writing"))
    }

    @Test("restaurar y listar espacios también entienden los dos idiomas")
    func restaurarEspacio() {
        #expect(WorkspaceLayouts.Intent.detect("workspace writing") == .restore("writing"))
        #expect(WorkspaceLayouts.Intent.detect("espacio escritura") == .restore("escritura"))
        #expect(WorkspaceLayouts.Intent.detect("workspaces") == .list)
        #expect(WorkspaceLayouts.Intent.detect("espacios") == .list)
    }

    @Test("guardar gana sobre restaurar, aunque la frase empiece por la otra palabra")
    func guardarNoSeConfundeConRestaurar() {
        // "guardar espacio X" contiene "espacio ", que es el prefijo de restaurar. Confundirlos
        // significa recolocar ventanas cuando alguien quería justo lo contrario.
        #expect(WorkspaceLayouts.Intent.detect("guardar espacio demo") == .save("demo"))
    }

    @Test("preguntarle al cerebro qué se decidió funciona en los dos idiomas")
    func queDecidimos() {
        #expect(BrainQuery.Intent.detect("what did we decide about pricing")
                == .whatDidWeDecide(topic: "pricing"))
        #expect(BrainQuery.Intent.detect("qué decidimos sobre precios")
                == .whatDidWeDecide(topic: "precios"))
        #expect(BrainQuery.Intent.detect("what's the decision on pricing")
                == .whatDidWeDecide(topic: "pricing"))
    }

    @Test("el tema conserva sus acentos y sus mayúsculas camino de la búsqueda")
    func temaSinAplanar() {
        // Se recorta del texto original, no del plegado: buscar «reunión con José» por «reunion
        // con jose» encuentra menos, y el nombre propio aparece luego en pantalla sin tildes.
        #expect(BrainQuery.Intent.detect("qué decidimos sobre Precios Acme")
                == .whatDidWeDecide(topic: "Precios Acme"))
        #expect(BrainQuery.Intent.detect("prepare me for reunión con José")
                == .prepare(subject: "reunión con José"))
    }

    @Test("preparar, recordar y el pulso responden en inglés")
    func restoDeIntenciones() {
        #expect(BrainQuery.Intent.detect("brief me on Acme") == .prepare(subject: "Acme"))
        #expect(BrainQuery.Intent.detect("preparame para Acme") == .prepare(subject: "Acme"))
        #expect(BrainQuery.Intent.detect("remember we raised the price")
                == .remember(text: "we raised the price"))
        #expect(BrainQuery.Intent.detect("recordar que subimos el precio")
                == .remember(text: "que subimos el precio"))
        #expect(BrainQuery.Intent.detect("what's at risk") == .pulse)
        #expect(BrainQuery.Intent.detect("qué está en riesgo") == .pulse)
    }

    @Test("el grafo de trabajo se pregunta igual en inglés")
    func grafoEnIngles() {
        #expect(WorkQuery.Intent.detect("what did we promise Andrés") == .promisedTo("andres"))
        #expect(WorkQuery.Intent.detect("qué prometimos a Andrés") == .promisedTo("andres"))
        #expect(WorkQuery.Intent.detect("who is Acme") == .about("acme"))
        #expect(WorkQuery.Intent.detect("quién es Acme") == .about("acme"))
        #expect(WorkQuery.Intent.detect("pick up where i left off") == .resumeBefore)
        #expect(WorkQuery.Intent.detect("en qué estaba") == .resumeBefore)
    }

    @Test("los verbos de IA se invocan en cualquiera de los dos idiomas")
    func verbosBilingues() throws {
        let español = try #require(AIVerb.typed("resumir esto"))
        let inglés = try #require(AIVerb.typed("summarise this"))
        #expect(español.verb.id == "summarise")
        #expect(inglés.verb.id == "summarise")
        #expect(inglés.argument == "this")
    }

    @Test("un disparador largo sigue ganando al corto que lo contiene")
    func disparadorMasLargoGana() throws {
        let found = try #require(AIVerb.typed("translate to spanish the note"))
        #expect(found.verb.id == "translate-es")
    }

    // MARK: - Las palabras que no cuentan

    @Test("las palabras vacías se quitan en los dos idiomas, no solo en español")
    func palabrasVacias() {
        // Con la lista solo en español, «the price of the plan» conservaba cada palabra funcional
        // y dos memorias sobre lo mismo parecían no tener nada que ver.
        #expect(Phrases.significantWords("the price of the plan") == ["price", "plan"])
        #expect(Phrases.significantWords("el precio del plan") == ["precio", "plan"])
    }

    @Test("una palabra corta o con acento no despista a la comparación")
    func palabrasCortas() {
        #expect(Phrases.significantWords("Acción rápida y ya") == ["accion", "rapida"])
    }

    @Test("dos memorias equivalentes en inglés comparten las palabras que cuentan")
    func solapeEnIngles() {
        // Es el cálculo que decide si una memoria sustituye a otra. Con las vacías solo en
        // español, estas dos frases compartían «pro», «plan» y también «the», «costs» — cada
        // palabra funcional diluye el parecido y el conflicto pasaba desapercibido.
        let existing = Set(Phrases.significantWords("The Pro plan costs 49"))
        let incoming = Set(Phrases.significantWords("The Pro plan costs 59"))
        let shared = existing.intersection(incoming).count
        let similarity = Double(shared) / Double(min(existing.count, incoming.count))
        #expect(similarity >= 0.7)
    }

    // MARK: - El idioma del material

    @Test("cada texto se corta en el idioma que tiene, no en uno global")
    func corteBilingue() {
        // Un corpus con las dos lenguas es lo normal, no la excepción, y las abreviaturas no
        // coinciden: partir «Sr. García» o «Mr. Smith» por la mitad deja al buscador un trozo.
        #expect(Semantic.sentences(of: "Hablé con el Sr. García ayer.").count == 1)
        #expect(Semantic.sentences(of: "I spoke with Mr. Smith yesterday.").count == 1)
    }

    @Test("el suelo de idioma del corpus vive aparte del idioma de la interfaz")
    func sueloDeIdioma() {
        // Dos ajustes distintos a propósito, y ninguno lee al otro. Se comprueba por construcción
        // en vez de moviendo el global: las pruebas corren en paralelo y tocar `Loc.language` aquí
        // haría fallar a otra por un motivo que no tiene nada que ver con lo que prueba.
        #expect(Phrases.corpusFallback == .english)
        #expect(Semantic.sentences(of: "Hablé con el Sr. García ayer.").count == 1)
    }

    // MARK: - Lo que se le pide al modelo

    @Test("los prompts van en inglés y le dicen al modelo en qué idioma contestar")
    func promptsEnIngles() {
        let (system, _) = Retriever.prompt(for: "cuánto cobramos", hits: [])
        #expect(system.contains("same language as the question"))
        // La regla que no puede diluirse en ninguna traducción.
        #expect(system.contains("Do not fill gaps with your own knowledge"))

        let (distill, _) = Distillation.prompt(for: [])
        #expect(distill.contains("Do not invent"))
        #expect(distill.contains("language the episodes are in"))
    }

    @Test("las instrucciones de los verbos no fijan el idioma de la salida al de la interfaz")
    func verbosRespetanElTexto() {
        // Resumir una nota en español tiene que devolver español, esté la app como esté.
        let summarise = AIVerb.all.first { $0.id == "summarise" }
        #expect(summarise?.instruction.contains("in the language of the text") == true)
    }
}
