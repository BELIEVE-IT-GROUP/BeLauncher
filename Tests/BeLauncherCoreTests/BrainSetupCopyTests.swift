import Testing
import Foundation
@testable import BeLauncherCore

/// Lo que la persona lee cuando mira su cerebro y cuando mira si el asistente recibe algo.
/// El fallo que motiva casi todas estas pruebas es el mismo: que algo roto se lea como sano.
@Suite("Lo que se le enseña a la persona sobre su cerebro")
struct BrainSetupCopyTests {

    // MARK: - Números

    @Test("Un cerebro vacío lo dice, y dice qué hacer para llenarlo")
    func cerebroVacio() {
        let readout = BrainSetupCopy.readout(passages: 0, vectorised: 0,
                                             engine: "bge-m3", isLocal: true)
        #expect(readout.headline.contains("Nothing is indexed"))
        #expect(readout.detail.contains("copy a piece of text"))
        #expect(readout.percent == 0)
        #expect(readout.isComplete == false)
    }

    @Test("Con todo procesado no queda ninguna cifra pendiente a la vista")
    func indiceCompleto() {
        let readout = BrainSetupCopy.readout(passages: 1_240, vectorised: 1_240,
                                             engine: "bge-m3", isLocal: true)
        #expect(readout.isComplete)
        #expect(readout.percent == 1)
        #expect(readout.detail == "All of them understand meaning.")
        #expect(readout.headline.contains("1,240"))
    }

    @Test("A medio procesar se dice cuántos faltan, no solo cuántos van")
    func indiceAMedias() {
        let readout = BrainSetupCopy.readout(passages: 1_000, vectorised: 400,
                                             engine: "bge-m3", isLocal: true)
        #expect(readout.isComplete == false)
        #expect(readout.detail.contains("600"))
        #expect(readout.percent == 0.4)
    }

    @Test("Sin ningún vector todavía no se dice que falten cero")
    func indiceSinVectores() {
        let readout = BrainSetupCopy.readout(passages: 50, vectorised: 0,
                                             engine: "bge-m3", isLocal: true)
        #expect(readout.detail.contains("None of them"))
        #expect(readout.detail.contains("still to process") == false)
    }

    @Test("Sin modelo se avisa de que la búsqueda por palabras sigue funcionando")
    func sinModeloNoSuenaRoto() {
        let readout = BrainSetupCopy.readout(passages: 300, vectorised: 0,
                                             engine: nil, isLocal: false)
        #expect(readout.needsModel)
        #expect(readout.engineLine.contains(ModelInstall.wordSearchStillWorks))
        #expect(readout.detail.contains("the model is missing"))
    }

    @Test("Un modelo local promete que nada sale a internet; uno remoto no lo promete")
    func localFrenteARemoto() {
        let local = BrainSetupCopy.readout(passages: 10, vectorised: 10,
                                           engine: "bge-m3", isLocal: true)
        let remoto = BrainSetupCopy.readout(passages: 10, vectorised: 10,
                                            engine: "text-embedding-3-small", isLocal: false)
        #expect(local.engineLine.contains("on your Mac"))
        #expect(local.engineLine.contains("Nothing goes to the internet"))
        #expect(remoto.engineLine.contains("leaves your Mac"))
        #expect(remoto.engineLine.contains("Nothing goes to the internet") == false)
    }

    @Test("Un solo fragmento se dice en singular")
    func singular() {
        let readout = BrainSetupCopy.readout(passages: 1, vectorised: 1,
                                             engine: "bge-m3", isLocal: true)
        #expect(readout.headline.contains("One fragment of"))
    }

    @Test("Cada idioma agrupa los miles a su manera, sin depender de la región del Mac")
    func agrupacionDeMiles() {
        // Antes se forzaba el punto siempre. Con el inglés por defecto eso deja "1.240" delante de
        // un lector estadounidense, que lo lee como uno coma doscientos cuarenta.
        #expect(BrainSetupCopy.number(1_240) == "1,240")
        #expect(BrainSetupCopy.number(999) == "999")
        #expect(BrainSetupCopy.number(1_000_000) == "1,000,000")
    }

    @Test("Un porcentaje nunca pasa de uno aunque sobren vectores")
    func porcentajeAcotado() {
        let readout = BrainSetupCopy.readout(passages: 10, vectorised: 40,
                                             engine: "bge-m3", isLocal: true)
        #expect(readout.percent == 1)
    }

    // MARK: - Veredicto de la conexión

    static func report(_ name: String, failing: MCPHealth.Step?) -> MCPHealth.Report {
        MCPHealth.report(
            clientName: name,
            configured: failing != .configured,
            launch: failing == .launched ? .failed("ruta inválida") : .started,
            handshake: failing == .handshake ? nil : MCPHealthTests.initializeReply(),
            toolsList: failing == .toolsListed
                ? MCPHealthTests.toolsListReply(names: [])
                : MCPHealthTests.toolsListReply(names: ["recall"]),
            toolCall: failing == .toolCalled
                ? MCPHealthTests.toolCallReply(text: "No sé nada sobre eso todavía.")
                // El eco de la ejecución, no la pregunta repetida: toda herramienta repite la
                // pregunta dentro de su «no encontré nada», así que buscar la pregunta daba verde
                // con el cerebro vacío.
                : MCPHealthTests.toolCallReply(text: "\(MCPHealthTests.eco) 42"),
            echoing: MCPHealthTests.eco
        )
    }

    @Test("Sin haber comprobado nada no se dice ni que va ni que falla")
    func sinComprobar() {
        let veredicto = BrainSetupCopy.verdict(for: nil)
        #expect(veredicto.level == .unknown)
        #expect(veredicto.label == "unchecked")
        #expect(veredicto.whatToDo.isEmpty == false)
    }

    @Test("Solo se dice que responde con datos cuando pasan los cinco pasos")
    func todoEnVerde() {
        let veredicto = BrainSetupCopy.verdict(for: Self.report("Claude", failing: nil))
        #expect(veredicto.level == .working)
        #expect(veredicto.label == "answers with data")
        #expect(veredicto.whatToDo.isEmpty)
    }

    @Test("El fallo de hoy, contestar vacío, se lee como fallo y no como conectado")
    func respondePeroVacio() {
        let veredicto = BrainSetupCopy.verdict(for: Self.report("Claude", failing: .toolCalled))
        #expect(veredicto.level == .broken)
        #expect(veredicto.label == "comes back empty")
        #expect(veredicto.headline.contains("no real datum"))
        #expect(veredicto.whatToDo.contains("Rebuild the index"))
    }

    @Test("Cada paso que falla lleva su propia instrucción, nunca la misma para todos")
    func cadaPasoSuArreglo() {
        let instrucciones = MCPHealth.Step.allCases.map { BrainSetupCopy.whatToDo(about: $0) }
        #expect(Set(instrucciones).count == MCPHealth.Step.allCases.count)
        #expect(instrucciones.allSatisfy { !$0.isEmpty })
    }

    @Test("Cada paso que falla se resume con palabras distintas en la etiqueta")
    func cadaPasoSuEtiqueta() {
        let etiquetas = MCPHealth.Step.allCases.map { BrainSetupCopy.shortFailure($0) }
        #expect(Set(etiquetas).count == MCPHealth.Step.allCases.count)
        #expect(etiquetas.contains("comes back empty"))
        // Ni «conectado» ni «connected»: la etiqueta nombra lo que no está pasando, en el idioma
        // que sea. Que la app hable inglés no relaja la regla que la hizo existir.
        #expect(etiquetas.contains { $0.contains("conectado") || $0.contains("connected") } == false)
    }

    @Test("No estar en la configuración manda a conectar, no a reinstalar")
    func sinConfigurar() {
        let veredicto = BrainSetupCopy.verdict(for: Self.report("Cursor", failing: .configured))
        #expect(veredicto.level == .broken)
        #expect(veredicto.label == "not set up")
        #expect(veredicto.whatToDo.contains("Connect"))
    }

    @Test("El resumen de varios clientes nombra a los que no reciben nada")
    func resumenConRotos() {
        let resumen = BrainSetupCopy.summary(of: [
            Self.report("Claude", failing: nil),
            Self.report("Cursor", failing: .toolCalled),
        ])
        #expect(resumen.level == .broken)
        #expect(resumen.headline.contains("Cursor"))
        #expect(resumen.headline.contains("Claude") == false)
    }

    @Test("El resumen sin ningún informe no se pone en verde por defecto")
    func resumenVacio() {
        let resumen = BrainSetupCopy.summary(of: [])
        #expect(resumen.level == .unknown)
        #expect(resumen.level != .working)
    }

    @Test("El resumen en verde solo aparece cuando todos los clientes traen datos")
    func resumenTodoBien() {
        let resumen = BrainSetupCopy.summary(of: [
            Self.report("Claude", failing: nil),
            Self.report("Cursor", failing: nil),
        ])
        #expect(resumen.level == .working)
        #expect(resumen.headline.contains("2"))
    }

    @Test("El texto del botón de comprobar promete lo que hace, no una conexión")
    func botonHonesto() {
        #expect(BrainSetupCopy.checkButton.contains("Really check"))
        #expect(BrainSetupCopy.checkExplanation.contains("configuration file"))
        // Y lo mismo en español: la promesa del botón no puede perderse al traducir.
        #expect(Loc.render(BrainSetupCopy.checkButton, in: .spanish).contains("de verdad"))
    }

    // MARK: - Pantalla de puesta a punto

    @Test("La pantalla explica el porqué con un ejemplo, no con jerga")
    func porqueConEjemplo() {
        let jerga = ["embedding", "vectorial", "vectorización", "coseno", "modelo de lenguaje",
                     "vector", "cosine", "language model"]
        let texto = (BrainSetupCopy.setupTitle + BrainSetupCopy.setupWhy
                     + BrainSetupCopy.setupCost).lowercased()
        #expect(jerga.allSatisfy { !texto.contains($0) })
        #expect(BrainSetupCopy.setupWhy.contains("1000 EUR"))
    }

    @Test("Se dice que la app se sigue usando mientras descarga y que se puede saltar")
    func sePuedeSeguirSinEl() {
        #expect(BrainSetupCopy.setupKeepUsing.contains("Keep using"))
        #expect(BrainSetupCopy.setupSkip == "Carry on without it")
        #expect(BrainSetupCopy.setupLater.contains("Settings"))
        #expect(Loc.render(BrainSetupCopy.setupSkip, in: .spanish) == "Seguir sin él")
    }

    @Test("Nada se instala sin que la persona lo pulse, y el texto lo dice")
    func nadaSilencioso() {
        #expect(BrainSetupCopy.installExplanation.contains("nothing runs until you press something"))
    }

    // MARK: - Lo que «Conectar» puede afirmar

    /// El mensaje anterior era «X ya puede consultar tu cerebro. Reinícialo para que lo vea»:
    /// escribir una ruta en un JSON no prueba que el asistente arranque nada, y el fallo más
    /// común de la sonda es justo ese, en máquinas cuyo archivo de configuración estaba perfecto.
    @Test("Conectar dice que escribió la configuración, no que el asistente ya consulte el cerebro")
    func conectarNoAfirmaLaConexion() {
        let mensaje = BrainSetupCopy.connectWrote(client: "Cursor")
        #expect(mensaje.contains("Cursor"))
        #expect(mensaje.lowercased().contains("wrote"))
        #expect(!mensaje.contains("can now consult"))
        // Y termina llevando a comprobarlo de verdad, que es lo único que zanja la duda.
        #expect(mensaje.contains(BrainSetupCopy.checkButton))
    }

    @Test("Que el archivo ya mencionara BeLauncher tampoco se cuenta como estar conectado")
    func yaEstabaEnElArchivo() {
        let mensaje = BrainSetupCopy.connectAlreadyThere(client: "Claude Code")
        #expect(mensaje.contains("Claude Code"))
        #expect(mensaje.contains("no proof"))
        #expect(mensaje.contains(BrainSetupCopy.checkButton))
    }
}
