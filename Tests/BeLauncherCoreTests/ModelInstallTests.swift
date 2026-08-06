import Testing
import Foundation
@testable import BeLauncherCore

/// El plan de instalación del modelo de embeddings. Nada de esto toca la red ni el disco: es la
/// parte que decide qué falta, a partir de lo que alguien más observó.
@Suite("Plan según el estado de la máquina")
struct ModelInstallPlanTests {

    @Test("Sin Ollama, el plan pide instalar, abrir y descargar, en ese orden")
    func sinOllama() {
        let state = ModelInstall.MachineState(
            ollamaInstalled: false, ollamaRunning: false, modelPresent: false)
        #expect(ModelInstall.plan(for: state) == [.installOllama, .startOllama, .pullModel])
    }

    @Test("Con Ollama instalado pero parado, solo falta abrirlo y descargar")
    func ollamaParado() {
        let state = ModelInstall.MachineState(
            ollamaInstalled: true, ollamaRunning: false, modelPresent: false)
        #expect(ModelInstall.plan(for: state) == [.startOllama, .pullModel])
    }

    @Test("Con Ollama corriendo pero sin el modelo, solo falta descargarlo")
    func sinModelo() {
        let state = ModelInstall.MachineState(
            ollamaInstalled: true, ollamaRunning: true, modelPresent: false)
        #expect(ModelInstall.plan(for: state) == [.pullModel])
    }

    @Test("Con todo listo, el plan está vacío")
    func todoListo() {
        let state = ModelInstall.MachineState(
            ollamaInstalled: true, ollamaRunning: true, modelPresent: true)
        #expect(ModelInstall.plan(for: state).isEmpty)
        #expect(state.isReady)
    }

    @Test("Un modelo presente con el servidor parado no cuenta como listo")
    func modeloSinServidor() {
        // Lo que se descargó ayer no sirve si Ollama no está corriendo hoy; el plan tiene que
        // seguir pidiendo que se abra, no dar la búsqueda por semántica por buena.
        let state = ModelInstall.MachineState(
            ollamaInstalled: true, ollamaRunning: false, modelPresent: true)
        #expect(ModelInstall.plan(for: state) == [.startOllama])
        #expect(!state.isReady)
    }
}

@Suite("Mientras no haya modelo, la app sigue funcionando")
struct ModelInstallStillWorksTests {

    @Test("El estado sin modelo dice explícitamente que la búsqueda por palabras sigue activa")
    func loDiceExplicitamente() {
        let state = ModelInstall.MachineState(
            ollamaInstalled: false, ollamaRunning: false, modelPresent: false)
        let mensaje = ModelInstall.message(for: .notReady(state))
        #expect(mensaje.contains(ModelInstall.wordSearchStillWorks))
    }

    @Test("Ese estado nunca se cuenta como ocupado ni como fallo")
    func noEsUnFallo() {
        let state = ModelInstall.MachineState(
            ollamaInstalled: false, ollamaRunning: false, modelPresent: false)
        let fase = ModelInstall.Phase.notReady(state)
        #expect(!fase.isBusy)
        #expect(!fase.canCancel)
    }

    @Test("El mensaje de listo nombra el modelo que quedó activo")
    func mensajeListo() {
        #expect(ModelInstall.message(for: .ready(model: "bge-m3")).contains("bge-m3"))
    }
}

@Suite("Progreso de la descarga de ollama pull")
struct ModelInstallPullProgressTests {

    @Test("Una línea con total y completado se convierte en fracción")
    func fraccionNormal() throws {
        let linea = #"{"status":"pulling 8934d96d3f08","total":1000,"completed":250}"#
        let parsed = try #require(ModelInstall.parsePullLine(linea))
        #expect(parsed.fraction == 0.25)
    }

    @Test("Total en cero no revienta la división, da 0%")
    func totalCero() throws {
        let linea = #"{"status":"pulling manifest","total":0,"completed":0}"#
        let parsed = try #require(ModelInstall.parsePullLine(linea))
        #expect(parsed.fraction == 0)
    }

    @Test("Sin el campo total, también da 0% en vez de fallar")
    func sinTotal() throws {
        let linea = #"{"status":"verifying sha256 digest"}"#
        let parsed = try #require(ModelInstall.parsePullLine(linea))
        #expect(parsed.fraction == 0)
    }

    @Test("completed nunca supera el 100%, aunque el total venga mal")
    func fraccionTope() throws {
        let linea = #"{"status":"pulling x","total":100,"completed":500}"#
        let parsed = try #require(ModelInstall.parsePullLine(linea))
        #expect(parsed.fraction == 1)
    }

    @Test("El estado success se reconoce como terminado")
    func exito() throws {
        let parsed = try #require(ModelInstall.parsePullLine(#"{"status":"success"}"#))
        #expect(parsed.isDone)
    }

    @Test("Una línea corrupta o cortada a mitad no rompe la descarga, se ignora")
    func lineaCorrupta() {
        #expect(ModelInstall.parsePullLine("") == nil)
        #expect(ModelInstall.parsePullLine("   ") == nil)
        #expect(ModelInstall.parsePullLine(#"{"status":"pulling x","tot"#) == nil)
        #expect(ModelInstall.parsePullLine("no es json en absoluto") == nil)
        #expect(ModelInstall.parsePullLine("{}") == nil)
    }

    @Test("Una línea de error se distingue de una de progreso")
    func lineaDeError() throws {
        let linea = #"{"error":"pull model manifest: file does not exist"}"#
        let parsed = try #require(ModelInstall.parsePullLine(linea))
        #expect(parsed.error == "pull model manifest: file does not exist")
    }

    @Test("El texto legible incluye el porcentaje mientras descarga")
    func textoLegible() {
        #expect(ModelInstall.describe(status: "pulling 8934d96d3f08", fraction: 0.42).contains("42"))
        #expect(ModelInstall.describe(status: "pulling manifest", fraction: 0).contains("Preparando"))
        #expect(ModelInstall.describe(status: "success", fraction: 1).contains("Listo"))
    }

    @Test("Cada capa se distingue por su digest, no por el texto del estado")
    func digest() throws {
        let linea = #"{"status":"pulling 8934d96d","digest":"sha256:8934d96d","total":10,"completed":5}"#
        let parsed = try #require(ModelInstall.parsePullLine(linea))
        #expect(parsed.digest == "sha256:8934d96d")
    }
}

/// La barra que no puede retroceder.
///
/// `ollama pull` baja varias capas y empieza el contador de cada una en cero. Con la fracción de
/// una sola línea, una descarga real pintaba 94% y a la línea siguiente 7%: la persona ve que la
/// app perdió lo descargado. Estas pruebas son la razón de que `PullProgress` exista.
@Suite("Progreso acumulado entre capas")
struct ModelInstallProgressAccumulationTests {

    /// Una tanda real: una capa pequeña que termina, y después la grande que empieza de cero.
    private static let secuencia = [
        #"{"status":"pulling manifest"}"#,
        #"{"status":"pulling aaa","digest":"sha256:aaa","total":20000000,"completed":10000000}"#,
        #"{"status":"pulling aaa","digest":"sha256:aaa","total":20000000,"completed":20000000}"#,
        #"{"status":"pulling bbb","digest":"sha256:bbb","total":1200000000,"completed":0}"#,
        #"{"status":"pulling bbb","digest":"sha256:bbb","total":1200000000,"completed":600000000}"#,
        #"{"status":"pulling bbb","digest":"sha256:bbb","total":1200000000,"completed":1200000000}"#,
        #"{"status":"verifying sha256 digest"}"#,
        #"{"status":"success"}"#,
    ]

    @Test("La fracción nunca baja cuando empieza una capa nueva")
    func nuncaRetrocede() {
        var progress = ModelInstall.PullProgress()
        var anterior = 0.0
        var fracciones: [Double] = []
        for linea in Self.secuencia {
            guard let parsed = ModelInstall.parsePullLine(linea) else { continue }
            progress.absorb(parsed)
            fracciones.append(progress.fraction)
            #expect(progress.fraction >= anterior,
                    "la barra retrocedió de \(anterior) a \(progress.fraction) en «\(parsed.status)»")
            anterior = progress.fraction
        }
        // Y no se queda plana: si acumular significara "ignorar todo", esta prueba pasaría igual.
        #expect(fracciones.contains { $0 > 0.4 })
    }

    @Test("Los bytes son la suma de todas las capas, no los de la última línea")
    func sumaDeCapas() {
        var progress = ModelInstall.PullProgress()
        for linea in Self.secuencia.prefix(5) {
            guard let parsed = ModelInstall.parsePullLine(linea) else { continue }
            progress.absorb(parsed)
        }
        #expect(progress.completedBytes == 620_000_000)
        #expect(progress.knownTotalBytes == 1_220_000_000)
    }

    @Test("Al terminar, la barra llega al 100% aunque el modelo pese menos de lo previsto")
    func terminaEnUno() {
        var progress = ModelInstall.PullProgress()
        progress.absorb(ModelInstall.PullLine(status: "pulling aaa", total: 500, completed: 500,
                                              digest: "sha256:aaa"))
        #expect(progress.fraction < 1)
        progress.absorb(ModelInstall.PullLine(status: "success", total: 0, completed: 0))
        #expect(progress.fraction == 1)
        #expect(progress.isDone)
    }

    @Test("Las líneas sin tamaño cambian el texto pero no mueven la barra")
    func lineasSinTamano() {
        var progress = ModelInstall.PullProgress()
        progress.absorb(ModelInstall.PullLine(status: "pulling bbb", total: 1_200_000_000,
                                              completed: 600_000_000, digest: "sha256:bbb"))
        let antes = progress.fraction
        progress.absorb(ModelInstall.PullLine(status: "verifying sha256 digest",
                                              total: 0, completed: 0))
        #expect(progress.fraction == antes)
        #expect(progress.status == "verifying sha256 digest")
    }

    @Test("El texto de la descarga dice cuántos bytes de cuántos, no solo un porcentaje")
    func textoConBytes() {
        var progress = ModelInstall.PullProgress()
        progress.absorb(ModelInstall.PullLine(status: "pulling bbb", total: 1_200_000_000,
                                              completed: 600_000_000, digest: "sha256:bbb"))
        let texto = ModelInstall.describe(progress)
        #expect(texto.contains("%"))
        #expect(texto.contains("de"))
        #expect(texto.contains("GB") || texto.contains("MB"))
    }
}

/// Cómo se pone Ollama en marcha en ESTE Mac.
///
/// El botón «Instalar con Homebrew» instala la fórmula de línea de comandos: no deja ningún
/// `Ollama.app`. El código viejo intentaba abrir esa aplicación y, al fallar, decía «Ábrelo desde
/// Aplicaciones», mandando a la persona a buscar algo que ese mismo botón garantizó que no
/// existiera.
@Suite("Cómo arrancar Ollama según cómo esté instalado")
struct ModelInstallStartMethodTests {

    @Test("Con la app instalada, se abre la app")
    func conApp() {
        #expect(ModelInstall.startMethod(appPresent: true, brewPresent: true,
                                         binaryPath: "/opt/homebrew/bin/ollama") == .openApp)
    }

    @Test("Instalado por Homebrew y sin app, se arranca el servicio de la fórmula")
    func conFormula() {
        #expect(ModelInstall.startMethod(appPresent: false, brewPresent: true,
                                         binaryPath: "/opt/homebrew/bin/ollama") == .brewService)
    }

    @Test("Con el binario pero sin Homebrew, se ejecuta el binario directamente")
    func conBinario() {
        #expect(ModelInstall.startMethod(appPresent: false, brewPresent: false,
                                         binaryPath: "/usr/local/bin/ollama")
                == .serveCommand("/usr/local/bin/ollama"))
    }

    @Test("Sin nada instalado, no hay nada que arrancar")
    func sinNada() {
        #expect(ModelInstall.startMethod(appPresent: false, brewPresent: true,
                                         binaryPath: nil) == .notInstalled)
    }

    @Test("El fallo del camino Homebrew no manda a Aplicaciones, donde no hay nada")
    func falloSinApp() {
        let porFormula = ModelInstall.startFailure(for: .brewService)
        #expect(!porFormula.contains("Aplicaciones"))
        #expect(porFormula.contains("brew services start ollama"))

        let porBinario = ModelInstall.startFailure(for: .serveCommand("/usr/local/bin/ollama"))
        #expect(!porBinario.contains("Aplicaciones"))
        #expect(porBinario.contains("/usr/local/bin/ollama"))

        // Y cuando la app SÍ está, sigue siendo el consejo correcto.
        #expect(ModelInstall.startFailure(for: .openApp).contains("Aplicaciones"))
    }

    @Test("El paso se llama poner en marcha, no abrir: con Homebrew no hay nada que abrir")
    func tituloDelPaso() {
        #expect(!ModelInstall.Step.startOllama.title.contains("Abrir"))
    }
}

@Suite("Clasificación de errores de la descarga")
struct ModelInstallPullFailureTests {

    @Test("Sin espacio en disco se reconoce y lo dice")
    func sinEspacio() {
        #expect(ModelInstall.PullFailure.classify("write /root/.ollama/models: no space left on device")
                == .noDiskSpace)
        #expect(ModelInstall.PullFailure.noDiskSpace.description.contains("espacio"))
    }

    @Test("Sin red se reconoce y lo dice")
    func sinRed() {
        #expect(ModelInstall.PullFailure.classify("The Internet connection appears to be offline.")
                == .network)
        #expect(ModelInstall.PullFailure.network.description.contains("conexión"))
    }

    @Test("El servidor de Ollama caído se reconoce y lo dice")
    func servidorCaido() {
        #expect(ModelInstall.PullFailure.classify("Could not connect to the server") == .serverDown)
        #expect(ModelInstall.PullFailure.serverDown.description.contains("Ollama"))
    }

    /// Todo lo que fuera 400 o más se reportaba como `.serverDown`, o sea «Ollama no responde».
    /// Un 404 es justo lo contrario: Ollama respondió, y lo que dijo es que no conoce el modelo.
    @Test("Un 404 dice que falta el modelo, no que Ollama esté caído")
    func modeloInexistente() {
        let fallo = ModelInstall.PullFailure.forHTTP(status: 404, model: "bge-m3")
        #expect(fallo == .modelNotFound("bge-m3"))
        #expect(fallo != .serverDown)
        #expect(fallo.description.contains("bge-m3"))
        #expect(!fallo.description.contains("no responde"))
    }

    @Test("Un 503 sí es el servidor sin responder")
    func servidorNoDisponible() {
        #expect(ModelInstall.PullFailure.forHTTP(status: 503, model: "bge-m3") == .serverDown)
    }

    @Test("Un código sin significado conocido se cuenta tal cual, sin inventar la causa")
    func codigoRaro() {
        guard case .other(let raw) = ModelInstall.PullFailure.forHTTP(status: 418, model: "bge-m3")
        else {
            Issue.record("un código desconocido no puede convertirse en un diagnóstico inventado")
            return
        }
        #expect(raw.contains("418"))
    }

    @Test("Un error desconocido no se inventa una causa, pero sí lo cuenta")
    func desconocido() {
        guard case .other(let raw) = ModelInstall.PullFailure.classify("algo raro pasó") else {
            Issue.record("un error sin patrón conocido debe caer en .other, no adivinar una causa")
            return
        }
        #expect(raw == "algo raro pasó")
    }
}

@Suite("Espacio en disco antes de empezar la descarga")
struct ModelInstallDiskSpaceTests {

    @Test("Con espacio de sobra, la descarga puede empezar")
    func sobraEspacio() {
        #expect(ModelInstall.hasEnoughDiskSpace(freeBytes: 10_000_000_000))
    }

    @Test("Sin espacio suficiente, se avisa antes de tocar la red")
    func faltaEspacio() {
        #expect(!ModelInstall.hasEnoughDiskSpace(freeBytes: 500_000_000))
        let mensaje = ModelInstall.spaceMessage(freeBytes: 500_000_000)
        #expect(mensaje.contains("GB") || mensaje.contains("MB"))
    }

    @Test("El aviso de espacio insuficiente queda modelado como su propia fase, no como un fallo genérico")
    func faseDedicada() {
        let fase = ModelInstall.Phase.insufficientSpace(freeBytes: 500_000_000)
        #expect(!fase.isBusy)
        if case .failed = fase {
            Issue.record("sin espacio no es lo mismo que un fallo de red o de servidor")
        }
    }
}

@Suite("Fases de la instalación")
struct ModelInstallPhaseTests {

    private static func descargando(_ fraction: Double = 0.5) -> ModelInstall.Phase {
        var progress = ModelInstall.PullProgress()
        progress.absorb(ModelInstall.PullLine(
            status: "pulling x",
            total: ModelInstall.expectedModelBytes,
            completed: Int64(Double(ModelInstall.expectedModelBytes) * fraction),
            digest: "sha256:x"))
        return .downloading(progress)
    }

    @Test("Solo las fases que están trabajando de verdad bloquean un segundo intento")
    func ocupado() {
        #expect(ModelInstall.Phase.checking.isBusy)
        #expect(ModelInstall.Phase.installingOllama.isBusy)
        #expect(ModelInstall.Phase.startingOllama.isBusy)
        #expect(Self.descargando().isBusy)
        #expect(!ModelInstall.Phase.idle.isBusy)
        #expect(!ModelInstall.Phase.cancelled.isBusy)
        #expect(!ModelInstall.Phase.ready(model: "bge-m3").isBusy)
        #expect(!ModelInstall.Phase.failed("x").isBusy)
    }

    @Test("Solo la descarga se puede cancelar")
    func cancelable() {
        #expect(Self.descargando().canCancel)
        #expect(!ModelInstall.Phase.checking.canCancel)
        #expect(!ModelInstall.Phase.installingOllama.canCancel)
        #expect(!ModelInstall.Phase.ready(model: "bge-m3").canCancel)
    }

    /// Lo que protege de que un `check()` tardío pise una descarga en curso: solo las fases que la
    /// persona puso en marcha cuentan como "operando", y esas no se repintan por detrás.
    @Test("Una comprobación de fondo no puede pisar lo que la persona puso en marcha")
    func operando() {
        #expect(ModelInstall.Phase.installingOllama.isOperating)
        #expect(ModelInstall.Phase.startingOllama.isOperating)
        #expect(Self.descargando().isOperating)
        #expect(!ModelInstall.Phase.checking.isOperating)
        #expect(!ModelInstall.Phase.idle.isOperating)
        #expect(!ModelInstall.Phase.cancelled.isOperating)
        #expect(!ModelInstall.Phase.notReady(ModelInstall.MachineState(
            ollamaInstalled: true, ollamaRunning: true, modelPresent: false)).isOperating)
    }

    /// «Todavía no se ha mirado» y «estoy mirando» son cosas distintas. Se pintaban con el mismo
    /// spinner, así que una sección parada giraba para siempre bajo un texto falso.
    @Test("Sin comprobar tiene su propio texto, distinto del de estar comprobando")
    func idleNoEsChecking() {
        let sinComprobar = ModelInstall.message(for: .idle)
        #expect(!sinComprobar.isEmpty)
        #expect(sinComprobar != ModelInstall.message(for: .checking))
    }

    /// Cancelar a mitad de 2 GB dejaba la fase en `.idle`, es decir, un spinner eterno diciendo
    /// «Mirando qué hay en este Mac…» y ningún botón para reintentar.
    @Test("Cancelar tiene su propia fase, que no gira y explica qué pasó")
    func cancelada() {
        let fase = ModelInstall.Phase.cancelled
        #expect(!fase.isBusy)
        #expect(fase != .idle)
        let mensaje = ModelInstall.message(for: fase)
        #expect(mensaje.contains("cancel"))
        #expect(mensaje != ModelInstall.message(for: .idle))
        #expect(!mensaje.contains("Mirando"))
    }
}
