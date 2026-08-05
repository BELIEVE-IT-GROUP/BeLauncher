import Foundation

/// The system commands every launcher is expected to have. A closed catalogue: each one maps to
/// a specific capability the app implements, never to a shell string the user could edit.
public struct SystemCommand: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let keywords: [String]
    public let symbol: String
    public let kind: Kind

    public enum Kind: String, Sendable, Equatable {
        case lockScreen
        case sleepDisplay
        case sleepMac
        case emptyTrash
        case toggleDarkMode
        case toggleDoNotDisturb
        case showDesktop
        case screenSaver
        case logOut
        case restart
        case shutDown
        case toggleWiFi
        case toggleBluetooth
        case volumeMute
        case ejectDisks
        case openTrash
        case openDownloads
        case openHome
        case restartBeLauncher
        case quitBeLauncher
    }

    /// Commands that end a session or power down are confirmed before running.
    public var needsConfirmation: Bool {
        switch kind {
        // Ejecting every mounted disk can interrupt a copy in progress, so it asks too.
        case .logOut, .restart, .shutDown, .emptyTrash, .ejectDisks: true
        default: false
        }
    }

    public init(id: String, title: String, keywords: [String], symbol: String, kind: Kind) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.symbol = symbol
        self.kind = kind
    }

    public static let all: [SystemCommand] = [
        .init(id: "lock", title: "Bloquear pantalla", keywords: ["lock", "bloquear", "candado"],
              symbol: "lock.fill", kind: .lockScreen),
        .init(id: "sleep-display", title: "Apagar la pantalla", keywords: ["display", "pantalla", "apagar"],
              symbol: "display", kind: .sleepDisplay),
        .init(id: "sleep", title: "Suspender el Mac", keywords: ["sleep", "suspender", "dormir"],
              symbol: "powersleep", kind: .sleepMac),
        .init(id: "screensaver", title: "Salvapantallas", keywords: ["screensaver", "salvapantallas"],
              symbol: "sparkles.tv", kind: .screenSaver),
        .init(id: "dark-mode", title: "Cambiar modo claro/oscuro", keywords: ["dark", "oscuro", "claro", "tema"],
              symbol: "circle.lefthalf.filled", kind: .toggleDarkMode),
        .init(id: "dnd", title: "Concentración: no molestar", keywords: ["dnd", "molestar", "focus", "silencio"],
              symbol: "moon.fill", kind: .toggleDoNotDisturb),
        .init(id: "empty-trash", title: "Vaciar la papelera", keywords: ["trash", "papelera", "vaciar"],
              symbol: "trash", kind: .emptyTrash),
        .init(id: "open-trash", title: "Abrir la papelera", keywords: ["trash", "papelera"],
              symbol: "trash.circle", kind: .openTrash),
        .init(id: "downloads", title: "Abrir Descargas", keywords: ["downloads", "descargas"],
              symbol: "arrow.down.circle", kind: .openDownloads),
        .init(id: "home", title: "Abrir carpeta personal", keywords: ["home", "personal", "casa"],
              symbol: "house", kind: .openHome),
        .init(id: "desktop", title: "Mostrar el escritorio", keywords: ["desktop", "escritorio"],
              symbol: "macwindow.on.rectangle", kind: .showDesktop),
        .init(id: "mute", title: "Silenciar el sonido", keywords: ["mute", "silenciar", "volumen"],
              symbol: "speaker.slash", kind: .volumeMute),
        .init(id: "wifi", title: "Activar o desactivar el wifi", keywords: ["wifi", "red"],
              symbol: "wifi", kind: .toggleWiFi),
        .init(id: "bluetooth", title: "Activar o desactivar Bluetooth", keywords: ["bluetooth"],
              symbol: "antenna.radiowaves.left.and.right", kind: .toggleBluetooth),
        .init(id: "eject", title: "Expulsar discos", keywords: ["eject", "expulsar", "disco"],
              symbol: "eject", kind: .ejectDisks),
        .init(id: "logout", title: "Cerrar sesión", keywords: ["logout", "cerrar sesión"],
              symbol: "rectangle.portrait.and.arrow.right", kind: .logOut),
        .init(id: "restart", title: "Reiniciar el Mac", keywords: ["restart", "reiniciar"],
              symbol: "arrow.clockwise", kind: .restart),
        .init(id: "shutdown", title: "Apagar el Mac", keywords: ["shutdown", "apagar"],
              symbol: "power", kind: .shutDown),
        .init(id: "relaunch", title: "Reiniciar BeLauncher", keywords: ["relaunch", "reiniciar belauncher"],
              symbol: "arrow.triangle.2.circlepath", kind: .restartBeLauncher),
        .init(id: "quit", title: "Salir de BeLauncher", keywords: ["quit", "salir"],
              symbol: "xmark.circle", kind: .quitBeLauncher),
    ]

    /// Matches the title and every keyword, so "papelera" and "trash" both find the same command.
    public static func search(_ query: String) -> [(command: SystemCommand, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        return all.compactMap { command in
            let candidates = [command.title] + command.keywords
            guard let best = candidates.compactMap({ Fuzzy.match(query: trimmed, candidate: $0) })
                .max(by: { $0.score < $1.score }) else { return nil }
            return (command, best.score)
        }
        .sorted { $0.score > $1.score }
    }
}
