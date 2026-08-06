import Foundation

/// Where everything was, so you can put it back.
///
/// Arranging one window is a keystroke. Arranging *the set* — editor left, terminal bottom right,
/// browser on the second display, chat on the laptop screen — is two minutes of dragging, and you
/// do it again every time you undock, every time a call takes over the screen, every time you
/// switch from writing to reviewing. That is the job a separate app usually gets bought for.
///
/// A workspace is a named snapshot: which app, which window, where, how big, on which display.
/// Restoring is the same list read backwards.
public struct Workspace: Sendable, Equatable, Identifiable, Codable {

    /// One window, remembered by what it belongs to rather than by a process id.
    ///
    /// A pid is meaningless tomorrow. The bundle identifier plus the window title survives a
    /// restart, an app update and a machine, which is the difference between a snapshot and a
    /// souvenir.
    public struct Placement: Sendable, Equatable, Codable, Identifiable {
        public var id: String { bundleIdentifier + "·" + windowTitle }
        public let bundleIdentifier: String
        public let applicationName: String
        /// Empty when the app has one window and the title is noise.
        public let windowTitle: String
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        /// Which screen it was on, by its arrangement index.
        public let display: Int

        public init(bundleIdentifier: String, applicationName: String, windowTitle: String = "",
                    x: Double, y: Double, width: Double, height: Double, display: Int = 0) {
            self.bundleIdentifier = bundleIdentifier
            self.applicationName = applicationName
            self.windowTitle = windowTitle
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.display = display
        }
    }

    public var id: String { name.lowercased() }
    public let name: String
    public let placements: [Placement]
    /// How many screens were connected. Restoring onto a different number needs saying so.
    public let displays: Int
    public let savedAt: Date

    public init(name: String, placements: [Placement], displays: Int, savedAt: Date = .now) {
        self.name = name
        self.placements = placements
        self.displays = displays
        self.savedAt = savedAt
    }

    public var summary: String {
        let apps = Set(placements.map(\.applicationName)).sorted()
        return apps.prefix(4).joined(separator: ", ")
            + (apps.count > 4 ? " y \(apps.count - 4) más" : "")
    }
}

public enum WorkspaceLayouts {

    /// What can be restored here and now, and what has to be said out loud first.
    public enum Fit: Sendable, Equatable {
        case exact
        /// Fewer screens than when it was saved: windows off the edge get pulled back.
        case fewerDisplays(saved: Int, now: Int)
        /// Some of the apps are not running.
        case missingApps([String])

        public var warning: String? {
            switch self {
            case .exact:
                nil
            case .fewerDisplays(let saved, let now):
                "Se guardó con \(saved) pantallas y ahora hay \(now). Lo que quedaba fuera se "
                + "traerá a la que tienes."
            case .missingApps(let names):
                "No están abiertas: \(names.joined(separator: ", ")). El resto sí se coloca."
            }
        }
    }

    /// Checks a workspace against the machine as it is now, without moving anything.
    ///
    /// Said before restoring rather than discovered afterwards: someone who undocked a laptop and
    /// restores a two-screen layout should be told, not left hunting for a window that went to a
    /// display that is not there.
    public static func fit(_ workspace: Workspace, displays: Int,
                           runningBundles: Set<String>) -> Fit {
        let missing = workspace.placements
            .filter { !runningBundles.contains($0.bundleIdentifier) }
            .map(\.applicationName)
        if !missing.isEmpty { return .missingApps(Array(Set(missing)).sorted()) }
        if displays < workspace.displays {
            return .fewerDisplays(saved: workspace.displays, now: displays)
        }
        return .exact
    }

    /// Windows not worth remembering.
    ///
    /// Chrome reports three windows and two are strips 41 pixels tall; every app has panels,
    /// palettes and inspectors. A snapshot full of those restores a mess and hides the two
    /// windows that mattered.
    public static let minimumSide: Double = 200

    public static func isWorthSaving(width: Double, height: Double) -> Bool {
        width >= minimumSide && height >= minimumSide
    }

    /// The desktop pretending to be a window.
    ///
    /// The Finder reports one that spans every display at once — 10720×2160 on a three-screen
    /// Mac. Saving it means a "workspace" that includes the desktop, and restoring it means
    /// trying to move something that is not a window anyone arranged.
    public static func spansEverything(width: Double, widestScreen: Double) -> Bool {
        width > widestScreen * 1.2
    }

    /// Pulls a window back onto a screen that exists.
    public static func clamp(_ placement: Workspace.Placement,
                             into visible: WindowLayoutMath.Frame) -> Workspace.Placement {
        let width = min(placement.width, visible.width)
        let height = min(placement.height, visible.height)
        let x = min(max(placement.x, visible.x), visible.x + visible.width - width)
        let y = min(max(placement.y, visible.y), visible.y + visible.height - height)
        return Workspace.Placement(
            bundleIdentifier: placement.bundleIdentifier,
            applicationName: placement.applicationName, windowTitle: placement.windowTitle,
            x: x, y: y, width: width, height: height, display: 0
        )
    }

    // MARK: - Typing it

    public enum Intent: Sendable, Equatable {
        case save(String)
        case restore(String)
        case list

        public static func detect(_ query: String) -> Intent? {
            let folded = query
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespaces)
            guard folded.count >= 4 else { return nil }

            for prefix in ["guardar espacio ", "guardar layout ", "guardar ventanas ",
                           "save workspace "] where folded.hasPrefix(prefix) {
                let name = String(folded.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : .save(name)
            }
            for prefix in ["espacio ", "layout ", "restaurar ", "workspace "] where folded.hasPrefix(prefix) {
                let name = String(folded.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : .restore(name)
            }
            for word in ["espacios", "layouts", "workspaces"] where folded == word {
                return .list
            }
            return nil
        }
    }
}

// MARK: - Storage

extension Store {

    public func saveWorkspace(_ workspace: Workspace) throws {
        let data = try JSONEncoder().encode(workspace)
        setSetting("workspace_\(workspace.id)", String(decoding: data, as: UTF8.self))
    }

    public func workspaces() -> [Workspace] {
        let rows = (try? database.query(
            "SELECT value FROM settings WHERE key LIKE 'workspace_%' ORDER BY key")) ?? []
        return rows.compactMap { row in
            try? JSONDecoder().decode(Workspace.self, from: Data(row.string("value").utf8))
        }
    }

    public func workspace(named name: String) -> Workspace? {
        workspaces().first { $0.id == name.lowercased() }
    }

    public func deleteWorkspace(named name: String) {
        setSetting("workspace_\(name.lowercased())", "")
        try? database.execute("DELETE FROM settings WHERE key = ?",
                              [.text("workspace_\(name.lowercased())")])
    }
}
