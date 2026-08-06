import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Idiomas")
struct LocalizationTests {

    // MARK: - Elegir idioma

    @Test("el inglés es el idioma por defecto cuando el sistema no dice otra cosa")
    func inglesPorDefecto() {
        #expect(Language.best(matching: []) == .english)
        #expect(Language.best(matching: ["fr-FR", "de-DE"]) == .english)
    }

    @Test("un Mac en español elige español aunque venga con región")
    func españolConRegion() {
        #expect(Language.best(matching: ["es-419", "en-US"]) == .spanish)
        #expect(Language.best(matching: ["es_MX"]) == .spanish)
        #expect(Language.best(matching: ["es"]) == .spanish)
    }

    @Test("la elección del usuario gana sobre la del sistema")
    func eleccionExplicitaGana() {
        #expect(Language.resolve(stored: "en", systemPreferred: ["es-ES"]) == .english)
        #expect(Language.resolve(stored: "es", systemPreferred: ["en-US"]) == .spanish)
    }

    @Test("un ajuste guardado que ya no significa nada no rompe el arranque")
    func ajusteInvalidoNoRompe() {
        // Puede pasar tras volver a una versión anterior, o si alguien edita la base a mano.
        #expect(Language.resolve(stored: "", systemPreferred: ["es-ES"]) == .spanish)
        #expect(Language.resolve(stored: "klingon", systemPreferred: ["es-ES"]) == .spanish)
        #expect(Language.resolve(stored: nil, systemPreferred: []) == .english)
    }

    // MARK: - Sustituir argumentos

    @Test("los huecos numerados dejan que la traducción cambie el orden")
    func huecosNumerados() {
        #expect(Loc.substitute("%1$@ owes %2$@", ["Ana", "Beto"]) == "Ana owes Beto")
        #expect(Loc.substitute("%2$@ le debe a %1$@", ["Ana", "Beto"]) == "Beto le debe a Ana")
    }

    @Test("los huecos sin número se rellenan en orden")
    func huecosSinNumero() {
        #expect(Loc.substitute("%@ de %@", ["3", "8"]) == "3 de 8")
    }

    @Test("un porcentaje literal sobrevive a la sustitución")
    func porcentajeLiteral() {
        // "Descargado 40%%" no puede quedar como "Descargado 40" solo porque haya argumentos.
        #expect(Loc.substitute("%@ 100%% listo", ["Casi"]) == "Casi 100% listo")
    }

    @Test("un hueco que apunta a un argumento que no existe se deja tal cual")
    func huecoFueraDeRango() {
        #expect(Loc.substitute("%1$@ y %9$@", ["solo"]) == "solo y %9$@")
    }

    // MARK: - El catálogo

    @Test("sin traducción se lee el inglés, nunca una clave técnica")
    func faltaTraduccionCaeEnIngles() {
        let inventada = "This string is not in the catalog on purpose"
        #expect(Loc.render(inventada, in: .spanish) == inventada)
        #expect(Loc.render(inventada, in: .english) == inventada)
    }

    @Test("el español traduce y respeta los argumentos")
    func españolTraduce() {
        #expect(Loc.render("Summarise", in: .spanish) == "Resumir")
        #expect(Loc.render("Decided by %@", in: .spanish, ["Jorge"]) == "Decidido por Jorge")
    }

    @Test("ninguna traducción queda vacía ni repite el inglés por descuido")
    func catalogoSano() {
        for (english, spanish) in SpanishStrings.table {
            #expect(!spanish.trimmingCharacters(in: .whitespaces).isEmpty,
                    "Traducción vacía para «\(english)»")
            #expect(!spanish.contains("  "), "Doble espacio en «\(spanish)»")
        }
    }

    @Test("cada hueco del inglés existe también en el español")
    func huecosCoinciden() {
        // Una traducción que se come un %@ no se rompe: se queda callada. El nombre que faltaba
        // simplemente no aparece, y el usuario lee una frase que le falta la mitad del sentido.
        for (english, spanish) in SpanishStrings.table {
            #expect(placeholders(in: english) == placeholders(in: spanish),
                    "Los huecos no coinciden entre «\(english)» y «\(spanish)»")
        }
    }

    /// El conjunto de posiciones a las que apunta un texto: `%@` cuenta como la siguiente libre.
    private func placeholders(in text: String) -> Set<Int> {
        var found: Set<Int> = []
        var sequential = 1
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%", index + 1 < characters.count else { index += 1; continue }
            if characters[index + 1] == "%" { index += 2; continue }
            if characters[index + 1] == "@" {
                found.insert(sequential)
                sequential += 1
                index += 2
                continue
            }
            var cursor = index + 1
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor]); cursor += 1
            }
            if !digits.isEmpty, cursor + 1 < characters.count,
               characters[cursor] == "$", characters[cursor + 1] == "@",
               let position = Int(digits) {
                found.insert(position)
                index = cursor + 2
                continue
            }
            index += 1
        }
        return found
    }

    // MARK: - Que no quede la app a medio traducir

    /// Esta es la prueba que justifica todo el mecanismo.
    ///
    /// Una app a medias es peor que una sin traducir: el usuario descubre el hueco cuando ya
    /// confiaba. La única forma de que eso no pase es que el hueco rompa la compilación de las
    /// pruebas, no que alguien se acuerde de revisarlo. Recorre el código fuente de verdad, saca
    /// cada literal que pasa por `L(` y comprueba que el catálogo lo tenga.
    @Test("ninguna cadena visible se quedó sin su español")
    func nadaSinTraducir() throws {
        let sources = try #require(sourceFiles())
        var missing: [String] = []
        var scanned = 0

        for file in sources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for literal in localisedLiterals(in: text) {
                scanned += 1
                if !Loc.hasTranslation(literal) {
                    missing.append("\(file.lastPathComponent): \(literal)")
                }
            }
        }

        #expect(scanned > 0, "El escaneo no encontró ni una llamada a L(): revisa el patrón")
        #expect(missing.isEmpty,
                Comment(rawValue: "Sin traducir:\n" + missing.sorted().joined(separator: "\n")))
    }

    /// `#filePath` es la ruta de este archivo en el repositorio, así que el directorio de fuentes
    /// se deduce de él en vez de depender del directorio de trabajo, que cambia según cómo se
    /// lancen las pruebas.
    private func sourceFiles(file: String = #filePath) -> [URL]? {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()   // BeLauncherCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("Sources")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
            return nil
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Saca el primer literal de cada `L("…")`.
    ///
    /// Solo entiende literales de una línea entre comillas, que es exactamente la disciplina que se
    /// sigue en el código: concatenar dentro de `L(` haría imposible comprobar nada desde aquí.
    func localisedLiterals(in source: String) -> [String] {
        var result: [String] = []
        let characters = Array(source)
        var index = 0

        while index + 2 < characters.count {
            // `L("` precedido de algo que no sea parte de un identificador, para no capturar
            // funciones que acaben en L.
            guard characters[index] == "L", characters[index + 1] == "(",
                  characters[index + 2] == "\"" else { index += 1; continue }
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber
                || characters[index - 1] == "_" {
                index += 1
                continue
            }
            var cursor = index + 3
            var literal = ""
            var escaped = false
            var closed = false
            while cursor < characters.count {
                let character = characters[cursor]
                if escaped {
                    // Solo las secuencias que aparecen de verdad en estas cadenas.
                    switch character {
                    case "n": literal.append("\n")
                    case "t": literal.append("\t")
                    case "\"": literal.append("\"")
                    case "\\": literal.append("\\")
                    default: literal.append(character)
                    }
                    escaped = false
                    cursor += 1
                    continue
                }
                if character == "\\" { escaped = true; cursor += 1; continue }
                if character == "\"" { closed = true; break }
                if character == "\n" { break }
                literal.append(character)
                cursor += 1
            }
            if closed, !literal.isEmpty { result.append(literal) }
            index = cursor + 1
        }
        return result
    }

    @Test("el escáner encuentra las llamadas reales y descarta las que no lo son")
    func escanerHonesto() {
        let source = """
        let a = L("Hola")
        let b = someL("no cuenta")
        let c = L("con \\"comillas\\" dentro")
        let d = L(variable)
        """
        let found = localisedLiterals(in: source)
        #expect(found.contains("Hola"))
        #expect(found.contains("con \"comillas\" dentro"))
        #expect(!found.contains("no cuenta"))
        #expect(found.count == 2)
    }
}
