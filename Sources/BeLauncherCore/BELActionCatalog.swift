import Foundation

/// The stable catalogue shared by the launcher, Brain and future App Intents.
///
/// This is deliberately smaller than the v2 proposal's full seed list for now. An entry is only
/// marked implemented when today's runtime has a real path for it; the remaining proposal IDs can
/// be added as unavailable seeds without making the UI promise work that does not exist yet.
public enum BELActionCatalog {

    public enum ValidationIssue: Equatable, Sendable {
        case duplicateID(String)
        case emptyID
        case invalidNamespace(String)
        case emptyTitleKey(String)
        case missingAlias(String)
        case implementedWithoutAdapter(String)
    }

    /// The definitions that have a corresponding runtime today. The legacy registries remain the
    /// execution layer until N1 migrates them behind a handler protocol.
    public static var all: [BELActionDefinition] {
        nativeSystem + nativeFiles + nativeShortcuts + aiVerbs
    }

    public static func named(_ id: String) -> BELActionDefinition? {
        all.first { $0.id == id }
    }

    /// Legacy bridge used by N1 adapters while SystemCommand is being migrated.
    public static func systemCommandKind(for id: String) -> String? {
        guard let command = SystemCommand.all.first(where: { nativeID(for: $0.kind) == id })
        else { return nil }
        return command.kind.rawValue
    }

    /// Converts a stable AI action ID back to the legacy verb ID while the runner is being migrated.
    public static func legacyAIVerbID(for id: String) -> String? {
        guard id.hasPrefix("ai.verb.") else { return nil }
        let legacy = String(id.dropFirst("ai.verb.".count))
        return AIVerb.named(legacy)?.id
    }

    /// A cheap invariant gate for CI and for the future seed file. It checks contract integrity,
    /// not whether a provider or TCC permission happens to be available on this Mac.
    public static func validate(_ definitions: [BELActionDefinition] = all) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var ids = Set<String>()
        for definition in definitions {
            if definition.id.isEmpty { issues.append(.emptyID) }
            if !ids.insert(definition.id).inserted { issues.append(.duplicateID(definition.id)) }
            if !definition.id.contains(".") {
                issues.append(.invalidNamespace(definition.id))
            }
            if definition.titleKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyTitleKey(definition.id))
            }
            if definition.aliases.isEmpty { issues.append(.missingAlias(definition.id)) }
            if definition.availability == .implemented, definition.adapter == .none {
                issues.append(.implementedWithoutAdapter(definition.id))
            }
        }
        return issues
    }

    private static var nativeSystem: [BELActionDefinition] {
        SystemCommand.all.map { command in
            BELActionDefinition(
                id: nativeID(for: command.kind),
                kind: .native,
                titleKey: "native.system.\(command.kind.rawValue)",
                aliases: command.keywords + [command.id],
                output: .text,
                requiredCapabilities: command.needsConfirmation ? [.accessibility] : [],
                risk: command.needsConfirmation ? .r3 : .r0,
                routePolicy: .deterministic,
                adapter: .allowlistedShell,
                availability: .implemented)
        }
    }

    private static var aiVerbs: [BELActionDefinition] {
        AIVerb.all.map { verb in
            let risk: BELActionDefinition.Risk = verb.id == "extract-tasks" ? .r1 : .r0
            let route: BELActionDefinition.RoutePolicy = verb.sensitivity == .confidential
                ? .localOnly : .localFirst
            return BELActionDefinition(
                id: "ai.verb.\(verb.id)",
                kind: .ai,
                titleKey: "ai.verb.\(verb.id)",
                aliases: verb.triggers + [verb.id, verb.title],
                arguments: [.init("text", .text)],
                output: .text,
                brainContextLevel: .b0,
                risk: risk,
                routePolicy: route,
                adapter: .model,
                availability: .implemented)
        }
    }

    private static var nativeFiles: [BELActionDefinition] {
        [
            BELActionDefinition(id: "files.open", kind: .native,
                                titleKey: "Open file", aliases: ["open file", L("Open file")],
                                arguments: [.init("path", .path)], output: .path,
                                requiredCapabilities: [.files], risk: .r0,
                                routePolicy: .deterministic, adapter: .publicAPI,
                                availability: .implemented),
            BELActionDefinition(id: "files.reveal", kind: .native,
                                titleKey: "Show in Finder",
                                aliases: ["reveal file", L("Show file"), "reveal"],
                                arguments: [.init("path", .path)], output: .path,
                                requiredCapabilities: [.files], risk: .r0,
                                routePolicy: .deterministic, adapter: .publicAPI,
                                availability: .implemented),
            BELActionDefinition(id: "files.move_to_trash", kind: .native,
                                titleKey: "Move file to Trash",
                                aliases: ["trash file", L("Move file to the trash")],
                                arguments: [.init("path", .path)], output: .path,
                                requiredCapabilities: [.files], risk: .r2,
                                routePolicy: .deterministic, adapter: .publicAPI,
                                availability: .implemented),
        ]
    }

    private static var nativeShortcuts: [BELActionDefinition] {
        [BELActionDefinition(
            id: "shortcuts.run", kind: .native, titleKey: "Run shortcut",
            aliases: ["run shortcut", L("Run shortcut")],
            arguments: [.init("name", .text)], output: .text,
            requiredCapabilities: [.shortcuts], risk: .r2,
            routePolicy: .deterministic, adapter: .shortcut,
            availability: .implemented
        )]
    }

    private static func nativeID(for kind: SystemCommand.Kind) -> String {
        switch kind {
        case .openBrain: "brain.open"
        case .lockScreen: "system.lock_screen"
        case .sleepDisplay: "system.sleep_display"
        case .sleepMac: "system.sleep"
        case .emptyTrash: "files.empty_trash"
        case .toggleDarkMode: "system.toggle_dark_mode"
        case .toggleDoNotDisturb: "system.dnd_toggle"
        case .showDesktop: "system.show_desktop"
        case .screenSaver: "system.screen_saver"
        case .logOut: "system.log_out"
        case .restart: "system.restart"
        case .shutDown: "system.shutdown"
        case .toggleWiFi: "system.wifi_toggle"
        case .toggleBluetooth: "system.bluetooth_toggle"
        case .volumeMute: "system.mute"
        case .ejectDisks: "files.eject_disks"
        case .openTrash: "files.open_trash"
        case .openDownloads: "files.open_downloads"
        case .openDesktop: "files.open_desktop"
        case .openHome: "files.open_home"
        case .restartBeLauncher: "system.restart_belauncher"
        case .quitBeLauncher: "system.quit_belauncher"
        }
    }
}
