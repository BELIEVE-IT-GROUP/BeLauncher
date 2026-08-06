import Testing
import Foundation
@testable import BeLauncher

/// La autoprueba que decide si creerle al modelo de voz.
///
/// El fallo del que defiende no es una caída, es una mentira: con el modelo a medias el
/// transcriptor devuelve una frase fluida e inventada, a toda velocidad, y ninguna API dice que
/// pasó. Ese texto entra al índice indistinguible de uno bueno.
///
/// Aquí no hay micrófono ni modelo: se prueba la aritmética que decide, con las dos frases que
/// midió la sonda en este Mac — la buena, que puntuó 1,0, y la basura real que puntuó ~0,3.
@Suite("La autoprueba de la transcripción")
struct TranscriptionTests {

    private let spanish = "el modelo de voz funciona sin conexion a internet"
    /// Lo que devolvió de verdad el transcriptor con el modelo ausente.
    private let garbage = "Astumost very fork CL modedelow"

    @Test("una transcripción inventada no llega al umbral y se rechaza")
    func laBasuraSeRechaza() {
        let score = Transcription.agreement(spoken: spanish, heard: garbage)

        #expect(score < Transcription.trustBar)
        #expect(!Transcription.isTrustworthy(score))
    }

    @Test("una transcripción fiel se acepta")
    func loFielSeAcepta() {
        let score = Transcription.agreement(spoken: spanish, heard: spanish)

        #expect(score == 1)
        #expect(Transcription.isTrustworthy(score))
    }

    @Test("acentos y mayúsculas no cuentan como errores del modelo")
    func losAcentosNoCuentan() {
        let heard = "El Modelo de Voz funciona sin conexión a Internet."

        #expect(Transcription.agreement(spoken: spanish, heard: heard) == 1)
    }

    @Test("una transcripción a medias tampoco pasa el umbral")
    func aMediasTampocoPasa() {
        // La mitad de las palabras largas de la frase. Un modelo que se come media frase es tan
        // inservible como uno que inventa: lo que se guarde sale mal citado para siempre.
        let heard = "el modelo de voz y poco mas"

        let score = Transcription.agreement(spoken: spanish, heard: heard)
        #expect(score < Transcription.trustBar)
    }

    @Test("el silencio puntúa cero, no uno por no contradecir nada")
    func elSilencioPuntuaCero() {
        #expect(Transcription.agreement(spoken: spanish, heard: "") == 0)
        #expect(!Transcription.isTrustworthy(0))
    }

    @Test("sin frase que comparar no se aprueba nada")
    func sinFraseNoSeApruebaNada() {
        // Si esto devolviera 1 —cero de cero— una locale sin frase conocida se daría por buena y
        // la autoprueba dejaría de ser una puerta.
        #expect(Transcription.agreement(spoken: "", heard: "lo que sea") == 0)
    }

    @Test("el umbral queda por encima de lo que puntúa un modelo ausente")
    func elUmbralSeparaLosDosCasos() {
        // La sonda midió 1,0 con el modelo puesto y ~0,3 sin él. El umbral tiene que quedar en
        // medio con holgura, o el arreglo entero deja de servir.
        #expect(Transcription.trustBar > 0.4)
        #expect(Transcription.trustBar < 1)
    }

    @Test("el motivo del rechazo dice qué hacer, no solo que falló")
    func elRechazoDiceQueHacer() {
        let said = Transcription.Failure.untrustworthy(0.3).errorDescription ?? ""

        #expect(said.contains("no"))
        #expect(said.contains("Settings"))
        // Lo importante: dice que NO se guarda nada. Un error que no aclare eso deja a alguien
        // creyendo que la reunión quedó transcrita.
        #expect(said.contains("nothing is kept"))
    }

    @Test("las palabras cortas no inflan la puntuación")
    func lasPalabrasCortasNoCuentan() {
        // "de", "el", "la", "a" no distinguen una transcripción buena de una inventada: cualquier
        // castellano las tiene. Si contaran, la basura medida subiría hacia el umbral.
        #expect(Transcription.words("de a el la un").isEmpty)
        #expect(Transcription.words("modelo voz internet").count == 3)
    }

    @Test("el aviso de macOS viejo se explica sin jerga")
    func elAvisoDeMacOSViejo() {
        #expect(Transcription.unsupportedReason.contains("macOS 26"))
        #expect(Transcription.unsupportedReason.contains("without sending the audio off the Mac"))
    }
}
