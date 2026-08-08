import Testing
import Foundation
@testable import BeLauncherCore

@Suite("System commands, aliases and ranking")
@MainActor
struct SystemCommandTests {

    // MARK: - System commands

    @Test("found by title and by keyword, in both languages")
    func searchByKeyword() {
        #expect(SystemCommand.search("papelera").contains { $0.command.id == "empty-trash" || $0.command.id == "open-trash" })
        #expect(SystemCommand.search("trash").contains { $0.command.id == "empty-trash" || $0.command.id == "open-trash" })
        #expect(SystemCommand.search("bloquear").first?.command.id == "lock")
        #expect(SystemCommand.search("dark").contains { $0.command.id == "dark-mode" })
    }

    @Test("a single letter never floods the list with system commands")
    func needsTwoCharacters() {
        #expect(SystemCommand.search("l").isEmpty)
        #expect(SystemCommand.search("").isEmpty)
    }

    @Test("everything irreversible asks first")
    func destructiveNeedsConfirmation() {
        // .ejectDisks is here because a security audit caught it: ejecting every mounted disk
        // can interrupt a copy in progress and lose data.
        let mustConfirm: Set<SystemCommand.Kind> = [.logOut, .restart, .shutDown, .emptyTrash, .ejectDisks]
        for command in SystemCommand.all {
            #expect(command.needsConfirmation == mustConfirm.contains(command.kind),
                    "\(command.id) has the wrong confirmation setting")
        }
    }

    @Test("ids and kinds are unique, so a payload always resolves to one command")
    func uniqueIdentifiers() {
        #expect(Set(SystemCommand.all.map(\.id)).count == SystemCommand.all.count)
        #expect(Set(SystemCommand.all.map(\.kind)).count == SystemCommand.all.count)
    }

    @Test("a system command reaches the results and carries its kind as payload")
    func appearsInSearch() {
        // Se busca en español con la interfaz en inglés a propósito: las palabras clave son
        // bilingües siempre, porque quien piensa en español las escribe aunque su Mac esté en
        // inglés. El título que sale sí sigue al idioma de la interfaz.
        let results = SearchEngine.search("bloquear", in: SearchInput())
        let lock = results.first { $0.kind == .system }
        #expect(lock?.title == "Lock the screen")
        #expect(Loc.render(lock?.title ?? "", in: .spanish) == "Bloquear pantalla")
        #expect(lock?.payload == SystemCommand.Kind.lockScreen.rawValue)
    }

    @Test("running one emits the command, never a shell string")
    func runEmitsKind() {
        var performed: [LauncherModel.Action] = []
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { performed.append($0) })
        model.activate()
        model.query = "bloquear"
        model.handle(.enter)
        #expect(performed.first == .systemCommand(SystemCommand.Kind.lockScreen.rawValue))
    }

    // MARK: - Ranking

    @Test("what you launch often climbs the list")
    func usageRanking() {
        let apps = [
            Application(name: "Mail", path: "/Applications/Mail.app"),
            Application(name: "Maps", path: "/Applications/Maps.app"),
        ]
        let cold = SearchEngine.search("ma", in: SearchInput(applications: apps))
        let warm = SearchEngine.search("ma", in: SearchInput(
            applications: apps, applicationUses: ["/Applications/Maps.app": 12]
        ))
        #expect(cold.first?.title == "Mail")
        #expect(warm.first?.title == "Maps", "12 launches should outweigh alphabetical luck")
    }

    @Test("the ranking bonus is capped so an old habit never blocks a better match")
    func rankingIsCapped() {
        let apps = [
            Application(name: "Terminal", path: "/Applications/Terminal.app"),
            Application(name: "Notion", path: "/Applications/Notion.app"),
        ]
        let results = SearchEngine.search("notion", in: SearchInput(
            applications: apps, applicationUses: ["/Applications/Terminal.app": 5_000]
        ))
        #expect(results.first?.title == "Notion")
    }

    // MARK: - Aliases

    @Test("an alias pulls its target to the top even with a weak fuzzy score")
    func aliasWins() {
        let apps = [
            Application(name: "Safari", path: "/Applications/Safari.app"),
            Application(name: "Navigator Pro", path: "/Applications/Navigator Pro.app"),
        ]
        let plain = SearchEngine.search("nav", in: SearchInput(applications: apps))
        #expect(plain.first?.title == "Navigator Pro")

        let aliased = SearchEngine.search("nav", in: SearchInput(
            applications: apps, aliases: ["nav": "/Applications/Safari.app"]
        ))
        #expect(aliased.first?.title == "Safari")
    }

    @Test("aliases and launches survive a restart, and are validated")
    func persistence() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-alias-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        let store = try Store(path: path)

        try store.setAlias("NAV", target: "/Applications/Safari.app")
        #expect(store.aliases()["nav"] == "/Applications/Safari.app")

        #expect(throws: ValidationError.keywordHasWhitespace) {
            try store.setAlias("dos palabras", target: "/x")
        }
        #expect(throws: ValidationError.emptyBody) {
            try store.setAlias("x", target: "")
        }

        store.recordLaunch(path: "/Applications/Safari.app")
        store.recordLaunch(path: "/Applications/Safari.app")
        #expect(store.applicationUses()["/Applications/Safari.app"] == 2)

        store.removeAlias("nav")
        #expect(store.aliases().isEmpty)
    }
}

@Suite("Bookmarks and folders")
struct ShortcutIndexTests {

    @Test("Chromium bookmarks are read from the tree the browsers already keep")
    func chromium() {
        let json = """
        {"roots":{"bookmark_bar":{"children":[
            {"type":"url","name":"GitHub","url":"https://github.com"},
            {"type":"folder","name":"Trabajo","children":[
                {"type":"url","name":"Linear","url":"https://linear.app"}
            ]},
            {"type":"url","name":"Local","url":"file:///tmp/x"}
        ]}}}
        """
        let found = ShortcutIndex.parseChromium(Data(json.utf8))
        #expect(found.map(\.title).sorted() == ["GitHub", "Linear"])
        #expect(found.allSatisfy { $0.source == .bookmark })
        #expect(!found.contains { $0.target.hasPrefix("file://") }, "only web links belong here")
    }

    @Test("malformed bookmark files are ignored instead of crashing")
    func malformed() {
        #expect(ShortcutIndex.parseChromium(Data("not json".utf8)).isEmpty)
        #expect(ShortcutIndex.parseChromium(Data()).isEmpty)
        #expect(ShortcutIndex.parseChromium(Data(#"{"roots":{}}"#.utf8)).isEmpty)
    }

    @Test("the folders people actually use are offered without asking permission first")
    func folders() {
        let found = ShortcutIndex.commonFolders(home: NSHomeDirectory())
        #expect(found.contains { $0.title == "Descargas" })
        #expect(found.allSatisfy { $0.target.hasPrefix("/") })

        // Listing them must never stat the protected ones: on recent macOS that pops the
        // "would like to access your Downloads folder" dialog while the app is still starting.
        #expect(found.contains { $0.target.hasSuffix("/Downloads") })

        #expect(ShortcutIndex.commonFolders(home: "/tmp/no-existe-\(UUID().uuidString)").isEmpty)
    }

    @Test("a bookmark is searchable and opens as a URL")
    @MainActor
    func bookmarkFlow() {
        var performed: [LauncherModel.Action] = []
        let input = SearchInput(shortcuts: [
            Shortcut(title: "Linear", target: "https://linear.app", source: .bookmark),
        ])
        let model = LauncherModel(dataSource: { input }, perform: { performed.append($0) })
        model.activate()
        model.query = "linear"

        #expect(model.selected?.kind == .bookmark)
        model.handle(.enter)
        #expect(performed.first == .openURL(URL(string: "https://linear.app")!))
    }

    @Test("a folder is searchable and opens as a file")
    @MainActor
    func folderFlow() {
        var performed: [LauncherModel.Action] = []
        let input = SearchInput(shortcuts: [
            Shortcut(title: "Descargas", target: "/Users/x/Downloads", source: .folder),
        ])
        let model = LauncherModel(dataSource: { input }, perform: { performed.append($0) })
        model.activate()
        model.query = "descargas"

        #expect(model.selected?.kind == .file)
        model.handle(.enter)
        #expect(performed.first == .openFile(path: "/Users/x/Downloads"))
    }
}

@Suite("Shortcuts as the safe escape hatch")
@MainActor
struct SystemShortcutTests {

    @Test("a user's own Shortcut is searchable and runs by name")
    func runsByName() {
        var performed: [LauncherModel.Action] = []
        let input = SearchInput(systemShortcuts: ["Modo enfoque", "Enviar informe semanal"])
        let model = LauncherModel(dataSource: { input }, perform: { performed.append($0) })
        model.activate()
        model.query = "informe semanal"

        #expect(model.selected?.kind == .shortcut)
        model.handle(.enter)
        #expect(performed.first == .runShortcut(name: "Enviar informe semanal"),
                "we invoke by name; we never read or rewrite what the shortcut does")
    }

    @Test("shortcuts rank above bookmarks, they are deliberate automations")
    func ranksAboveBookmarks() {
        let input = SearchInput(
            shortcuts: [Shortcut(title: "Enfoque", target: "https://x.com/enfoque", source: .bookmark)],
            systemShortcuts: ["Enfoque"]
        )
        let results = SearchEngine.search("enfoque", in: input)
        #expect(results.first?.kind == .shortcut)
    }

    @Test("every result kind has actions and a primary — nothing dead ends")
    func everyKindIsComplete() {
        for kind in ResultKind.allCases {
            let result = SearchResult(id: "x", kind: kind, title: "t", subtitle: "s",
                                      score: 1, matched: [], payload: "/tmp/x", recordID: 1)
            let actions = ActionRegistry.actions(for: result)
            #expect(!actions.isEmpty, "\(kind) offers nothing to do")
            #expect(actions.first?.shortcut?.display == "↩", "\(kind) has no Return action")
        }
    }
}

/// The entitlement that made every system command a no-op in every signed release.
///
/// Under hardened runtime macOS refuses Apple Events unless the app declares
/// `com.apple.security.automation.apple-events`, and it refuses them *before* asking anyone — so no
/// prompt appears and BeLauncher never even shows up in Privacy › Automation. There is nothing for
/// the user to switch on. It went unnoticed because the development build is unsigned, so it worked
/// on exactly the one path it was tested on.
@Suite("Signing the app so it can actually do its job")
struct EntitlementsTests {

    static var repositoryRoot: String {
        // The tests run from .build, so walk up to the package root.
        var path = URL(fileURLWithPath: #filePath)
        while path.pathComponents.count > 1 {
            path.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: path.appendingPathComponent("Package.swift").path) {
                return path.path
            }
        }
        return ""
    }

    @Test("the app ships the entitlements needed for automation and microphone capture")
    func hasEntitlements() throws {
        let path = (Self.repositoryRoot as NSString)
            .appendingPathComponent("Scripts/BeLauncher.entitlements")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("com.apple.security.automation.apple-events"),
                "sin esto los comandos de sistema y los flujos no hacen nada en un build firmado")
        #expect(contents.contains("com.apple.security.device.audio-input"),
                "sin Audio Input el build firmado no llega al prompt TCC del micrófono")
    }

    @Test("the release actually passes it to codesign, and refuses to ship without it")
    func releaseUsesThem() throws {
        let path = (Self.repositoryRoot as NSString)
            .appendingPathComponent("Scripts/release-mac.sh")
        let script = try String(contentsOfFile: path, encoding: .utf8)
        #expect(script.contains("--entitlements"),
                "el fichero puede existir y no usarse: eso ya pasó una vez")
        #expect(script.contains("com.apple.security.automation.apple-events"),
                "el release debe verificar el .app firmado, no confiar en que salió bien")
        #expect(script.contains("com.apple.security.device.audio-input"),
                "el release debe abortar si codesign elimina Audio Input")
    }

    @Test("the Info.plist explains Apple Events instead of denying them")
    func usageStringIsHonest() throws {
        let path = (Self.repositoryRoot as NSString)
            .appendingPathComponent("Scripts/Info.plist")
        let plist = try String(contentsOfFile: path, encoding: .utf8)
        #expect(plist.contains("NSAppleEventsUsageDescription"))
        // This string is what macOS shows in the permission dialog. It used to read "BeLauncher
        // does not send Apple Events", which was false and was the text shown while asking for
        // permission to send them.
        #expect(!plist.contains("does not send Apple Events"),
                "el texto del diálogo de permiso no puede negar lo que la app hace")
    }
}
