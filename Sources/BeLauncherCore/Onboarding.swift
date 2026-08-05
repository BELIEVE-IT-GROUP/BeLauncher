import Foundation

/// What the app needs, why, and what it does with it — said once, up front, in one place.
///
/// "Just in time" permissions sounded principled and were unusable: the app never told anyone what
/// it could do, so nobody ever hit the moment that would have asked. The person who bought a
/// launcher to move faster ended up with a launcher that quietly did less, and no way to find out
/// why. Explaining everything at the start and letting the person switch each one on is not more
/// intrusive — it is the version where they are actually deciding.
public enum Onboarding {

    public struct Capability: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case accessibility
            case calendar
            case notifications
            case clipboard
            case updates
            case launchAtLogin
        }

        public let id: String
        public let kind: Kind
        public let title: String
        /// What the person gets. Never the name of the API.
        public let unlocks: String
        /// What is actually accessed, in plain words.
        public let accesses: String
        /// What still works if they say no.
        public let ifYouSayNo: String
        public let symbol: String
        /// Whether macOS itself will ask. The rest are just our own settings.
        public let isSystemPermission: Bool
        /// Recommended on, because the app is noticeably worse without it.
        public let recommended: Bool

        public init(kind: Kind, title: String, unlocks: String, accesses: String,
                    ifYouSayNo: String, symbol: String, isSystemPermission: Bool,
                    recommended: Bool) {
            self.id = kind.rawValue
            self.kind = kind
            self.title = title
            self.unlocks = unlocks
            self.accesses = accesses
            self.ifYouSayNo = ifYouSayNo
            self.symbol = symbol
            self.isSystemPermission = isSystemPermission
            self.recommended = recommended
        }
    }

    public static let capabilities: [Capability] = [
        .init(kind: .clipboard,
              title: "Historial del portapapeles",
              unlocks: "Recuperas cualquier cosa que copiaste, con ⌥C. Textos, imágenes y archivos.",
              accesses: "Lo que copias, guardado en tu Mac. Nunca lo que copias desde un gestor de "
                      + "contraseñas, ni nada con forma de clave o token: eso se descarta antes de "
                      + "escribirse.",
              ifYouSayNo: "El lanzador, los snippets y todo lo demás siguen igual. Solo pierdes el historial.",
              symbol: "doc.on.clipboard", isSystemPermission: false, recommended: true),

        .init(kind: .accessibility,
              title: "Accesibilidad",
              unlocks: "Pegar directamente en la app donde estabas, y colocar ventanas (mitad "
                     + "izquierda, pantalla completa, entre dos monitores).",
              accesses: "macOS solo deja pulsar ⌘V en otra app o mover su ventana con este permiso. "
                      + "BeLauncher no lo usa para nada más: no lee tu pantalla, ni tus pulsaciones, "
                      + "ni el contenido de otras apps.",
              ifYouSayNo: "Copias con Enter y pegas tú con ⌘V. La gestión de ventanas no funciona.",
              symbol: "accessibility", isSystemPermission: true, recommended: true),

        .init(kind: .calendar,
              title: "Calendario",
              unlocks: "«Prepárame para la reunión con Acme» reúne lo que sabes de ellos y lo cruza "
                     + "con lo que tienes agendado hoy.",
              accesses: "Solo los títulos y horas de tus eventos, leídos en el momento y nunca "
                      + "guardados ni enviados a ningún sitio.",
              ifYouSayNo: "Preparar una reunión sigue funcionando, pero tienes que escribir tú con "
                        + "quién es.",
              symbol: "calendar", isSystemPermission: true, recommended: false),

        .init(kind: .notifications,
              title: "Notificaciones",
              unlocks: "Los temporizadores de los flujos te avisan cuando terminan. Sin esto, un "
                     + "bloque de enfoque de 50 minutos acaba en silencio.",
              accesses: "Nada. Solo permite mostrar un aviso.",
              ifYouSayNo: "Los flujos funcionan; los temporizadores no avisan.",
              symbol: "bell", isSystemPermission: true, recommended: false),

        .init(kind: .launchAtLogin,
              title: "Abrir al iniciar sesión",
              unlocks: "El atajo global funciona desde que enciendes el Mac, sin abrir nada.",
              accesses: "Nada. Es un ajuste de macOS.",
              ifYouSayNo: "Tendrás que abrir BeLauncher a mano cada día.",
              symbol: "power", isSystemPermission: false, recommended: true),

        .init(kind: .updates,
              title: "Buscar actualizaciones",
              unlocks: "Te avisa en la barra de menús cuando hay versión nueva y la instala con un "
                     + "botón.",
              accesses: "Una petición a nuestro servidor de descargas para leer un número de "
                      + "versión. No lleva quién eres, ni qué usas, ni nada de tu Mac.",
              ifYouSayNo: "Nunca toca la red. Te enteras de las versiones nuevas por donde tú quieras.",
              symbol: "arrow.down.circle", isSystemPermission: false, recommended: true),
    ]

    /// The promise, stated where the person is deciding — not buried in a privacy policy.
    public static let privacy = """
        BeLauncher no tiene cuenta, ni analítica, ni telemetría, ni servidor donde vivan tus datos.

        Lo que escribes, lo que copias y lo que guardas en tu cerebro se quedan en este Mac, en una \
        base de datos y una carpeta de archivos Markdown que puedes abrir, copiar o borrar tú mismo.

        Solo salen tres cosas a la red, y las tres las decides tú: la activación de la licencia (una \
        vez), buscar si hay versión nueva, y las peticiones de IA si eliges un modelo en la nube. \
        Esas van de tu Mac directas al proveedor con tu clave: no pasan por nosotros.

        Con un modelo local (Ollama, LM Studio) ni eso.
        """

    /// The five things worth knowing on day one. Not fifty shortcuts: five.
    public static let firstThings: [(keys: String, does: String)] = [
        ("⇧⌘Espacio", "Abre BeLauncher. Escribe y empieza a buscar apps, archivos y todo lo demás."),
        ("⌥C", "Tu historial del portapapeles."),
        ("↩", "Hace lo obvio con lo que tengas seleccionado: abrir la app, copiar el resultado."),
        ("⌘K", "Todo lo demás que puedes hacer con eso: revelar en Finder, pedirle algo a la IA, "
             + "ponerle un alias."),
        ("Tab", "Completa lo que estás escribiendo."),
    ]

    /// Five things to try, in the order that makes the product click.
    public static let tryThis: [(type: String, andSee: String)] = [
        ("2+2*10", "Calcula mientras escribes. Enter copia el resultado."),
        ("10 km to mi", "Convierte unidades, monedas y zonas horarias igual."),
        ("f informe", "Busca archivos por nombre en todo tu Mac."),
        ("enfoque", "Una misión: silencia, y arranca un bloque de 50 minutos. Te enseña el plan "
                  + "antes de hacer nada."),
        ("recordar que subimos el precio a 90", "Propone guardarlo en tu cerebro. Tú confirmas."),
    ]
}
