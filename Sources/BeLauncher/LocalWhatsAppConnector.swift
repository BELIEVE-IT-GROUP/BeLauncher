import Foundation
import BeLauncherCore

/// WhatsApp on modern macOS does not expose the same plain SQLite contract as Messages.
///
/// This probe exists so the product can be honest: installed or web-backed WhatsApp is not the
/// same thing as a readable local message source. When a supported store is found, this is the
/// single place that should graduate from "detected but unsupported" to a parser.
enum LocalWhatsAppConnector {
    struct Status: Sendable, Equatable {
        let nativeContainers: [String]
        let webStores: [String]
        let supportedStores: [String]

        var installed: Bool { !nativeContainers.isEmpty || !webStores.isEmpty }
        var isSupported: Bool { !supportedStores.isEmpty }

        var sourceState: KnowledgeSource.State {
            if isSupported { return .available }
            return installed ? .unsupported : .planned
        }

        var diagnosticState: String {
            switch sourceState {
            case .available: return "supported-store-found"
            case .unsupported: return "detected-unsupported"
            case .planned: return "not-detected"
            case .connected: return "connected"
            case .manual: return "manual"
            }
        }

        var problem: String? {
            guard installed, !isSupported else { return nil }
            return L("WhatsApp is installed, but no supported readable local message store was found.")
        }
    }

    static func status(home: String = NSHomeDirectory()) -> Status {
        let manager = FileManager.default
        let nativeContainers = nativeContainerCandidates(home: home)
            .filter { manager.fileExists(atPath: $0) }
        let webStores = webStoreCandidates(home: home)
            .filter { manager.fileExists(atPath: $0) }
        let supportedStores = supportedStoreCandidates(home: home)
            .filter { manager.isReadableFile(atPath: $0) }
        return Status(nativeContainers: nativeContainers, webStores: webStores,
                      supportedStores: supportedStores)
    }

    static func nativeContainerCandidates(home: String) -> [String] {
        [
            "\(home)/Library/Containers/net.whatsapp.WhatsApp",
            "\(home)/Library/Containers/net.whatsapp.WhatsApp.WAAppKitBridgeService",
            "\(home)/Library/Containers/net.whatsapp.WhatsApp.ServiceExtension",
            "\(home)/Library/Containers/net.whatsapp.WhatsApp.Intents",
        ]
    }

    static func webStoreCandidates(home: String) -> [String] {
        let roots = [
            "\(home)/Library/Application Support/Google/Chrome",
            "\(home)/Library/Application Support/Chromium",
            "\(home)/Library/Application Support/Microsoft Edge",
            "\(home)/Library/Application Support/BraveSoftware/Brave-Browser",
        ]
        return roots.flatMap { root in
            chromeProfiles(root: root).map {
                "\($0)/IndexedDB/https_web.whatsapp.com_0.indexeddb.leveldb"
            }
        }
    }

    /// Known message database names from mobile/legacy exports and possible future desktop stores.
    /// Analytics, HTTP storage, model assets and WebKit bookkeeping are deliberately excluded.
    static func supportedStoreCandidates(home: String) -> [String] {
        let roots = [
            "\(home)/Library/Containers/net.whatsapp.WhatsApp/Data",
            "\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp",
            "\(home)/Library/Application Support/WhatsApp",
        ]
        let names = [
            "ChatStorage.sqlite",
            "msgstore.db",
            "messages.db",
            "chat.db",
            "wa.db",
        ]
        return roots.flatMap { root in
            names.map { "\(root)/\($0)" }
        }
    }

    private static func chromeProfiles(root: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        return entries.compactMap { name in
            guard name == "Default" || name.hasPrefix("Profile ") else { return nil }
            return "\(root)/\(name)"
        }
    }
}
