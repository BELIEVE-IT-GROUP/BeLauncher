import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Verbs over what you copied")
struct AIVerbTests {

    private let local = IntelligenceProvider.named("ollama")!
    private let cloud = IntelligenceProvider.named("anthropic")!

    private func runner(_ answer: String, providers: [IntelligenceProvider],
                        preferred: String) -> AIVerbRunner {
        let json = #"{"choices":[{"message":{"content":"\#(answer)"}}]}"#
        let client = IntelligenceClient(
            transport: { _ in (Data(json.utf8), URLResponse()) },
            keyLookup: { _ in "user-own-key" }
        )
        return AIVerbRunner(client: client, router: ModelRouter(preferred: preferred),
                            providers: providers)
    }

    @Test("a verb carries its own instruction, so nobody has to explain themselves twice")
    func verbsAreSelfContained() {
        for verb in AIVerb.all {
            #expect(!verb.instruction.isEmpty)
            #expect(!verb.title.isEmpty)
        }
        #expect(Set(AIVerb.all.map(\.id)).count == AIVerb.all.count)
    }

    @Test("what gets offered depends on what you copied")
    func suggestionsFitTheContent() {
        let json = AIVerb.suggested(for: #"{"a": 1, "b": [2,3]}"#)
        #expect(json.first?.id == "json")

        let long = AIVerb.suggested(for: String(repeating: "palabra ", count: 200))
        #expect(long.contains { $0.id == "summarise" })

        let email = AIVerb.suggested(for: "Hola Jorge, ¿podemos vernos el martes?")
        #expect(email.contains { $0.id == "reply" })

        #expect(AIVerb.suggested(for: "cualquier cosa").count <= 5,
                "a list of eleven options is a list nobody reads")
    }

    @Test("a verb is never offered twice, however many rules suggest it")
    func noDuplicates() {
        // Long, multi-line and tabular: three rules all reach for "summarise".
        let text = String(repeating: "fila\tcolumna\n", count: 40)
        let suggested = AIVerb.suggested(for: text)
        #expect(Set(suggested.map(\.id)).count == suggested.count,
                "the same verb listed twice looks broken, because it is")
    }

    @Test("extracting tasks from a meeting never reaches a cloud model by default")
    func confidentialVerbStaysLocal() async throws {
        let tasks = try #require(AIVerb.named("extract-tasks"))
        #expect(tasks.sensitivity == .confidential)

        // Preferring the cloud, but the material is company material: it must go local.
        let runner = runner("- Enviar propuesta", providers: [cloud, local], preferred: "anthropic")
        let result = try await runner.run(tasks, on: "Acordamos enviar la propuesta el viernes")
        #expect(result == "- Enviar propuesta")
    }

    @Test("with no local model, a confidential verb refuses instead of leaking")
    func refusesWhenOnlyCloud() async {
        let runner = runner("x", providers: [cloud], preferred: "anthropic")
        let tasks = AIVerb.named("extract-tasks")!
        await #expect(throws: IntelligenceError.self) {
            try await runner.run(tasks, on: "material de empresa")
        }
    }

    @Test("an ordinary verb honours the model you chose")
    func ordinaryVerbUsesPreference() async throws {
        let runner = runner("formateado", providers: [local, cloud], preferred: "anthropic")
        let json = AIVerb.named("json")!
        #expect(json.sensitivity == .ordinary)
        #expect(try await runner.run(json, on: "{\"a\":1}") == "formateado")
    }

    @Test("empty input is refused before any model is bothered")
    func refusesEmpty() async {
        let runner = runner("x", providers: [local], preferred: "ollama")
        await #expect(throws: IntelligenceError.emptyAnswer) {
            try await runner.run(AIVerb.named("fix")!, on: "   \n  ")
        }
    }

    @Test("the prompt carries the text and the instruction, and nothing else")
    func promptShape() async throws {
        actor Capture { 
            var body: String = ""
            func store(_ value: String) { body = value }
        }
        let capture = Capture()
        let client = IntelligenceClient(
            transport: { request in
                await capture.store(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                return (Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8), URLResponse())
            },
            keyLookup: { _ in "k" }
        )
        let runner = AIVerbRunner(client: client, router: ModelRouter(preferred: "ollama"),
                                  providers: [local])
        _ = try await runner.run(AIVerb.named("fix")!, on: "testo con herrores")

        let body = await capture.body
        #expect(body.contains("testo con herrores"))
        #expect(body.contains("Fix spelling"))
    }
}

@Suite("AI verbs inside the window")
@MainActor
struct AIInLauncherTests {

    private let clip = Clip(id: 1, text: "Acordamos con Acme enviar la propuesta el viernes y "
                            + "revisar el precio antes de fin de mes.", sourceApp: "Mail")

    @Test("verbs show up as actions on a clip, grouped apart")
    func verbsAppearAsActions() {
        let model = LauncherModel(dataSource: { SearchInput(clips: [self.clip]) }, perform: { _ in })
        model.activate()
        model.query = "acme"

        let aiActions = model.actions.filter { $0.section == .ai }
        #expect(!aiActions.isEmpty)
        #expect(aiActions.allSatisfy { $0.id.hasPrefix("ai-") })
        #expect(model.actions.first?.section == .primary, "the everyday action still comes first")
    }

    @Test("nothing is offered for a scrap too short to be worth a model")
    func skipsTinyText() {
        let tiny = Clip(id: 2, text: "ok", sourceApp: "Notes")
        let model = LauncherModel(dataSource: { SearchInput(clips: [tiny]) }, perform: { _ in })
        model.activate()
        model.query = "ok"
        #expect(model.actions.filter { $0.section == .ai }.isEmpty)
    }

    @Test("running a verb shows work in progress instead of freezing")
    func showsProgress() {
        var performed: [LauncherModel.Action] = []
        let model = LauncherModel(dataSource: { SearchInput(clips: [self.clip]) },
                                  perform: { performed.append($0) })
        model.activate()
        model.query = "acme"

        let summarise = try! #require(model.actions.first { $0.id == "ai-summarise" })
        model.run(summarise)

        #expect(model.aiState == .working("Summarise"))
        #expect(performed.contains {
            if case .runVerb(let id, _) = $0 { return id == "summarise" }
            return false
        })
    }

    @Test("Return copies the answer once it is there")
    func returnCopiesTheAnswer() {
        var performed: [LauncherModel.Action] = []
        let model = LauncherModel(dataSource: { SearchInput(clips: [self.clip]) },
                                  perform: { performed.append($0) })
        model.activate()
        model.query = "acme"
        model.aiAnswered(verb: "Resumir", text: "Propuesta el viernes; precio a revisar.")

        model.handle(.enter)
        #expect(performed.contains(.copyToClipboard(text: "Propuesta el viernes; precio a revisar.",
                                                    cursorOffset: nil)))
    }

    @Test("a failure is shown, and the window goes back to normal after it")
    func failureIsRecoverable() {
        let model = LauncherModel(dataSource: { SearchInput(clips: [self.clip]) }, perform: { _ in })
        model.activate()
        model.aiFailed("Falta la clave de Anthropic")
        #expect(model.aiState == .failed("Falta la clave de Anthropic"))

        model.clearAI()
        #expect(model.aiState == .idle)
    }

    @Test("summoning the window again clears whatever the model was showing")
    func activateResets() {
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { _ in })
        model.aiAnswered(verb: "Resumir", text: "algo")
        model.activate()
        #expect(model.aiState == .idle)
    }
}

/// Typing what you want, instead of learning where it is hidden.
@Suite("Asking for something in your own words")
@MainActor
struct TypedVerbTests {

    @Test("«traducir» offers to translate what you last copied")
    func translatesTheClipboard() {
        let clip = Clip(id: 1, text: "Hello there", sourceApp: "Mail", kind: .text)
        let results = SearchEngine.search("traducir", in: SearchInput(clips: [clip]))
        let offer = results.first { $0.id == "verb-translate-es" }
        #expect(offer != nil, "traducir sin adivinar el ritual de seleccionar y pulsar ⌘K")
        #expect(offer?.payload.contains("Hello there") == true)
    }

    @Test("the longest match wins, so «traducir al ingles» is not «traducir»")
    func longestTriggerWins() {
        #expect(AIVerb.typed("traducir al ingles esto")?.verb.id == "translate-en")
        #expect(AIVerb.typed("traducir esto")?.verb.id == "translate-es")
    }

    @Test("text typed after the verb beats the clipboard")
    func explicitArgumentWins() {
        let clip = Clip(id: 1, text: "lo copiado", sourceApp: "Mail", kind: .text)
        let results = SearchEngine.search("resume esta frase larga",
                                          in: SearchInput(clips: [clip]))
        let offer = results.first { $0.id == "verb-summarise" }
        #expect(offer?.payload.contains("esta frase larga") == true)
        #expect(offer?.payload.contains("lo copiado") == false)
    }

    @Test("without clipboard the verb offers a text composer")
    func noSourceOffersComposer() {
        let results = SearchEngine.search("traducir", in: SearchInput())
        let offer = results.first { $0.id == "verb-input-translate-es" }
        #expect(offer != nil)
        #expect(offer?.subtitle == "Write or paste text to continue")
    }

    @Test("ordinary typing never becomes an AI offer by accident")
    func noFalsePositives() {
        #expect(AIVerb.typed("tr") == nil)
        #expect(AIVerb.typed("traduccion automatica") == nil, "solo el verbo, no cualquier palabra")
        #expect(AIVerb.typed("resumen") != nil)
    }

    @Test("running it asks for the verb, on the right text")
    func runsTheVerb() {
        var performed: [LauncherModel.Action] = []
        let clip = Clip(id: 1, text: "Hello there", sourceApp: "Mail", kind: .text)
        let model = LauncherModel(dataSource: { SearchInput(clips: [clip]) },
                                  perform: { performed.append($0) })
        model.activate()
        model.query = "traducir"
        model.handle(.enter)

        guard case .runVerb(let id, let text)? = performed.first else {
            Issue.record("no pidió el verbo: \(performed)"); return
        }
        #expect(id == "translate-es")
        #expect(text == "Hello there")
    }
}

@Suite("Asking the model that is actually installed")
struct ModelChoiceTests {

    @Test("the runner asks for the model it was given, not a hardcoded one")
    func usesTheInstalledModel() async throws {
        final class Recorder: @unchecked Sendable { var model: String? }
        let recorder = Recorder()
        let client = IntelligenceClient(transport: { request in
            let body = try #require(request.httpBody)
            let json = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any])
            recorder.model = json["model"] as? String
            return (Data(#"{"choices":[{"message":{"content":"hola"}}]}"#.utf8),
                    URLResponse())
        })
        let ollama = try #require(IntelligenceProvider.named("ollama"))
        let runner = AIVerbRunner(
            client: client, router: ModelRouter(preferred: "ollama"),
            providers: [ollama], models: ["ollama": "qwen2.5:7b"]
        )
        _ = try await runner.run(try #require(AIVerb.named("translate-es")), on: "hello")

        #expect(recorder.model == "qwen2.5:7b",
                "pedir un modelo que el usuario no tiene es lo que colgaba la app un minuto")
        #expect(recorder.model != ollama.defaultModel)
    }
}
