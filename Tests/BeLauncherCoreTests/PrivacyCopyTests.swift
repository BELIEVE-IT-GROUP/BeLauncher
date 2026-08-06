import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Textos de privacidad")
struct PrivacyCopyTests {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Pausar

    @Test("mientras captura, el aviso lo dice sin ofrecer reanudar nada")
    func capturando() {
        let banner = PrivacyCopy.banner(for: Privacy.State(), at: noon)
        #expect(!banner.isPaused)
        #expect(banner.resumeTitle.isEmpty)
        #expect(banner.headline.contains("capturing"))
    }

    @Test("una pausa a mano no promete que vuelva sola")
    func pausaIndefinida() {
        let banner = PrivacyCopy.banner(for: Privacy.State(reason: .byHand), at: noon)
        #expect(banner.isPaused)
        #expect(!banner.resumeTitle.isEmpty)
        #expect(!banner.detail.contains("Back on its own"))
    }

    @Test("una pausa con hora dice cuánto falta para que vuelva")
    func pausaConHora() {
        let state = Privacy.State(reason: .untilLater, until: noon.addingTimeInterval(47 * 60))
        let banner = PrivacyCopy.banner(for: state, at: noon)
        #expect(banner.isPaused)
        #expect(banner.detail.contains("47 minutes"))
    }

    // El motivo "compartiendo pantalla" ya no lo pone nadie: macOS no dice si alguien está
    // capturando la pantalla, así que la promesa se quitó en vez de fingirla. Lo que queda es una
    // base de datos de una versión anterior que sí puede tener ese motivo guardado, y de esa
    // pausa hay que poder salir: antes el cartel no traía botón porque la app iba a reanudar sola.
    @Test("de toda pausa se puede salir, incluida la que dejó una versión anterior")
    func deTodaPausaSeSale() {
        let paused = [Privacy.State(reason: .byHand),
                      Privacy.State(reason: .untilLater, until: noon.addingTimeInterval(600))]
        for state in paused {
            let banner = PrivacyCopy.banner(for: state, at: noon)
            #expect(banner.isPaused, "\(state.reason) debería contar como pausa")
            #expect(!banner.resumeTitle.isEmpty, "\(state.reason) deja al usuario sin salida")
        }
    }

    @Test("el tiempo restante se escribe en singular cuando queda un minuto")
    func restanteSingular() {
        #expect(PrivacyCopy.remaining(until: noon.addingTimeInterval(80), at: noon) == "1 minute")
        #expect(PrivacyCopy.remaining(until: noon.addingTimeInterval(30), at: noon)
                == "less than a minute")
        #expect(PrivacyCopy.remaining(until: noon.addingTimeInterval(3600), at: noon) == "1 hour")
        #expect(PrivacyCopy.remaining(until: noon.addingTimeInterval(3900), at: noon)
                == "1 hour and 5 minutes")
        // El singular y el plural se arman por trozos, así que hay que comprobarlos en los dos
        // idiomas: un plural mal enganchado solo se ve en el que no se probó.
        #expect(Loc.render("1 minute", in: .spanish) == "1 minuto")
        #expect(Loc.render("%1$@ and %2$@", in: .spanish,
                           [Loc.render("1 hour", in: .spanish),
                            Loc.render("%@ minutes", in: .spanish, ["5"])])
                == "1 hora y 5 minutos")
    }

    // MARK: - Que se vea desde fuera del panel

    @Test("la barra de menús no dice nada mientras está capturando")
    func barraCallada() {
        #expect(PrivacyCopy.menuBarTitle(for: Privacy.State(), at: noon) == nil)
    }

    @Test("la barra de menús avisa de la pausa aunque el panel esté cerrado")
    func barraAvisa() {
        #expect(PrivacyCopy.menuBarTitle(for: Privacy.State(reason: .byHand), at: noon)
                == "Paused")
        let timed = Privacy.State(reason: .untilLater, until: noon.addingTimeInterval(14 * 60))
        #expect(PrivacyCopy.menuBarTitle(for: timed, at: noon) == "Paused · 14 min")
    }

    @Test("cuando la pausa vence, la barra deja de avisar sola")
    func barraSeCalla() {
        let expired = Privacy.State(reason: .untilLater, until: noon.addingTimeInterval(-60))
        #expect(PrivacyCopy.menuBarTitle(for: expired, at: noon) == nil)
    }

    @Test("«hasta mañana» pausado de noche no se reanuda una hora después")
    func hastaMañana() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .gmt
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 10
        components.hour = 23; components.minute = 0
        let lateNight = try #require(calendar.date(from: components))

        let until = try #require(PrivacyCopy.PauseChoice.tomorrow.until(from: lateNight,
                                                                       calendar: calendar))
        #expect(until.timeIntervalSince(lateNight) > 8 * 3600)
        #expect(calendar.component(.day, from: until) == 11)
        #expect(calendar.component(.hour, from: until) == 8)
    }

    @Test("una pausa sin hora se guarda como estado, no como temporizador larguísimo")
    func pausaSinHora() {
        #expect(PrivacyCopy.PauseChoice.untilIResume.until(from: noon) == nil)
        #expect(PrivacyCopy.PauseChoice.untilIResume.reason == .byHand)
        #expect(PrivacyCopy.PauseChoice.hour.reason == .untilLater)
    }

    // MARK: - Excluir

    @Test("un dominio pegado del navegador se recorta a lo que de verdad se compara")
    func dominioNormalizado() {
        #expect(PrivacyCopy.normalisedDomain("https://www.Banco.com/login?x=1") == "banco.com")
        #expect(PrivacyCopy.normalisedDomain("  BBVA.es  ") == "bbva.es")
        #expect(PrivacyCopy.normalisedDomain("") == nil)
    }

    @Test("un dominio con espacios se rechaza diciendo cómo se escribe")
    func dominioConEspacios() throws {
        let problem = try #require(PrivacyCopy.problem(withDomain: "mi banco"))
        // El ejemplo del mensaje tiene que ser el mismo que el del campo: dos dominios distintos
        // en la misma pantalla hacen dudar de cuál es el que vale.
        #expect(problem.contains(PrivacyCopy.addDomainPlaceholder))
        #expect(PrivacyCopy.problem(withDomain: "banco.com") == nil)
        #expect(PrivacyCopy.problem(withDomain: "") == nil)
    }

    @Test("las apps de fábrica se enseñan con nombre de persona, no de identificador")
    func nombresLegibles() {
        #expect(PrivacyCopy.appName("com.1password.1password") == "1Password")
        #expect(PrivacyCopy.appName("com.apple.keychainaccess") == "Keychain Access")
        #expect(PrivacyCopy.appName("com.acme.SecretThing") == "SecretThing")
        #expect(PrivacyCopy.appName("notion") == "Notion")
    }

    @Test("todas las exclusiones de fábrica tienen algo que enseñar")
    func fábricaCompleta() {
        for identifier in Privacy.excludedByDefault {
            #expect(!PrivacyCopy.appName(identifier).isEmpty)
        }
    }

    // MARK: - Olvidar

    @Test("no se puede confirmar un olvido cuando no hay nada en ese rato")
    func olvidoVacío() {
        let confirmation = PrivacyCopy.confirmation(
            period: "La última hora",
            forgetting: Privacy.Forgetting(passages: 0, clips: 0, nodes: 0)
        )
        #expect(!confirmation.canProceed)
        #expect(confirmation.confirmTitle.isEmpty)
    }

    @Test("la confirmación dice cuánto se borra y cancelar es la respuesta por defecto")
    func olvidoConfirmado() {
        let forgetting = Privacy.Forgetting(passages: 8, clips: 3, nodes: 1)
        let confirmation = PrivacyCopy.confirmation(period: "Hoy", forgetting: forgetting)
        #expect(confirmation.canProceed)
        #expect(confirmation.cancelIsDefault)
        #expect(confirmation.confirmTitle == "Forget 12 things")
        #expect(confirmation.message.contains("cannot be undone"))
        #expect(confirmation.message.contains("for good"))
    }

    @Test("una sola cosa no se anuncia en plural")
    func olvidoSingular() {
        let one = Privacy.Forgetting(passages: 1, clips: 0, nodes: 0)
        #expect(PrivacyCopy.confirmation(period: "Today", forgetting: one).confirmTitle
                == "Forget 1 thing")
        #expect(Loc.render("Forget 1 thing", in: .spanish) == "Olvidar 1 cosa")
    }

    @Test("un olvido incompleto se dice, no se da por hecho")
    func olvidoIncompleto() {
        let text = PrivacyCopy.forgetFailed(left: 4)
        #expect(text.contains("4"))
        #expect(text.contains("repeat"))
    }

    @Test("cada rato que se puede olvidar sabe qué periodo cubre, salvo el que se elige a mano")
    func periodos() throws {
        for choice in PrivacyCopy.ForgetChoice.allCases where choice != .range {
            let period = try #require(choice.period(now: noon))
            #expect(period.from <= period.to)
        }
        #expect(PrivacyCopy.ForgetChoice.range.period(now: noon) == nil)
    }

    @Test("el desglose de lo que se borra se lee sin saber cómo guardamos las cosas")
    func desglose() {
        let text = PrivacyCopy.breakdown(Privacy.Forgetting(passages: 8, clips: 3, nodes: 1))
        #expect(text.contains("8 fragments"))
        #expect(text.contains("3 clipboard copies"))
        #expect(text.contains("1 thing you were working on"))
        #expect(!text.contains("graph"))
        #expect(!text.contains("(s)"))
        #expect(PrivacyCopy.breakdown(Privacy.Forgetting(passages: 0, clips: 0, nodes: 0))
                == "Nothing was saved in that stretch.")
    }

    // MARK: - Estado del cerebro

    @Test("el cerebro vacío lo dice en vez de enseñar ceros sin explicar")
    func cerebroVacío() {
        #expect(!PrivacyCopy.Brain.emptyHeadline.isEmpty)
        #expect(PrivacyCopy.Brain.emptyDetail.contains("shows up here"))
    }

    @Test("las cifras del cerebro se cuentan todas y ninguna se queda sin explicar")
    func tarjetasDelCerebro() {
        let cards = PrivacyCopy.Brain.cards(passages: 1_240, vectorised: 900, episodes: 12,
                                            entities: 41, clips: 300)
        #expect(cards.count == 5)
        #expect(cards[0].value == "1,240")
        #expect(cards.allSatisfy { !$0.hint.isEmpty })
        #expect(Set(cards.map(\.id)).count == cards.count)
    }

    @Test("una cifra de uno no se dice en plural")
    func tarjetaSingular() {
        let cards = PrivacyCopy.Brain.cards(passages: 1, vectorised: 1, episodes: 1,
                                            entities: 1, clips: 1)
        #expect(cards[0].label == "fragment")
        #expect(cards[2].label == "stretch of work")
        #expect(cards[4].label == "saved copy")
    }

    @Test("el error del cerebro dice qué pasó y qué hacer")
    func errorDelCerebro() {
        let text = PrivacyCopy.Brain.failed("la base de datos está ocupada")
        #expect(text.contains("la base de datos está ocupada"))
        #expect(text.contains("Refresh"))
    }

    // MARK: - Cómo se habla

    /// The rule that is easiest to break by accident: one hurried label saying "vectorizado" and
    /// the panel stops being for the person who has to trust it.
    @Test("ningún texto visible usa jerga de máquina")
    func sinJerga() {
        let forbidden = ["vector", "embedding", "índice semántico", "semantic index", "chunk",
                         "token", "sqlite", "query", "hash"]
        for text in allVisibleCopy() {
            for word in forbidden {
                #expect(!text.lowercased().contains(word),
                        "«\(word)» aparece en: \(text)")
            }
        }
    }

    @Test("ningún texto visible usa raya larga")
    func sinRayaLarga() {
        for text in allVisibleCopy() {
            #expect(!text.contains("—"), "raya larga en: \(text)")
        }
    }

    private func allVisibleCopy() -> [String] {
        var texts: [String] = [
            PrivacyCopy.pauseTitle, PrivacyCopy.pauseExplanation, PrivacyCopy.resumeExplanation,
            PrivacyCopy.exclusionsTitle, PrivacyCopy.exclusionsExplanation,
            PrivacyCopy.defaultsExplanation, PrivacyCopy.defaultsKept,
            PrivacyCopy.appsEmpty, PrivacyCopy.domainsEmpty,
            PrivacyCopy.addAppPlaceholder, PrivacyCopy.addDomainPlaceholder,
            PrivacyCopy.forgetTitle, PrivacyCopy.forgetExplanation, PrivacyCopy.counting,
            PrivacyCopy.rangeStart, PrivacyCopy.rangeEnd, PrivacyCopy.rangeBackwards,
            PrivacyCopy.forgetFailed(left: 2),
            PrivacyCopy.Brain.emptyHeadline, PrivacyCopy.Brain.emptyDetail,
            PrivacyCopy.Brain.counting, PrivacyCopy.Brain.localLine, PrivacyCopy.Brain.remoteLine,
            PrivacyCopy.Brain.failed("algo"),
        ]
        texts += PrivacyCopy.PauseChoice.allCases.map(\.label)
        texts += PrivacyCopy.ForgetChoice.allCases.map(\.label)
        for card in PrivacyCopy.Brain.cards(passages: 3, vectorised: 2, episodes: 1,
                                            entities: 5, clips: 9) {
            texts += [card.label, card.hint]
        }
        for state in [Privacy.State(), Privacy.State(reason: .byHand),
                      Privacy.State(reason: .untilLater, until: noon.addingTimeInterval(600))] {
            let banner = PrivacyCopy.banner(for: state, at: noon)
            texts += [banner.headline, banner.detail, banner.resumeTitle]
        }
        let confirmation = PrivacyCopy.confirmation(
            period: "Hoy", forgetting: Privacy.Forgetting(passages: 2, clips: 1, nodes: 0))
        texts += [confirmation.title, confirmation.message,
                  confirmation.confirmTitle, confirmation.cancelTitle]
        return texts
    }
}
