import Foundation

/// Makes the vault explain itself the moment it exists.
///
/// A folder called `objects` next to a folder called `commits` tells the person who owns the
/// memory nothing about how their memory is meant to grow. Worse, the app said the vault "can be
/// an Obsidian vault or a git repository" without ever saying how — a claim the user had to
/// implement themselves to find out whether it was true.
///
/// So the vault ships with the folders it is supposed to have, a README that reads like an
/// explanation rather than a schema, and the two things that were only promises are now one
/// function each.
public enum VaultGuide {

    /// The folders a working brain ends up needing, created on day one so nobody has to invent
    /// the structure. Empty folders with a purpose beat a clever empty folder.
    public static let folders: [(name: String, purpose: String)] = [
        ("objects", L("What the company believes: decisions, policies, commitments, notes. One file per thing.")),
        ("commits", L("The history of how each thing got there: who proposed it and who confirmed it.")),
        ("attachments", L("Files that back a memory up: a PDF, a screenshot, a contract.")),
        ("people", L("Who is who: clients, partners, the team.")),
        ("projects", L("What you are working on.")),
        ("meetings", L("Raw notes before they are distilled into decisions.")),
        ("inbox", L("Whatever arrives with nowhere to go yet. Emptying it is the job, not filling it.")),
    ]

    /// The read-me the vault opens with, in the language of the window at the moment it was
    /// created. It stays in that language afterwards: the file is on the user's disk, and rewriting
    /// somebody's own notes because they changed a menu setting is not the app's business.
    public static var readme: String {
        L("""
        # Your brain

        This is an ordinary folder of ordinary Markdown files. No proprietary database, no secret
        format, no server. If you walk away from BeLauncher tomorrow you take this folder with you
        and lose nothing. That is the only honest way to ask you to put your company's memory in
        here.

        ## What is in each folder

        | Folder | What for |
        | --- | --- |
        | `objects` | What the company believes today: decisions, policies, commitments, notes. |
        | `commits` | How each thing got there: who proposed it, who confirmed it, when. |
        | `attachments` | What backs a memory up: a PDF, a screenshot, a contract. |
        | `people` | Clients, partners, the team. |
        | `projects` | What you are working on. |
        | `meetings` | Raw notes, before they are distilled. |
        | `inbox` | Whatever arrives with nowhere to go. Emptying it is the job. |

        ## How it fills up

        Not by hand. From the launcher:

        - **`remember that …`** proposes a memory. Note "proposes": nothing gets in here without
          you confirming it. A brain that writes itself is a brain you cannot trust.
        - **`capture meeting`** with your notes on the clipboard pulls out the decisions and the
          commitments and offers them to you one at a time.
        - **`what did we decide about …`** gives you back what still stands today, not everything
          that was ever said.
        - **`pulse`** tells you what is going stale: contradictions, overdue commitments, decisions
          nobody has looked at in six months.

        ## How to attach something

        Copy the file into `attachments/` and name it with the id of the memory it belongs to, or
        drag it onto the memory from the launcher. In the Markdown it ends up as an ordinary
        relative link, so any editor opens it.

        ## It is just a folder

        Every file in here is plain `.md`. Any Markdown editor opens it, and if you want history and
        backups you can make this folder a git repository yourself — nothing in the app depends on
        it either way.

        Mind the obvious one: if you push this to a repository, whatever is in here ends up wherever
        that repository is. For company memory, make it private.
        """)
    }

    /// The folders the app reads back as data. Nothing may be written into them except real
    /// memories and real commits.
    public static let machineRead: Set<String> = ["objects", "commits"]

    /// Files git should never take: the index rebuilds itself, and attachments are usually the
    /// heavy, private part someone did not mean to push.
    public static let gitignore = """
        .DS_Store
        *.sqlite3
        *.sqlite3-wal
        *.sqlite3-shm
        """

    // MARK: - Making it real

    /// The name of the read-me the vault ships with. Deliberately not translated: the file lives on
    /// disk and belongs to the person, so it keeps whatever name it was created with even after
    /// they switch the interface to another language. Declared once because Settings has a button
    /// that opens it — spelling the name out a second time there put the button one keystroke away
    /// from opening a file that does not exist.
    public static let readmeName = "LÉEME.md"

    /// Creates the folders and the README, without touching anything already there.
    @discardableResult
    public static func scaffold(at root: String,
                                manager: FileManager = .default) throws -> [String] {
        var created: [String] = []
        for folder in folders {
            let path = (root as NSString).appendingPathComponent(folder.name)
            if !manager.fileExists(atPath: path) {
                try manager.createDirectory(atPath: path, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                created.append(folder.name)
            }
            // A folder that explains itself survives being looked at in six months — but not the
            // two the app parses. Every `.md` in `objects` is a memory and every one in `commits`
            // is a commit, so a friendly note dropped in there is read back as a decision the
            // company never made. Those two are explained in the README instead.
            guard !machineRead.contains(folder.name) else { continue }
            let note = (path as NSString).appendingPathComponent("QUÉ VA AQUÍ.md")
            if !manager.fileExists(atPath: note) {
                try? "# \(folder.name)\n\n\(folder.purpose)\n".write(toFile: note, atomically: true,
                                                                    encoding: .utf8)
            }
        }
        let readmePath = (root as NSString).appendingPathComponent(readmeName)
        if !manager.fileExists(atPath: readmePath) {
            try readme.write(toFile: readmePath, atomically: true, encoding: .utf8)
            created.append(readmeName)
        }
        return created
    }

    /// Obsidian opens a folder as a vault through its URL scheme. No plugin, no export.
    public static func obsidianURL(for root: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let path = root.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "obsidian://open?path=\(path)")
    }

    public enum GitResult: Sendable, Equatable {
        case created
        case alreadyGit
        case failed(String)
    }

    /// Turns the vault into a git repository. Nothing is committed and no remote is added: what
    /// gets published, and where, stays the person's decision.
    public static func makeGitRepository(at root: String,
                                         run: (String, [String]) -> Int32 = VaultGuide.runGit)
        -> GitResult
    {
        let manager = FileManager.default
        if manager.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) {
            return .alreadyGit
        }
        guard run("/usr/bin/git", ["-C", root, "init", "-q"]) == 0 else {
            return .failed(L("git init failed. Do you have Xcode's command line tools?"))
        }
        try? gitignore.write(toFile: (root as NSString).appendingPathComponent(".gitignore"),
                             atomically: true, encoding: .utf8)
        return .created
    }

    public static func runGit(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
