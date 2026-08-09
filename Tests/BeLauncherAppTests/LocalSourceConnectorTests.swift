import Foundation
import Testing
@testable import BeLauncher
@testable import BeLauncherCore

@Suite("Deep local source discovery")
struct LocalSourceConnectorTests {
    @Test("Apple Mail follows the newest store version instead of assuming V10")
    func discoversCurrentMailStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let old = home.appendingPathComponent("Library/Mail/V9", isDirectory: true)
        let current = home.appendingPathComponent("Library/Mail/V12", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

        #expect(LocalMailConnector.mailRoot(home: home.path)?.resolvingSymlinksInPath().path
                == current.resolvingSymlinksInPath().path)
    }

    @Test("Full Disk Access health accepts a readable current Mail store")
    @MainActor
    func fullDiskHealthUsesCurrentMailStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mail = home.appendingPathComponent("Library/Mail/V12/Account", isDirectory: true)
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)

        #expect(Permissions.fullDiskAccessLikely(home: home.path))
    }

    @Test("una fuente no queda conectada si su evidencia ya no es legible")
    @MainActor
    func successfulSyncRequiresReadableEvidence() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let db = home.appendingPathComponent("Library/Messages/chat.db")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("sqlite".utf8).write(to: db)

        let storePath = home.appendingPathComponent("state.sqlite3").path
        let store = try Store(path: storePath)
        store.setSetting("source_enabled_messages", true)
        store.setSetting("source_last_sync_messages", String(Date.now.timeIntervalSince1970))
        store.setSetting("source_last_problem_messages", "")
        #expect(LocalSourceHealth.successfulSync("messages", store: store, home: home.path))

        try FileManager.default.removeItem(at: db)
        #expect(!LocalSourceHealth.successfulSync("messages", store: store, home: home.path))
    }

    @Test("permiso concedido no pinta una fuente verde antes de una lectura real")
    @MainActor
    func localSourceNeedsSuccessfulRead() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let store = try Store(path: path)
        let source = KnowledgeSource(id: "photos", title: "Photos", scope: "metadata",
                                     state: .available, symbol: "photo")

        #expect(LocalSourceHealth.state(for: source, store: store) == .available)
        store.setSetting("source_last_sync_photos", String(Date.now.timeIntervalSince1970))
        store.setSetting("source_last_count_photos", "12")
        store.setSetting("source_last_problem_photos", "")
        #expect(LocalSourceHealth.state(for: source, store: store) == .connected)

        store.setSetting("source_last_problem_photos", "read failed")
        #expect(LocalSourceHealth.state(for: source, store: store) == .available)
    }

    @Test("WhatsApp ausente sigue siendo planeado, no conectado")
    func whatsappAbsentIsPlanned() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let status = LocalWhatsAppConnector.status(home: home.path)

        #expect(!status.installed)
        #expect(status.sourceState == .planned)
        #expect(status.diagnosticState == "not-detected")
        #expect(status.problem == nil)
    }

    @Test("WhatsApp instalado sin store de mensajes soportado queda explícitamente no soportado")
    func whatsappInstalledWithoutReadableStoreIsUnsupported() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let container = home.appendingPathComponent("Library/Containers/net.whatsapp.WhatsApp",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let status = LocalWhatsAppConnector.status(home: home.path)

        #expect(status.installed)
        #expect(!status.isSupported)
        #expect(status.sourceState == .unsupported)
        #expect(status.diagnosticState == "detected-unsupported")
        #expect(status.problem?.contains("no supported readable local message store") == true)
    }

    @Test("WhatsApp Web en IndexedDB no se confunde con un parser de chats")
    func whatsappWebStoreIsUnsupported() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let webStore = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Profile 2/IndexedDB/https_web.whatsapp.com_0.indexeddb.leveldb",
            isDirectory: true)
        try FileManager.default.createDirectory(at: webStore, withIntermediateDirectories: true)

        let status = LocalWhatsAppConnector.status(home: home.path)

        #expect(status.webStores.map { ($0 as NSString).lastPathComponent }
            == ["https_web.whatsapp.com_0.indexeddb.leveldb"])
        #expect(status.sourceState == .unsupported)
    }

    @Test("solo una base de mensajes conocida convierte WhatsApp en fuente soportable")
    func whatsappSupportedStoreIsAvailable() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = home.appendingPathComponent(
            "Library/Containers/net.whatsapp.WhatsApp/Data/ChatStorage.sqlite")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("sqlite".utf8).write(to: store)

        let status = LocalWhatsAppConnector.status(home: home.path)

        #expect(status.isSupported)
        #expect(status.sourceState == .available)
        #expect(status.diagnosticState == "supported-store-found")
        #expect(status.problem == nil)
    }
}
