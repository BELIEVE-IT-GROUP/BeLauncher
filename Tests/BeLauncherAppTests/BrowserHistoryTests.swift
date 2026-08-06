import Testing
import Foundation
import SQLite3
@testable import BeLauncher
@testable import BeLauncherCore

/// El historial del navegador, leído contra bases de datos de verdad.
///
/// Se construyen archivos SQLite con el esquema real de Safari y de Chrome en una carpeta temporal
/// y se le pasa esa carpeta como `home`. No hace falta ningún navegador instalado y no se toca el
/// historial de nadie, pero lo que se ejercita es el código que corre en producción: la consulta,
/// la conversión de fechas y el filtro de exclusiones, en el mismo orden.
///
/// Existe porque hasta ahora no existía: la auditoría borró el filtro de exclusiones entero y las
/// 839 pruebas siguieron en verde, así que un historial bancario podía entrar al cerebro sin que
/// nada se pusiera rojo.
@Suite("Historial del navegador")
struct BrowserHistoryTests {

    // MARK: - Instantes conocidos

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Un instante fijo, escrito como lo escribiría una persona, para que la comprobación de las
    /// épocas no se haga contra la misma constante que usa el código.
    private static func moment(day: Int, hour: Int, minute: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 1, day: day,
                                      hour: hour, minute: minute, second: 0))!
    }

    /// Segundos desde 2001-01-01, que es lo que guarda Safari en `visit_time`.
    private static func safariTime(_ date: Date) -> Double {
        date.timeIntervalSince1970 - 978_307_200
    }

    /// Microsegundos desde 1601-01-01, que es lo que guarda Chrome en `last_visit_time`.
    private static func chromeTime(_ date: Date) -> Double {
        (date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
    }

    // MARK: - Bases de datos de mentira con esquema de verdad

    private struct Visit {
        let at: Date
        let url: String
        let title: String
    }

    private final class Home {
        let path: String

        init() {
            path = FileManager.default.temporaryDirectory
                .appendingPathComponent("belauncher-history-test-\(UUID().uuidString)").path
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }

        func makeFolder(_ relative: String) -> String {
            let full = (path as NSString).appendingPathComponent(relative)
            try? FileManager.default.createDirectory(atPath: full,
                                                     withIntermediateDirectories: true)
            return full
        }
    }

    private static func write(_ path: String, schema: [String], rows: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            Issue.record("no se pudo crear \(path)")
            return
        }
        defer { sqlite3_close_v2(handle) }
        for statement in schema + rows {
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
                Issue.record("SQL rechazado: \(statement)")
                return
            }
        }
    }

    private static func makeSafari(in home: Home, visits: [Visit]) throws {
        let folder = home.makeFolder("Library/Safari")
        let rows = visits.enumerated().flatMap { index, visit -> [String] in
            [
                "INSERT INTO history_items (id, url) VALUES (\(index), '\(visit.url)')",
                """
                INSERT INTO history_visits (id, history_item, visit_time, title)
                VALUES (\(index), \(index), \(safariTime(visit.at)), '\(visit.title)')
                """,
            ]
        }
        try write((folder as NSString).appendingPathComponent("History.db"), schema: [
            "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT)",
            """
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER,
                                         visit_time REAL, title TEXT)
            """,
        ], rows: rows)
    }

    private static func makeChrome(in home: Home, profile: String, visits: [Visit]) throws {
        let folder = home.makeFolder("Library/Application Support/Google/Chrome/\(profile)")
        let rows = visits.enumerated().flatMap { index, visit -> [String] in
            [
                "INSERT INTO urls (id, url, title) VALUES (\(index), '\(visit.url)', '\(visit.title)')",
                """
                INSERT INTO visits (id, url, visit_time)
                VALUES (\(index), \(index), \(String(format: "%.0f", chromeTime(visit.at))))
                """,
            ]
        }
        try write((folder as NSString).appendingPathComponent("History"), schema: [
            "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT)",
            "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)",
        ], rows: rows)
    }

    /// Cualquier cosa anterior a lo que se guarda en las bases de prueba.
    private static var beginning: Date { moment(day: 1, hour: 0, minute: 0) }

    // MARK: - Las épocas

    @Test("una visita de Safari se guarda en el momento en que ocurrió, no en otra década")
    func epocaDeSafari() throws {
        let when = Self.moment(day: 14, hour: 10, minute: 24)
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: when, url: "https://ejemplo.com/uno", title: "Uno"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: [],
                                          excludedApps: [], home: home.path)

        #expect(reading.visits.count == 1)
        // Un segundo de margen: el valor viaja como REAL y vuelve como Double.
        #expect(abs((reading.visits.first?.at ?? .distantPast).timeIntervalSince(when)) < 1)
        #expect(reading.visits.first?.browser == "Safari")
    }

    @Test("una visita de Chrome se guarda en el momento en que ocurrió, no en otro siglo")
    func epocaDeChrome() throws {
        let when = Self.moment(day: 14, hour: 17, minute: 39)
        let home = Home()
        try Self.makeChrome(in: home, profile: "Default", visits: [
            Visit(at: when, url: "https://ejemplo.com/dos", title: "Dos"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: [],
                                          excludedApps: [], home: home.path)

        #expect(reading.visits.count == 1)
        #expect(abs((reading.visits.first?.at ?? .distantPast).timeIntervalSince(when)) < 1)
        #expect(reading.visits.first?.browser == "Chrome")
    }

    @Test("el corte por fecha se aplica en la época de cada navegador, no en segundos Unix")
    func corteEnLaEpocaDeCadaNavegador() throws {
        let old = Self.moment(day: 5, hour: 9, minute: 0)
        let recent = Self.moment(day: 20, hour: 9, minute: 0)
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: old, url: "https://ejemplo.com/viejo", title: "Viejo en Safari"),
            Visit(at: recent, url: "https://ejemplo.com/nuevo", title: "Nuevo en Safari"),
        ])
        try Self.makeChrome(in: home, profile: "Default", visits: [
            Visit(at: old, url: "https://ejemplo.com/viejoc", title: "Viejo en Chrome"),
            Visit(at: recent, url: "https://ejemplo.com/nuevoc", title: "Nuevo en Chrome"),
        ])

        let reading = BrowserHistory.read(since: Self.moment(day: 10, hour: 0, minute: 0),
                                          excludedDomains: [], excludedApps: [], home: home.path)

        let titles = Set(reading.visits.map(\.title))
        #expect(titles == ["Nuevo en Safari", "Nuevo en Chrome"])
    }

    // MARK: - Las exclusiones, antes de guardar nada

    @Test("una web excluida no sale de la lectura, ni siquiera para descartarla luego")
    func laWebExcluidaNoSale() throws {
        let when = Self.moment(day: 14, hour: 11, minute: 0)
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: when, url: "https://www.bbva.es/movimientos", title: "Mis movimientos"),
            Visit(at: when.addingTimeInterval(60), url: "https://github.com/believe",
                  title: "Un repositorio"),
        ])
        try Self.makeChrome(in: home, profile: "Default", visits: [
            Visit(at: when, url: "https://vault.believe-global.com/secrets", title: "Secretos"),
            Visit(at: when.addingTimeInterval(60), url: "https://ejemplo.com/blog", title: "Un blog"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning,
                                          excludedDomains: Set(Privacy.excludedDomainsByDefault),
                                          excludedApps: [], home: home.path)

        let titles = Set(reading.visits.map(\.title))
        #expect(titles == ["Un repositorio", "Un blog"])
        // El título de una página excluida cuenta tanto como su dirección: "Mis movimientos" ya
        // dice de qué iba.
        #expect(!reading.visits.contains { $0.title.contains("movimientos") })
        #expect(!reading.visits.contains { $0.url.contains("bbva") })
    }

    @Test("la lista de exclusiones que manda es la que se pasa, no la de fábrica")
    func mandaLaListaQueSePasa() throws {
        let when = Self.moment(day: 14, hour: 11, minute: 0)
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: when, url: "https://terapia-privada.com/cita", title: "Mi cita"),
            Visit(at: when.addingTimeInterval(60), url: "https://ejemplo.com/otra", title: "Otra"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning,
                                          excludedDomains: ["terapia-privada.com"],
                                          excludedApps: [], home: home.path)

        #expect(reading.visits.map(\.title) == ["Otra"])
    }

    @Test("excluir por subcadena alcanza a los subdominios y a las rutas de la misma web")
    func laExclusionAlcanzaTodaLaWeb() throws {
        let when = Self.moment(day: 14, hour: 11, minute: 0)
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: when, url: "https://banco.com/entrar", title: "Entrar"),
            Visit(at: when.addingTimeInterval(60), url: "https://particulares.banco.com/saldo",
                  title: "Saldo"),
            Visit(at: when.addingTimeInterval(120), url: "https://BANCO.com/CUENTAS",
                  title: "Cuentas"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: ["banco.com"],
                                          excludedApps: [], home: home.path)

        #expect(reading.visits.isEmpty)
    }

    @Test("una lista de exclusiones vacía no excluye nada por su cuenta")
    func sinExclusionesEntraTodo() throws {
        let when = Self.moment(day: 14, hour: 11, minute: 0)
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: when, url: "https://www.bbva.es/movimientos", title: "Mis movimientos"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: [],
                                          excludedApps: [], home: home.path)

        // La lectura no decide sola: quien la llama pasa la lista, y `CorpusRunner` pasa la del
        // usuario. Si esto pasara a excluir por su cuenta, la prueba de arriba dejaría de probar
        // que el filtro existe.
        #expect(reading.visits.count == 1)
    }

    // MARK: - Perfiles y filas rotas

    @Test("se leen todos los perfiles de Chrome, no solo Default")
    func todosLosPerfilesDeChrome() throws {
        let when = Self.moment(day: 14, hour: 11, minute: 0)
        let home = Home()
        try Self.makeChrome(in: home, profile: "Default",
                            visits: [Visit(at: when, url: "https://a.com", title: "Personal")])
        try Self.makeChrome(in: home, profile: "Profile 1",
                            visits: [Visit(at: when, url: "https://b.com", title: "Trabajo")])

        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: [],
                                          excludedApps: [], home: home.path)

        #expect(Set(reading.visits.map(\.title)) == ["Personal", "Trabajo"])
    }

    @Test("una carpeta que no es un perfil de Chrome no se intenta leer")
    func lasCarpetasQueNoSonPerfilesSeIgnoran() throws {
        let home = Home()
        _ = home.makeFolder("Library/Application Support/Google/Chrome/Crashpad")
        try Self.makeChrome(in: home, profile: "Default",
                            visits: [Visit(at: Self.moment(day: 14, hour: 11, minute: 0),
                                           url: "https://a.com", title: "Personal")])

        #expect(BrowserHistory.chromeProfiles(home: home.path).count == 1)
    }

    @Test("una visita sin título no entra, porque no dice nada de lo que se estaba haciendo")
    func sinTituloNoEntra() throws {
        let when = Self.moment(day: 14, hour: 11, minute: 0)
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: when, url: "https://ejemplo.com/vacio", title: "   "),
            Visit(at: when.addingTimeInterval(60), url: "https://ejemplo.com/algo", title: "Algo"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: [],
                                          excludedApps: [], home: home.path)

        #expect(reading.visits.map(\.title) == ["Algo"])
    }

    @Test("las visitas vuelven en orden, del navegador que sea")
    func vuelvenEnOrden() throws {
        let home = Home()
        try Self.makeSafari(in: home, visits: [
            Visit(at: Self.moment(day: 14, hour: 12, minute: 0), url: "https://a.com", title: "Tarde"),
        ])
        try Self.makeChrome(in: home, profile: "Default", visits: [
            Visit(at: Self.moment(day: 14, hour: 9, minute: 0), url: "https://b.com", title: "Mañana"),
        ])

        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: [],
                                          excludedApps: [], home: home.path)

        #expect(reading.visits.map(\.title) == ["Mañana", "Tarde"])
    }

    @Test("sin navegadores no hay lectura ni queja: no está instalado no es un fallo")
    func sinNavegadoresNoHayQueja() {
        let home = Home()
        let reading = BrowserHistory.read(since: Self.beginning, excludedDomains: [],
                                          excludedApps: [], home: home.path)

        #expect(reading.visits.isEmpty)
        #expect(reading.problems.isEmpty)
    }

    @Test("un permiso denegado se cuenta con la frase que dice qué hacer")
    func elPermisoDenegadoSeExplica() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let said = BrowserHistory.describe(denied, browser: "Safari")

        #expect(said.contains("Full Disk Access"))
        #expect(said.contains("Safari"))
    }
}
