import Foundation

/// Browser bookmarks, recent documents and the folders people actually live in.
///
/// Read straight from the files the browsers already keep, with no extension installed and no
/// permission prompt. Nothing is written back and nothing leaves the Mac.
public enum ShortcutIndex {

    public static func scan(home: String = NSHomeDirectory()) -> [Shortcut] {
        chromiumBookmarks(home: home) + safariBookmarks(home: home) + commonFolders(home: home)
    }

    // MARK: - Chromium family (Chrome, Brave, Edge, Arc)

    static let chromiumProfiles = [
        "Library/Application Support/Google/Chrome/Default/Bookmarks",
        "Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks",
        "Library/Application Support/Microsoft Edge/Default/Bookmarks",
        "Library/Application Support/Arc/User Data/Default/Bookmarks",
    ]

    static func chromiumBookmarks(home: String) -> [Shortcut] {
        chromiumProfiles.flatMap { relative -> [Shortcut] in
            let path = (home as NSString).appendingPathComponent(relative)
            guard let data = FileManager.default.contents(atPath: path) else { return [] }
            return parseChromium(data)
        }
    }

    /// Chromium keeps bookmarks as a JSON tree of folders and urls.
    static func parseChromium(_ data: Data) -> [Shortcut] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }

        var found: [Shortcut] = []
        func walk(_ node: Any) {
            guard let node = node as? [String: Any] else { return }
            if let children = node["children"] as? [Any] {
                children.forEach(walk)
                return
            }
            guard node["type"] as? String == "url",
                  let name = node["name"] as? String,
                  let url = node["url"] as? String,
                  url.hasPrefix("http") else { return }
            found.append(Shortcut(title: name, target: url, source: .bookmark))
        }
        roots.values.forEach(walk)
        return found
    }

    // MARK: - Safari

    static func safariBookmarks(home: String) -> [Shortcut] {
        // Safari's Bookmarks.plist lives behind Full Disk Access. Rather than demand that
        // permission for a nice-to-have, we read it only if it happens to be readable.
        let path = (home as NSString).appendingPathComponent("Library/Safari/Bookmarks.plist")
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return []
        }
        var found: [Shortcut] = []
        func walk(_ node: Any) {
            guard let node = node as? [String: Any] else { return }
            if let children = node["Children"] as? [Any] {
                children.forEach(walk)
                return
            }
            guard node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
                  let url = node["URLString"] as? String,
                  url.hasPrefix("http") else { return }
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
            found.append(Shortcut(title: title, target: url, source: .bookmark))
        }
        walk(plist)
        return found
    }

    // MARK: - Folders

    static func commonFolders(home: String) -> [Shortcut] {
        let candidates = [
            ("Escritorio", "Desktop"), ("Documentos", "Documents"), ("Descargas", "Downloads"),
            ("Imágenes", "Pictures"), ("Películas", "Movies"), ("Música", "Music"),
            ("Aplicaciones", "../../Applications"), ("Carpeta personal", ""),
        ]
        // The home folder is checked; the ones inside it are not, on purpose. Downloads, Desktop
        // and Documents are TCC-protected on recent macOS, and merely asking whether they are
        // there pops the "would like to access your Downloads folder" dialog at launch — the exact
        // thing this app promises not to do. They ship with every Mac; if one is missing, opening
        // it fails harmlessly and the permission gets asked then, when the user can see why.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        return candidates.map { title, relative in
            let path = relative.isEmpty ? home : (home as NSString).appendingPathComponent(relative)
            return Shortcut(title: title, target: path, source: .folder)
        }
    }

    // MARK: - Recent documents

    /// The same list the Apple menu shows, read from the shared file list.
    public static func recentDocuments(limit: Int = 30) -> [Shortcut] {
        let defaults = UserDefaults.standard.persistentDomain(forName: "com.apple.recentitems")
        guard let documents = defaults?["RecentDocuments"] as? [String: Any],
              let items = documents["CustomListItems"] as? [[String: Any]] else { return [] }
        return items.prefix(limit).compactMap { item in
            guard let name = item["Name"] as? String else { return nil }
            return Shortcut(title: name, target: name, source: .recentDocument)
        }
    }
}
