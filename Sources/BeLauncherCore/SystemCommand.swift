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
        /// Opens the brain. Not a system action, but it belongs in the same list: it is a thing
        /// you type a word for and a window appears, which is what this list is.
        case openBrain
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
        /// Opens the Desktop *folder*, which is not the same as `showDesktop` hiding the windows.
        case openDesktop
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
        .init(id: "brain", title: L("Your brain"),
              keywords: ["cerebro", "brain", "grafo", "graph", "memoria", "memory"],
              symbol: "brain", kind: .openBrain),
        .init(id: "lock", title: L("Lock the screen"), keywords: ["lock", "bloquear", "candado"],
              symbol: "lock.fill", kind: .lockScreen),
        .init(id: "sleep-display", title: L("Turn the display off"), keywords: ["display", "pantalla", "apagar"],
              symbol: "display", kind: .sleepDisplay),
        .init(id: "sleep", title: L("Put the Mac to sleep"), keywords: ["sleep", "suspender", "dormir"],
              symbol: "powersleep", kind: .sleepMac),
        .init(id: "screensaver", title: L("Screen saver"), keywords: ["screensaver", "salvapantallas"],
              symbol: "sparkles.tv", kind: .screenSaver),
        .init(id: "dark-mode", title: L("Switch light or dark mode"), keywords: ["dark", "oscuro", "claro", "tema"],
              symbol: "circle.lefthalf.filled", kind: .toggleDarkMode),
        .init(id: "dnd", title: L("Focus: do not disturb"), keywords: ["dnd", "molestar", "focus", "silencio"],
              symbol: "moon.fill", kind: .toggleDoNotDisturb),
        .init(id: "empty-trash", title: L("Empty the Trash"), keywords: ["trash", "papelera", "vaciar"],
              symbol: "trash", kind: .emptyTrash),
        .init(id: "open-trash", title: L("Open the Trash"), keywords: ["trash", "papelera"],
              symbol: "trash.circle", kind: .openTrash),
        .init(id: "downloads", title: L("Open Downloads"), keywords: ["downloads", "descargas"],
              symbol: "arrow.down.circle", kind: .openDownloads),
        .init(id: "desktop-folder", title: L("Open the Desktop folder"),
              keywords: ["escritorio", "desktop folder", "carpeta escritorio"],
              symbol: "menubar.dock.rectangle", kind: .openDesktop),
        .init(id: "home", title: L("Open your home folder"), keywords: ["home", "personal", "casa"],
              symbol: "house", kind: .openHome),
        .init(id: "desktop", title: L("Show the desktop"), keywords: ["desktop", "escritorio"],
              symbol: "macwindow.on.rectangle", kind: .showDesktop),
        .init(id: "mute", title: L("Mute the sound"), keywords: ["mute", "silenciar", "volumen"],
              symbol: "speaker.slash", kind: .volumeMute),
        .init(id: "wifi", title: L("Turn Wi-Fi on or off"), keywords: ["wifi", "red"],
              symbol: "wifi", kind: .toggleWiFi),
        .init(id: "bluetooth", title: L("Turn Bluetooth on or off"), keywords: ["bluetooth"],
              symbol: "antenna.radiowaves.left.and.right", kind: .toggleBluetooth),
        .init(id: "eject", title: L("Eject disks"), keywords: ["eject", "expulsar", "disco"],
              symbol: "eject", kind: .ejectDisks),
        .init(id: "logout", title: L("Log out"), keywords: ["logout", "cerrar sesión"],
              symbol: "rectangle.portrait.and.arrow.right", kind: .logOut),
        .init(id: "restart", title: L("Restart the Mac"), keywords: ["restart", "reiniciar"],
              symbol: "arrow.clockwise", kind: .restart),
        .init(id: "shutdown", title: L("Shut the Mac down"), keywords: ["shutdown", "apagar"],
              symbol: "power", kind: .shutDown),
        .init(id: "relaunch", title: L("Restart BeLauncher"), keywords: ["relaunch", "reiniciar belauncher"],
              symbol: "arrow.triangle.2.circlepath", kind: .restartBeLauncher),
        .init(id: "quit", title: L("Quit BeLauncher"), keywords: ["quit", "salir"],
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
