import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Rich clipboard")
@MainActor
struct RichClipboardTests {

    private func store() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-clip-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        return try Store(path: path)
    }

    @Test("what you copied is recognised for what it is")
    func kindDetection() {
        #expect(Clip.detectKind("https://belauncher.app") == .link)
        #expect(Clip.detectKind("una nota cualquiera") == .text)
        #expect(Clip.detectKind("/etc/hosts") == .file)              // exists on every Mac
        #expect(Clip.detectKind("/no/existe/\(UUID().uuidString)") == .text)
        #expect(Clip.detectKind("https://con espacio.com") == .text) // not a usable link
    }

    @Test("a pinned clip sorts first and survives both kinds of trimming")
    func pinning() throws {
        let store = try store()
        let now = Date(timeIntervalSince1970: 2_000_000)

        store.recordClip(text: "viejo pero fijado", at: now.addingTimeInterval(-90 * 86_400))
        store.recordClip(text: "reciente", at: now)
        let old = try #require(store.clips().first { $0.text == "viejo pero fijado" })
        store.setPinned(true, clip: old.id)

        #expect(store.clips().first?.text == "viejo pero fijado", "pinned clips come first")

        store.trimClips(retentionDays: 30, maxItems: 500, now: now)
        #expect(store.clips().contains { $0.text == "viejo pero fijado" },
                "retention must not delete something the user pinned")

        for index in 0..<10 { store.recordClip(text: "relleno \(index)", at: now) }
        store.trimClips(retentionDays: 0, maxItems: 3, now: now)
        #expect(store.clips().contains { $0.text == "viejo pero fijado" },
                "the item cap must not delete something the user pinned")
    }

    @Test("copies from an excluded app are never recorded")
    func exclusions() throws {
        let store = try store()
        store.setExcludedApps(["1Password", "Banco"])

        #expect(store.recordClip(text: "algo normal", sourceApp: "Notes") == true)
        #expect(store.recordClip(text: "clave del banco", sourceApp: "banco") == false,
                "matching is case-insensitive")
        #expect(store.recordClip(text: "otra cosa", sourceApp: "1Password") == false)
        #expect(store.clips().map(\.text) == ["algo normal"])

        #expect(store.excludedApps() == ["1password", "banco"])
    }

    @Test("kind and pin state survive a reopen")
    func persistence() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("belauncher-clip-\(UUID().uuidString)")
            .appendingPathComponent("s.sqlite3").path
        do {
            let store = try Store(path: path)
            store.recordClip(text: "https://example.com", sourceApp: "Safari")
            store.recordClip(text: "/tmp/foto.png", sourceApp: "Finder", kind: .image,
                             assetPath: "/tmp/foto.png")
            let link = try #require(store.clips().first { $0.text == "https://example.com" })
            store.setPinned(true, clip: link.id)
        }
        let reopened = try Store(path: path)
        let clips = reopened.clips()
        #expect(clips.first?.kind == .link)
        #expect(clips.first?.isPinned == true)
        #expect(clips.contains { $0.kind == .image && $0.assetPath == "/tmp/foto.png" })
    }

    @Test("the subtitle says pinned, kind and origin")
    func subtitle() {
        let pinnedLink = Clip(id: 1, text: "https://x.com", sourceApp: "Safari",
                              kind: .link, isPinned: true)
        let subtitle = SearchEngine.clipSubtitle(pinnedLink)
        #expect(subtitle.contains("Fijado"))
        #expect(subtitle.contains("Enlace"))
        #expect(subtitle.contains("Safari"))

        let plain = Clip(id: 2, text: "hola", sourceApp: "")
        #expect(SearchEngine.clipSubtitle(plain) == "Clipboard")
    }

    @Test("pinned clips also rank higher when searching")
    func pinnedRanksHigher() {
        let clips = [
            Clip(id: 1, text: "informe trimestral", sourceApp: "Pages"),
            Clip(id: 2, text: "informe trimestral v2", sourceApp: "Pages", isPinned: true),
        ]
        let results = SearchEngine.search("informe", in: SearchInput(clips: clips))
        #expect(results.first?.recordID == 2)
    }

    @Test("the empty clipboard surface keeps the whole retained history")
    func recentsDoNotCollapseToSearchLimit() {
        let clips = (0..<20).map { Clip(id: Int64($0), text: "clip \($0)") }
        #expect(SearchEngine.recents(clips).count == 20)
    }

    @Test("pinning from the action panel goes through the store")
    func pinAction() {
        var pinned: [(Bool, Int64)] = []
        let input = SearchInput(clips: [Clip(id: 9, text: "algo copiado", sourceApp: "Xcode")])
        let model = LauncherModel(dataSource: { input }, onPin: { pinned.append(($0, $1)) },
                                  perform: { _ in })
        model.activate()
        model.query = "algo copiado"

        let pin = try! #require(model.actions.first { $0.id == "pin" })
        model.run(pin)
        #expect(pinned.first?.0 == true)
        #expect(pinned.first?.1 == 9)
    }
}

/// The carousel renders a thumbnail per card, so the path has to travel on the result itself.
@Suite("Clipboard cards carry what they need to be seen")
@MainActor
struct ClipboardCardTests {

    @Test("an image clip carries its file, so every card can show it — not only the selected one")
    func imagesCarryTheirAsset() {
        let clip = Clip(id: 1, text: "Imagen", sourceApp: "Safari", kind: .image,
                        assetPath: "/tmp/shot.png")
        let recents = SearchEngine.recents([clip])
        #expect(recents.first?.previewPath == "/tmp/shot.png")
    }

    @Test("a copied file previews itself")
    func filesPreviewThemselves() {
        let clip = Clip(id: 2, text: "/Users/x/informe.pdf", sourceApp: "Finder", kind: .file)
        #expect(SearchEngine.recents([clip]).first?.previewPath == "/Users/x/informe.pdf")
    }

    @Test("plain text has nothing to show, and says so by being empty")
    func textHasNoPreview() {
        let clip = Clip(id: 3, text: "hola", sourceApp: "Notes", kind: .text)
        #expect(SearchEngine.recents([clip]).first?.previewPath.isEmpty == true)
        // Searching returns the same thing: the two paths must not disagree.
        let found = SearchEngine.search("hola", in: SearchInput(clips: [clip]))
        #expect(found.first?.previewPath.isEmpty == true)
    }

    @Test("searching keeps the preview a card needs")
    func searchKeepsIt() {
        let clip = Clip(id: 4, text: "captura", sourceApp: "Safari", kind: .image,
                        assetPath: "/tmp/a.png")
        let found = SearchEngine.search("captura", in: SearchInput(clips: [clip]))
        #expect(found.first?.previewPath == "/tmp/a.png")
    }
}
