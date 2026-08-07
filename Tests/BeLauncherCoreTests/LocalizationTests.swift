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
            // Solo en cadenas de una línea. La regla existe para cazar descuidos al escribir una
            // etiqueta; un documento Markdown —el LÉEME del cerebro, por ejemplo— lleva sangrías y
            // continuaciones de lista con dos espacios porque así se escribe Markdown, y aplicarle
            // esta regla obligaría a estropear el documento para contentar al test.
            if !spanish.contains("\n") {
                #expect(!spanish.contains("  "), "Doble espacio en «\(spanish)»")
            }
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
    // MARK: - Que no se cuele español escrito a pelo

    /// La prueba que faltaba, y la que habría evitado el desastre.
    ///
    /// `nadaSinTraducir` cubre una dirección: una cadena que pasa por `L(` y no tiene español. La
    /// otra dirección es la que se vio en pantalla: cientos de literales en español escritos
    /// directamente en un `Text(…)`, que en un Mac en inglés salían en español dentro de una
    /// ventana inglesa. Ninguna prueba lo miraba porque el catálogo estaba perfecto: el problema
    /// era todo lo que nunca llegó a él.
    ///
    /// El escáner es deliberadamente tosco —busca caracteres y palabras que solo existen en
    /// español— y por eso lleva una lista de excepciones explicada. Una excepción es una decisión
    /// escrita, no un descuido: si algo entra aquí es porque no es texto de interfaz.
    @Test("ningún texto de interfaz se quedó escrito en español a pelo")
    func nadaEnEspañolSinCatalogo() throws {
        let sources = try #require(sourceFiles())
        var leaked: [String] = []

        for file in sources where !exempt.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (line, literal) in bareLiterals(in: text) where looksSpanish(literal) {
                guard !allowed.contains(literal) else { continue }
                leaked.append("\(file.lastPathComponent):\(line) — \(literal)")
            }
        }

        #expect(leaked.isEmpty,
                Comment(rawValue: "Español escrito a pelo, fuera del catálogo:\n"
                                  + leaked.sorted().joined(separator: "\n")))
    }

    /// Archivos que no son interfaz. Cada uno con su motivo, porque una lista de excepciones sin
    /// motivos se convierte en el sitio donde se esconde el trabajo sin hacer.
    private var exempt: Set<String> {
        [
            // El catálogo: su lado español es español a propósito.
            "SpanishStrings.swift", "SpanishStrings+Tables.swift", "SpanishStrings+Interface.swift",
            // Frases que la persona teclea. Son datos que el buscador reconoce, no texto que la app
            // dice; traducirlas rompería lo que el usuario ya sabe escribir.
            "Phrases.swift", "AIVerbs.swift", "Mission.swift", "Calculator.swift",
            // Salida de diagnóstico por terminal (`--diagnose-…`), que no es la interfaz.
            "main.swift",
            // El propio nombre de este idioma, que se escribe en ese idioma.
            "Localization.swift",
        ]
    }

    /// Literales sueltos que no son interfaz: nombres de archivo en el disco del usuario y
    /// formatos de fecha.
    private var allowed: Set<String> {
        [
            // Nombres de archivo en el disco de la persona y un formato de fecha.
            "LÉEME.md", "QUÉ VA AQUÍ.md", "LÉEME — corpus.md", "d 'de' MMMM 'de' yyyy",
            // Etiquetas internas del índice, no texto que se lea en pantalla.
            "conversación", "Conversación",
            // Palabras que el detector de credenciales busca dentro del texto copiado: son el
            // patrón, no un mensaje. Traducirlas dejaría de detectar la clave que buscan.
            "CLAVE",
            // Lo que la persona teclea para disparar algo. Son datos que el buscador reconoce; si
            // se traducen, deja de funcionar lo que ya sabía escribir.
            "salir", "cerrar sesión", "que no se duerma", "nº de factura", "cerebro", "memoria",
            "grafo", "asunto:",
            "pantalla", "papelera", "carpeta escritorio", "portapapeles", "nota ", "nota", "/nota ",
            "cpu · memoria", "espacio trabajo · espacios",
            "que consume", "que esta lento", "un abrazo", "con-guiones", "con_guiones_bajos",
            "con espacios",
            // Los signos que el troceador de MCP corta, y una plantilla de línea de portapapeles.
            "*_`~'\"“”‘’«»()[]{}<>,;:.…·—–- ",
            // Frase de prueba del reconocedor de voz: se compara contra lo que devuelve el modelo.
            "el modelo de voz funciona sin conexion a internet",
        ]
    }

    /// Marcas que en la práctica solo aparecen en español. No pretende detectar el idioma: sólo
    /// tiene que ser suficiente para que un párrafo escrito en español no pase desapercibido.
    private func looksSpanish(_ text: String) -> Bool {
        // Lo que no es prosa: una interpolación sola, una URL, un código de idioma, una ruta.
        let bare = text.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("("), bare.hasSuffix(")") { return false }
        if bare.contains("://") || bare.contains("{query}") { return false }
        if bare.range(of: "^[a-z]{2}[-_][A-Z]{2}$", options: .regularExpression) != nil { return false }
        if text.contains(where: { "áéíóúñ¿¡«»Ñ".contains($0) }) { return true }
        let pieces = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        // Palabras de función: solo cuentan si hay más de una palabra, porque sueltas aparecen en
        // identificadores y en inglés ("la" de un nombre propio, por ejemplo).
        let grammar: Set<String> = ["el", "la", "los", "las", "del", "para", "con", "una", "que",
                                    "por", "sin", "desde", "hasta", "esto", "esta", "todo", "nada",
                                    "pero", "como", "cuando", "porque", "tus", "sus", "de", "en",
                                    "se", "su", "lo", "al", "un", "ya", "muy", "cada", "otra"]
        if pieces.count > 1, pieces.contains(where: grammar.contains) { return true }
        // Y las etiquetas de una sola palabra, que son justo las que más se ven y las que ninguna
        // heurística gramatical caza: un botón que pone "Guardar" no tiene ninguna palabra de
        // función que delate el idioma.
        let labels: Set<String> = ["abrir", "guardar", "cancelar", "cerrar", "borrar", "buscar",
                                   "ajustes", "acciones", "copiar", "mostrar", "añadir", "ninguno",
                                   "ninguna", "listo", "reintentar", "aceptar", "enviar", "editar",
                                   "nombre", "correo", "clave", "versión", "idioma", "equipo",
                                   "tamaño", "recientes", "cargando", "vacío", "sonido",
                                   "actualizaciones", "descargando", "instalando", "salir",
                                   "continuar", "siguiente", "atrás", "hecho", "activar",
                                   "desactivar", "conectar", "compartir", "importar", "exportar",
                                   "memoria", "trabajo", "portapapeles", "nota", "fuentes",
                                   "reunión", "decisión", "conversación", "misión", "misiones",
                                   "propuesta", "pantalla", "ventana", "ventanas", "archivo",
                                   "carpeta", "permiso", "permisos", "papelera", "cerebro",
                                   "episodio", "persona", "proyecto", "empresa", "asunto", "cosa",
                                   "nodos", "relaciones"]
        return pieces.contains(where: labels.contains)
    }

    /// Literales que NO están dentro de una llamada a `L(`. Ignora comentarios, que es donde se
    /// explica el porqué de las cosas y donde el español es bienvenido.
    func bareLiterals(in source: String) -> [(Int, String)] {
        var result: [(Int, String)] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            let inside = Set(localisedLiterals(in: String(raw)))
            for literal in allLiterals(in: String(raw)) where !inside.contains(literal) {
                result.append((index + 1, literal))
            }
        }
        return result
    }

    /// Todos los literales de una línea, pasen o no por `L(`.
    private func allLiterals(in source: String) -> [String] {
        var result: [String] = []
        var literal = ""
        var open = false
        var escaped = false
        for character in source {
            if escaped { if open { literal.append(character) }; escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" {
                if open, !literal.isEmpty { result.append(literal) }
                literal = ""
                open.toggle()
                continue
            }
            if open { literal.append(character) }
        }
        return result
    }

}
