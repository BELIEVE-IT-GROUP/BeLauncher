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
}
