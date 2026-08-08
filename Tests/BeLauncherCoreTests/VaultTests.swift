import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Vault and memory commits")
@MainActor
struct VaultTests {

    private func vault() throws -> Vault {
        try Vault(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)").path)
    }

    private func decision(_ statement: String, entities: [String] = ["pricing"],
                          createdAt: Date = .now) -> MemoryObject {
        MemoryObject(level: .extracted, kind: .decision, statement: statement,
                     owner: "Jorge", createdAt: createdAt, entities: entities)
    }

    // MARK: - The file format

    @Test("an object survives a round trip through Markdown, and stays readable")
    func roundTrip() {
        let object = MemoryObject(
            level: .committed, kind: .decision,
            statement: "No lanzar reporting hasta Attribution v2",
            body: "Acordado en la reunión de producto.",
            source: "Reunión 2026-08-04", owner: "Jorge",
            entities: ["reporting", "attribution"], evidence: ["nota-123"]
        )
        let text = VaultDocument.render(object)
        #expect(text.hasPrefix("---"), "front matter first, so any editor understands it")
        #expect(text.contains("# No lanzar reporting hasta Attribution v2"))

        let parsed = try! #require(VaultDocument.parse(text))
        #expect(parsed.id == object.id)
        #expect(parsed.statement == object.statement)
        #expect(parsed.entities == object.entities)
        #expect(parsed.body == object.body)
        #expect(parsed.owner == "Jorge")
    }

    @Test("evidence and quick notes use the vault's durable publication path")
    func evidenceUsesInbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-evidence-\(UUID().uuidString)").path
        let vault = try Vault(root: root)
        let date = Date(timeIntervalSince1970: 7_000_000)
        let evidencePath = try vault.saveEvidence(title: "Imported call",
                                                   text: "The source was a local audio file.",
                                                   at: date)
        let notePath = try vault.saveQuickNote("Follow up with the client", at: date)
        #expect(evidencePath.hasPrefix((root as NSString).appendingPathComponent("inbox")))
        #expect(notePath.hasPrefix((root as NSString).appendingPathComponent("inbox")))
        #expect(FileManager.default.fileExists(atPath: evidencePath))
        #expect(FileManager.default.fileExists(atPath: notePath))
        #expect((try String(contentsOfFile: evidencePath)).contains("Imported call"))
        #expect((try String(contentsOfFile: notePath)).contains("Follow up with the client"))
        #expect((try FileManager.default.contentsOfDirectory(atPath: root))
            .filter { $0.hasPrefix(".beacon-vault-staging-") }.isEmpty)
    }

    @Test("quotes and accents in a statement do not corrupt the file")
    func awkwardCharacters() {
        let object = MemoryObject(level: .committed, kind: .policy,
                                  statement: #"El cliente dijo "no" al "plan pro": ¿revisamos?"#)
        let parsed = try! #require(VaultDocument.parse(VaultDocument.render(object)))
        #expect(parsed.statement == object.statement)
    }

    @Test("a file that is not one of ours is ignored, not half-parsed")
    func rejectsForeignFiles() {
        #expect(VaultDocument.parse("# Just a note\n\nsome text") == nil)
        #expect(VaultDocument.parse("---\nid: x\n---\n") == nil, "no statement, no object")
    }

    // MARK: - Temporal truth

    @Test("only committed and current objects answer 'what is true now'")
    func currentTruth() throws {
        let vault = try vault()
        let now = Date(timeIntervalSince1970: 2_000_000)

        var committed = decision("Precio enterprise: 2000", createdAt: now.addingTimeInterval(-100))
        committed.level = .committed
        var guess = decision("Quizá subimos el precio", createdAt: now.addingTimeInterval(-100))
        guess.level = .extracted
        var expired = decision("Precio enterprise: 1500", createdAt: now.addingTimeInterval(-200))
        expired.level = .committed
        expired.validUntil = now.addingTimeInterval(-1)

        try [committed, guess, expired].forEach(vault.save)

        let current = vault.current(at: now)
        #expect(current.map(\.statement) == ["Precio enterprise: 2000"],
                "an interpretation is not a decision, and an expired decision is not current")
    }

    @Test("an outcome memory keeps the mission link and is indexed as brain context")
    func outcomeMemoryIsRecoverable() throws {
        let vault = try vault()
        let finished = Date(timeIntervalSince1970: 4_000_000)
        let receipt = MissionReceipt(
            missionID: "mission-42", intent: "prepare client brief", requestedBy: "Jorge",
            startedAt: finished.addingTimeInterval(-60), finishedAt: finished,
            lines: ["✓ Saved the brief"], changed: ["Saved the brief"], undoable: []
        )
        let outcome = receipt.outcomeMemory()

        try vault.save(outcome)
        let loaded = try #require(vault.load(id: outcome.id))
        #expect(loaded.level == .outcome)
        #expect(loaded.source == "mission:mission-42")
        #expect(loaded.evidence == ["mission:mission-42"])

        let item = try #require(Indexer.items(memories: [loaded]).first)
        #expect(item.source == IndexedSource(kind: .memory, id: outcome.id))
        #expect(item.text.contains("Saved the brief"))
    }

    @Test("backlinks follow declared evidence instead of guessing from similar words")
    func explicitBacklinks() throws {
        let vault = try vault()
        let source = MemoryObject(id: "call-7", level: .evidence, kind: .note,
                                  statement: "Client call transcript")
        let extracted = MemoryObject(level: .extracted, kind: .learning,
                                     statement: "The client wants a smaller scope",
                                     evidence: ["note:call-7"])
        let unrelated = MemoryObject(level: .extracted, kind: .learning,
                                     statement: "The client wants a smaller scope")
        try [source, extracted, unrelated].forEach(vault.save)

        #expect(vault.backlinks(to: "call-7").map(\.id) == [extracted.id])
    }

    // MARK: - Commits

    @Test("nothing enters the brain without a person confirming it")
    func proposeThenConfirm() throws {
        let vault = try vault()
        let commit = try vault.propose(decision("Precio enterprise: 2000"), reason: "Reunión")

        #expect(commit.state == .proposed)
        #expect(vault.current().isEmpty, "a proposal is not yet part of the brain")

        let object = try vault.confirm(commitID: commit.id)
        #expect(object.level == .committed)
        #expect(vault.current().map(\.statement) == ["Precio enterprise: 2000"])
        #expect(vault.commits(state: .confirmed).count == 1)
    }

    @Test("discarding leaves no trace in the brain, but keeps the record")
    func discard() throws {
        let vault = try vault()
        let commit = try vault.propose(decision("Algo dudoso"))
        try vault.discard(commitID: commit.id)

        #expect(vault.current().isEmpty)
        #expect(vault.commits(state: .discarded).count == 1)
        #expect(throws: MemoryError.notProposed) { try vault.confirm(commitID: commit.id) }
    }

    @Test("a new decision supersedes the old one, and the link is walkable both ways")
    func supersede() throws {
        let vault = try vault()
        let now = Date(timeIntervalSince1970: 3_000_000)
        let first = try vault.confirm(
            commitID: try vault.propose(decision("Precio: 1500", createdAt: now.addingTimeInterval(-500))).id,
            at: now.addingTimeInterval(-400)
        )

        let second = try vault.propose(decision("Precio: 2000", createdAt: now.addingTimeInterval(-100)))
        #expect(second.conflicts == [first.id], "the person deciding must see what this replaces")
        let applied = try vault.confirm(commitID: second.id, at: now)

        #expect(applied.supersedes == [first.id])
        let previous = try #require(vault.load(id: first.id))
        #expect(previous.status == .superseded)
        #expect(previous.supersededBy == applied.id)
        #expect(previous.validUntil == now, "history keeps when it stopped being true")
        #expect(vault.current(at: now).map(\.statement) == ["Precio: 2000"])
    }

    @Test("unrelated decisions do not collide")
    func noFalseConflict() throws {
        let vault = try vault()
        _ = try vault.confirm(commitID: try vault.propose(
            decision("Precio enterprise: 1500", entities: ["pricing"])).id)

        let unrelated = try vault.propose(
            MemoryObject(level: .extracted, kind: .decision,
                         statement: "Contratar diseñador en septiembre", entities: ["hiring"]))
        #expect(unrelated.conflicts.isEmpty)
    }

    @Test("two different decisions about the same topic both stay alive")
    func sameTopicDifferentDecisions() throws {
        let vault = try vault()
        _ = try vault.confirm(commitID: try vault.propose(
            decision("Precio base del plan Pro: 1000", entities: ["pricing"])).id)

        let discount = try vault.propose(
            decision("Descuento anual del 10 por ciento", entities: ["pricing"]))
        #expect(discount.conflicts.isEmpty,
                "sharing a topic is not the same as contradicting; deleting a live decision is worse")

        _ = try vault.confirm(commitID: discount.id)
        #expect(vault.current().count == 2)
    }

    @Test("an empty statement is refused everywhere")
    func refusesEmpty() throws {
        let vault = try vault()
        let empty = MemoryObject(level: .extracted, kind: .note, statement: "   ")
        #expect(throws: MemoryError.emptyStatement) { try vault.save(empty) }
        #expect(throws: MemoryError.emptyStatement) { try vault.propose(empty) }
    }

    @Test("the vault is a folder of plain files, not a container")
    func portability() throws {
        let vault = try vault()
        _ = try vault.confirm(commitID: try vault.propose(decision("Algo decidido")).id)

        let files = try FileManager.default.contentsOfDirectory(atPath: vault.objectsFolder)
        #expect(files.count == 1)
        #expect(files.allSatisfy { $0.hasSuffix(".md") }, "openable in any editor")

        let contents = try String(contentsOfFile: (vault.objectsFolder as NSString)
            .appendingPathComponent(files[0]), encoding: .utf8)
        #expect(contents.contains("Algo decidido"))
    }

    // MARK: - Defects the audit found

    @Test("editing a statement replaces the file instead of leaving an orphan")
    func editingDoesNotDuplicate() throws {
        let vault = try vault()
        var object = MemoryObject(level: .committed, kind: .decision,
                                  statement: "Precio enterprise 1500")
        try vault.save(object)

        object.statement = "Precio enterprise 2000"   // a typo fixed, same object
        try vault.save(object)

        let files = try FileManager.default.contentsOfDirectory(atPath: vault.objectsFolder)
        #expect(files.count == 1, "an edit must not leave a second file claiming the same id")
        #expect(vault.objects().count == 1)
        #expect(vault.load(id: object.id)?.statement == "Precio enterprise 2000")
    }

    @Test("a decision that settles several older ones records all of them")
    func supersedesEverythingItReplaces() throws {
        let vault = try vault()
        // Two live decisions that both talk about the enterprise price. Saved directly so the
        // test is about superseding many at once, not about the conflict heuristic.
        var first = decision("Precio enterprise 1500 al año", entities: ["pricing"])
        first.level = .committed
        var second = decision("Precio enterprise anual 1500", entities: ["pricing"])
        second.level = .committed
        try vault.save(first)
        try vault.save(second)

        let merged = try vault.propose(
            decision("Precio enterprise 2000 al año", entities: ["pricing"]))
        #expect(merged.conflicts.count == 2)

        let applied = try vault.confirm(commitID: merged.id)
        #expect(Set(applied.supersedes) == Set([first.id, second.id]),
                "history must stay walkable forward, not only backward")
        #expect(vault.current().count == 1)
    }

    @Test("a horizontal rule in the body does not corrupt the object")
    func markdownRuleInBody() {
        let object = MemoryObject(level: .committed, kind: .note, statement: "Notas de la reunión",
                                  body: "Primera parte\n\n---\n\nSegunda parte")
        let parsed = try! #require(VaultDocument.parse(VaultDocument.render(object)))
        #expect(parsed.statement == "Notas de la reunión")
        #expect(parsed.body.contains("Primera parte"))
        #expect(parsed.body.contains("Segunda parte"))
    }

    @Test("a validity window that ends before it starts is refused")
    func refusesImpossibleValidity() throws {
        let vault = try vault()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let object = MemoryObject(level: .committed, kind: .policy, statement: "Imposible",
                                  createdAt: now, validFrom: now,
                                  validUntil: now.addingTimeInterval(-100))
        #expect(throws: MemoryError.invalidValidity) { try vault.save(object) }
    }

    @Test("a vault reopened from disk sees everything again")
    func reopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString)").path
        do {
            let vault = try Vault(root: root)
            _ = try vault.confirm(commitID: try vault.propose(decision("Persistente")).id)
        }
        let reopened = try Vault(root: root)
        #expect(reopened.current().map(\.statement) == ["Persistente"])
    }

    @Test("a durable vault manifest finishes a write after an interrupted launch")
    func recoversStagedWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-recovery-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = try Vault(root: root)
        let object = MemoryObject(level: .committed, kind: .decision,
                                  statement: "Recovered decision")
        let staging = (root as NSString).appendingPathComponent(".beacon-vault-staging-test")
        let destination = (first.objectsFolder as NSString).appendingPathComponent("recovered.md")
        let staged = (staging as NSString).appendingPathComponent("0.blob")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        try VaultDocument.render(object).write(toFile: staged, atomically: true, encoding: .utf8)
        let manifest: [String: Any] = [
            "writes": [["staged": staged, "destination": destination, "previous": NSNull()]]
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: URL(fileURLWithPath: (staging as NSString).appendingPathComponent("manifest.json")),
                   options: .atomic)

        let reopened = try Vault(root: root)
        #expect(reopened.load(id: object.id)?.statement == "Recovered decision")
        #expect(!FileManager.default.fileExists(atPath: staging))
    }
}

@Suite("The brain inside the launcher")
@MainActor
struct BrainSearchTests {

    private func memory(_ statement: String, entities: [String] = []) -> MemoryObject {
        MemoryObject(level: .committed, kind: .decision, statement: statement,
                     source: "Reunión", owner: "Jorge", entities: entities)
    }

    @Test("a decision outranks a bookmark that happens to share words")
    func brainAnswersFirst() {
        let input = SearchInput(
            shortcuts: [Shortcut(title: "Pricing enterprise", target: "https://x.com/pricing",
                                 source: .bookmark)],
            memories: [memory("Precio enterprise: 2000 al año", entities: ["pricing"])]
        )
        let results = SearchEngine.search("precio enterprise", in: input)
        #expect(results.first?.kind == .memory)
    }

    @Test("a memory is found through its entities, not only its wording")
    func findsByEntity() {
        let input = SearchInput(memories: [memory("Subimos a 2000", entities: ["pricing"])])
        #expect(!SearchEngine.search("pricing", in: input).isEmpty)
    }

    @Test("something waiting to be confirmed sits above everything, and Return confirms it")
    func pendingCommitsSurface() {
        var performed: [LauncherModel.Action] = []
        let commit = MemoryCommit(object: MemoryObject(level: .extracted, kind: .decision,
                                                       statement: "Cambiar el precio a 2500"),
                                  reason: "Reunión de hoy")
        let input = SearchInput(memories: [memory("Precio enterprise: 2000")],
                                pendingCommits: [commit])

        let model = LauncherModel(dataSource: { input }, perform: { performed.append($0) })
        model.activate()
        model.query = "precio"

        #expect(model.results.first?.kind == .pendingCommit,
                "what needs a decision from you comes before what is already settled")

        model.handle(.enter)
        #expect(performed.contains(.confirmCommit(commit.id)))
    }

    @Test("a proposal can be discarded from the panel, and that is destructive")
    func discardFromPanel() {
        var performed: [LauncherModel.Action] = []
        let commit = MemoryCommit(object: MemoryObject(level: .extracted, kind: .note,
                                                       statement: "Idea suelta"))
        let input = SearchInput(pendingCommits: [commit])
        let model = LauncherModel(dataSource: { input }, perform: { performed.append($0) })
        model.activate()
        model.query = "idea suelta"

        let discard = try! #require(model.actions.first { $0.id == "discard" })
        #expect(discard.isDestructive)
        model.run(discard)
        #expect(performed.contains(.discardCommit(commit.id)))
    }

    @Test("any clipboard entry can become a memory")
    func rememberFromClipboard() {
        var performed: [LauncherModel.Action] = []
        let input = SearchInput(clips: [Clip(id: 4, text: "El cliente pidió cambiar el alcance",
                                             sourceApp: "Mail")])
        let model = LauncherModel(dataSource: { input }, perform: { performed.append($0) })
        model.activate()
        model.query = "cliente pidió"

        let remember = try! #require(model.actions.first { $0.id == "remember" })
        #expect(remember.shortcut?.display == "⌘R")
        model.run(remember)
        #expect(performed.contains {
            if case .remember(let text, _) = $0 { return text.contains("cambiar el alcance") }
            return false
        })
    }

    @Test("the preview of a memory says whether it is still true")
    func memoryPreview() {
        var stale = memory("Precio viejo: 1500")
        stale.status = .superseded
        let input = SearchInput(memories: [stale])
        let model = LauncherModel(dataSource: { input }, perform: { _ in })
        model.activate()
        model.query = "precio viejo"

        let detail = try! #require(model.detail)
        #expect(detail.metadata.contains { $0.label == "In force" && $0.value == "No" })
    }
}

/// The vault has to explain itself without lying to itself.
@Suite("The vault explains itself")
@MainActor
struct VaultGuideTests {

    private func temporaryRoot() -> String {
        NSTemporaryDirectory() + "vaultguide-\(UUID().uuidString)"
    }

    @Test("the folders a brain needs exist from day one, with a README")
    func scaffolds() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        try VaultGuide.scaffold(at: root)
        for folder in VaultGuide.folders {
            #expect(FileManager.default.fileExists(
                atPath: (root as NSString).appendingPathComponent(folder.name)),
                "falta \(folder.name)")
        }
        #expect(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent("LÉEME.md")))
    }

    @Test("nothing explanatory is written where the app reads memories back")
    func neverPollutesMachineFolders() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try VaultGuide.scaffold(at: root)

        // A friendly note dropped into objects/ comes back as a decision the company never made.
        for folder in VaultGuide.machineRead {
            let path = (root as NSString).appendingPathComponent(folder)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            #expect(contents.filter { $0.hasSuffix(".md") }.isEmpty,
                    "\(folder) debe quedar vacía: todo .md ahí dentro se lee como dato")
        }
        // The human folders do get their note.
        #expect(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent("inbox/QUÉ VA AQUÍ.md")))
    }

    @Test("running it twice changes nothing and destroys nothing")
    func idempotent() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let first = try VaultGuide.scaffold(at: root)
        #expect(!first.isEmpty)

        let mine = (root as NSString).appendingPathComponent("inbox/mi nota.md")
        try "no me toques".write(toFile: mine, atomically: true, encoding: .utf8)

        let second = try VaultGuide.scaffold(at: root)
        #expect(second.isEmpty, "la segunda vez no debe crear nada")
        #expect(try String(contentsOfFile: mine, encoding: .utf8) == "no me toques")
    }

    @Test("git init happens once and never publishes anything by itself")
    func gitIsOptOut() {
        var commands: [[String]] = []
        let root = temporaryRoot()
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = VaultGuide.makeGitRepository(at: root) { _, arguments in
            commands.append(arguments); return 0
        }
        #expect(result == .created)
        #expect(commands.contains { $0.contains("init") })
        // Nothing may add a remote or push: where the company's memory ends up is not our call.
        #expect(!commands.contains { $0.contains("remote") || $0.contains("push") })
        #expect(FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent(".gitignore")))
    }

    @Test("Obsidian gets a path it can actually open")
    func obsidianLink() {
        let url = VaultGuide.obsidianURL(for: "/Users/x/Library/Application Support/BeLauncher/Vault")
        #expect(url?.scheme == "obsidian")
        #expect(url?.absoluteString.contains("Application%20Support") == true,
                "un espacio sin escapar deja el enlace inservible")
    }
}

@Suite("Finding the models already on this Mac")
struct LocalModelsTests {

    @Test("reads what Ollama reports")
    func ollama() {
        let json = Data(#"{"models":[{"name":"llama3.2:latest"},{"name":"qwen2.5"}]}"#.utf8)
        #expect(LocalModels.models(in: json) == ["llama3.2:latest", "qwen2.5"])
    }

    @Test("reads what LM Studio reports, which is the OpenAI shape")
    func lmStudio() {
        let json = Data(#"{"data":[{"id":"mistral-7b"},{"id":"phi-4"}]}"#.utf8)
        #expect(LocalModels.models(in: json) == ["mistral-7b", "phi-4"])
    }

    @Test("nothing running is not an error")
    func nothing() {
        #expect(LocalModels.models(in: Data("not json".utf8)).isEmpty)
        #expect(LocalModels.models(in: Data(#"{"models":[]}"#.utf8)).isEmpty)
    }
}

@Suite("What we ask for, and why")
struct OnboardingTests {

    @Test("every capability says what it gives, what it touches and what you lose")
    func honest() {
        for capability in Onboarding.capabilities {
            #expect(capability.unlocks.count > 25, "\(capability.id) no dice qué te da")
            #expect(capability.accesses.count > 10, "\(capability.id) no dice a qué accede")
            #expect(capability.ifYouSayNo.count > 15, "\(capability.id) no dice qué pierdes")
        }
    }

    @Test("the two permissions macOS has to grant are marked as such")
    func systemOnes() {
        let system = Set(Onboarding.capabilities.filter(\.isSystemPermission).map(\.id))
        #expect(system.contains("accessibility"))
        #expect(system.contains("calendar"))
        #expect(system.contains("notifications"))
        // Our own settings must never claim macOS is involved.
        #expect(!system.contains("clipboard"))
        #expect(!system.contains("updates"))
    }

    @Test("the privacy promise names what leaves the Mac")
    func privacy() {
        for expected in ["licence", "new version", "provider"] {
            #expect(Onboarding.privacy.localizedCaseInsensitiveContains(expected),
                    "la promesa no menciona \(expected)")
        }
        #expect(Onboarding.privacy.contains("no account"))
    }
}

@Suite("Telling a chat model from an embedding model")
struct ChatCapableTests {

    @Test("embedding models are never offered as the one that answers")
    func filtersEmbeddings() {
        for name in ["nomic-embed-text:latest", "bge-m3:latest", "text-embedding-3-small",
                     "gte-large", "all-minilm"] {
            #expect(!LocalModels.canChat(name), "\(name) no sabe conversar")
        }
    }

    @Test("real chat models survive the filter")
    func keepsChatModels() {
        for name in ["qwen2.5:latest", "llama3.2", "mistral-7b", "phi-4", "gemma2:9b"] {
            #expect(LocalModels.canChat(name))
        }
    }

    @Test("a library of only embedding models counts as nothing to talk to")
    func embeddingsOnlyIsEmpty() {
        // Exactly the case on the machine where this was found: qwen plus two embedding models,
        // and the app taking whichever came first.
        let json = Data(#"{"models":[{"name":"nomic-embed-text:latest"},{"name":"bge-m3:latest"}]}"#.utf8)
        #expect(LocalModels.models(in: json).filter(LocalModels.canChat).isEmpty)
    }
}
