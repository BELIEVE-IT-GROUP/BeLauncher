import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Cortar texto en pasajes")
struct PassageTests {

    @Test("Un texto corto es un solo pasaje")
    func short() {
        let passages = Semantic.passages(of: "El precio base del plan Pro es 1000 euros al mes.")
        #expect(passages.count == 1)
        #expect(passages[0].ordinal == 0)
    }

    @Test("Un fragmento demasiado corto no se indexa")
    func fragment() {
        #expect(Semantic.passages(of: "Notas").isEmpty)
        #expect(Semantic.passages(of: "").isEmpty)
    }

    @Test("Un texto largo se parte en varios y conserva el orden")
    func long() {
        let sentence = "Esta es una frase de prueba con suficiente longitud para llenar el pasaje. "
        let passages = Semantic.passages(of: String(repeating: sentence, count: 40))
        #expect(passages.count > 1)
        #expect(passages.map(\.ordinal) == Array(0..<passages.count))
    }

    @Test("Los pasajes se solapan, así una frase partida sobrevive en uno de los dos")
    func overlap() {
        let filler = String(repeating: "relleno de contexto anterior. ", count: 30)
        let marker = "la decisión fue subir el precio a 59 euros."
        let passages = Semantic.passages(of: filler + marker + " " + filler)
        // La frase marcada cae cerca de una frontera; con solape tiene que aparecer entera.
        #expect(passages.contains { $0.text.contains(marker) })
    }

    @Test("Una sola frase más larga que un pasaje se corta igualmente")
    func giant() {
        let passages = Semantic.passages(of: String(repeating: "x", count: 3_000))
        #expect(passages.count >= 4)
        #expect(passages.allSatisfy { $0.text.count <= Semantic.targetCharacters + Semantic.overlapCharacters })
    }

    @Test("Ninguna abreviatura corriente parte una frase por la mitad")
    func abbreviations() {
        let text = "Hablé con el Sr. García sobre el contrato. Quedamos el jueves."
        #expect(Semantic.sentences(of: text).count == 2)
    }
}

@Suite("Vectores")
struct VectorTests {

    @Test("Normalizar deja el vector con longitud 1")
    func normalise() {
        let unit = Semantic.normalise([3, 4, 0])
        let length = sqrt(unit.reduce(0) { $0 + $1 * $1 })
        #expect(abs(length - 1) < 1e-5)
    }

    @Test("Un vector de ceros no se convierte en NaN")
    func zero() {
        let result = Semantic.normalise([0, 0, 0])
        #expect(result.allSatisfy { !$0.isNaN })
    }

    @Test("Un vector consigo mismo da 1, con su opuesto da -1")
    func similarity() {
        let a = Semantic.normalise([1, 2, 3])
        #expect(abs(Semantic.similarity(a, a) - 1) < 1e-5)
        #expect(abs(Semantic.similarity(a, a.map { -$0 }) + 1) < 1e-5)
    }

    @Test("Vectores de distinto tamaño no se comparan a medias")
    func mismatched() {
        #expect(Semantic.similarity([1, 0], [1, 0, 0]) == 0)
    }

    @Test("Guardar y leer un vector devuelve exactamente lo mismo")
    func roundTrip() {
        let original = Semantic.normalise((0..<512).map { Float($0) * 0.017 - 3 })
        let recovered = Semantic.decode(Semantic.encode(original))
        #expect(recovered.count == original.count)
        for (a, b) in zip(original, recovered) { #expect(abs(a - b) < 1e-6) }
    }

    @Test("Promediar vectores de tokens da un vector unitario")
    func pooling() {
        let pooled = Semantic.pool([[1, 0, 0], [0, 1, 0]])
        #expect(abs(sqrt(pooled.reduce(0) { $0 + $1 * $1 }) - 1) < 1e-5)
    }
}

@Suite("Fusionar dos rankings")
struct FusionTests {

    @Test("Lo que aparece en ambas listas gana a lo que solo aparece en una")
    func agreement() {
        let fused = Semantic.fuse([["a", "b", "c"], ["c", "a", "z"]])
        #expect(fused.first?.id == "a")
        #expect(fused.contains { $0.id == "z" })
    }

    @Test("Fusionar por posición y no por puntuación")
    func byRank() {
        // Aunque una lista tuviera puntuaciones enormes, solo cuenta el puesto.
        let fused = Semantic.fuse([["solo-en-primera"], ["x", "y", "z", "solo-en-primera"]])
        #expect(fused.first?.id == "solo-en-primera")
    }

    @Test("Una lista vacía no rompe la fusión")
    func empty() {
        #expect(Semantic.fuse([[], ["a"]]).first?.id == "a")
        #expect(Semantic.fuse([]).isEmpty)
    }

    @Test("El resultado es estable ante empates")
    func deterministic() {
        let first = Semantic.fuse([["a", "b"], ["b", "a"]])
        let second = Semantic.fuse([["a", "b"], ["b", "a"]])
        #expect(first.map(\.id) == second.map(\.id))
    }
}

@Suite("Consulta de texto completo")
struct FTSQueryTests {

    @Test("Un apóstrofo no rompe la búsqueda")
    func apostrophe() {
        let query = Semantic.ftsQuery("l'accord d'Acme")
        #expect(!query.isEmpty)
        #expect(query.contains("\"accord\""))
    }

    @Test("Las palabras sueltas de una letra se descartan")
    func tiny() {
        #expect(Semantic.ftsQuery("a e i").isEmpty)
    }

    @Test("La última palabra lleva comodín para buscar mientras se escribe")
    func prefix() {
        #expect(Semantic.ftsQuery("precio pl").hasSuffix("\"pl\"*"))
    }

    @Test("Los operadores de FTS5 no se cuelan como sintaxis")
    func operators() {
        let query = Semantic.ftsQuery("NEAR OR \"algo\"")
        #expect(!query.contains("\"NEAR\" NEAR"))
        #expect(query.hasPrefix("\"NEAR\""))
    }
}

@Suite("Huella de contenido")
struct DigestTests {

    @Test("El mismo texto da la misma huella y otro texto una distinta")
    func stable() {
        #expect(Semantic.digest("hola") == Semantic.digest("hola"))
        #expect(Semantic.digest("hola") != Semantic.digest("hola "))
    }
}
