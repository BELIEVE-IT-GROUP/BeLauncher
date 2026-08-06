import Foundation

/// Paste a path, press Enter, you are there.
///
/// The Finder has had ⌘⇧G forever and it only works in the Finder, so the actual workflow is:
/// copy a path from a terminal or a chat, switch to the Finder, open a sheet, paste, Enter. From a
/// launcher it is one step, and it is the one people reach for constantly without a name for it.
///
/// Completion is what makes it feel native rather than like a text box: typing `/Users/mac/De`
/// and pressing Tab should finish the word, the same way a shell does.
public enum GoToPath {

    public struct Target: Sendable, Equatable {
        public let path: String
        public let isDirectory: Bool
        public let exists: Bool
        /// What Tab would complete to, when there is exactly one sensible answer.
        public let completion: String?

        public init(path: String, isDirectory: Bool, exists: Bool, completion: String? = nil) {
            self.path = path
            self.isDirectory = isDirectory
            self.exists = exists
            self.completion = completion
        }

        public var name: String {
            path == "/" ? "Raíz del disco" : (path as NSString).lastPathComponent
        }
    }

    /// Whether what was typed looks like a path at all.
    ///
    /// Deliberately narrow. A launcher whose search box treats every word as a possible path
    /// fills the list with things that do not exist, so this only fires on the shapes that are
    /// unambiguously a path: an absolute one, a home-relative one, an explicit relative one, or a
    /// file URL.
    public static func looksLikePath(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        return trimmed.hasPrefix("/")
            || trimmed.hasPrefix("~/") || trimmed == "~"
            || trimmed.hasPrefix("./") || trimmed.hasPrefix("../")
            || trimmed.hasPrefix("file://")
    }

    /// Turns what was typed into a real path.
    ///
    /// Handles the two things people actually paste: a `file://` URL from a browser or a chat app,
    /// which arrives percent-encoded, and a shell-style path with escaped spaces.
    public static func expand(_ query: String, home: String = NSHomeDirectory(),
                              workingDirectory: String = NSHomeDirectory()) -> String {
        var text = query.trimmingCharacters(in: .whitespaces)

        if text.hasPrefix("file://") {
            if let url = URL(string: text), url.isFileURL { return url.path }
            text = String(text.dropFirst("file://".count))
            return text.removingPercentEncoding ?? text
        }
        // Copying a path out of a terminal brings the backslashes with it.
        text = text.replacingOccurrences(of: "\\ ", with: " ")

        if text == "~" { return home }
        if text.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(text.dropFirst(2)))
        }
        if text.hasPrefix("./") || text.hasPrefix("../") {
            return ((workingDirectory as NSString).appendingPathComponent(text) as NSString)
                .standardizingPath
        }
        return (text as NSString).standardizingPath
    }

    /// What is at that path, plus what Tab should complete to.
    public static func resolve(_ query: String, home: String = NSHomeDirectory(),
                               contents: (String) -> [String] = GoToPath.children,
                               exists: (String) -> (Bool, Bool) = GoToPath.check) -> Target? {
        guard looksLikePath(query) else { return nil }
        let path = expand(query, home: home)
        let (found, isDirectory) = exists(path)

        if found {
            return Target(path: path, isDirectory: isDirectory, exists: true,
                          completion: isDirectory && !path.hasSuffix("/") ? path + "/" : nil)
        }

        // Not there yet: complete against the folder it is inside, which is what makes typing a
        // long path bearable.
        let parent = (path as NSString).deletingLastPathComponent
        let partial = (path as NSString).lastPathComponent
        let (parentExists, parentIsDirectory) = exists(parent)
        guard parentExists, parentIsDirectory, !partial.isEmpty else {
            return Target(path: path, isDirectory: false, exists: false)
        }

        let matches = contents(parent)
            .filter { $0.lowercased().hasPrefix(partial.lowercased()) && !$0.hasPrefix(".") }
            .sorted()
        guard let single = matches.first, matches.count == 1 else {
            // More than one answer is not a completion, it is a guess. Leave it alone.
            return Target(path: path, isDirectory: false, exists: false)
        }
        return Target(path: path, isDirectory: false, exists: false,
                      completion: (parent as NSString).appendingPathComponent(single))
    }

    /// What to say when the path is not there — naming the part that is wrong, not just "no".
    public static func explain(_ target: Target) -> String {
        let parent = (target.path as NSString).deletingLastPathComponent
        return "No existe «\(target.name)» dentro de \(parent)."
    }

    // MARK: - The disk

    public static func check(_ path: String) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return (found, isDirectory.boolValue)
    }

    public static func children(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
