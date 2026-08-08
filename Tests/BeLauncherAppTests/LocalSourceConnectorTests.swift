import Foundation
import Testing
@testable import BeLauncher

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
}
