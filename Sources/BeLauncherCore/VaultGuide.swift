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
        ("objects", "Lo que la empresa cree: decisiones, políticas, compromisos, notas. Un archivo por cosa."),
        ("commits", "El historial de cómo llegó ahí cada cosa: quién la propuso y quién la confirmó."),
        ("attachments", "Archivos que respaldan una memoria: un PDF, una captura, un contrato."),
        ("people", "Quién es quién: clientes, socios, el equipo."),
        ("projects", "En qué estáis trabajando."),
        ("meetings", "Notas en crudo antes de destilarlas en decisiones."),
        ("inbox", "Lo que llega sin sitio todavía. Vaciarlo es la tarea, no llenarlo."),
    ]

    public static let readme = """
        # Tu cerebro

        Esto es una carpeta normal con archivos Markdown normales. No hay base de datos
        propietaria, ni formato secreto, ni servidor. Si mañana dejas BeLauncher, te llevas esta
        carpeta y no pierdes nada. Esa es la única forma honesta de pedirte que metas aquí la
        memoria de tu empresa.

        ## Qué hay en cada carpeta

        | Carpeta | Para qué |
        | --- | --- |
        | `objects` | Lo que la empresa cree hoy: decisiones, políticas, compromisos, notas. |
        | `commits` | Cómo llegó ahí cada cosa: quién la propuso, quién la confirmó, cuándo. |
        | `attachments` | Lo que respalda una memoria: un PDF, una captura, un contrato. |
        | `people` | Clientes, socios, el equipo. |
        | `projects` | En qué estás trabajando. |
        | `meetings` | Notas en crudo, antes de destilarlas. |
        | `inbox` | Lo que llega sin sitio. Vaciarlo es la tarea. |

        ## Cómo se llena

        No a mano. Desde el lanzador:

        - **`recordar que …`** propone una memoria. Fíjate en «propone»: nada entra aquí sin que
          tú lo confirmes. Un cerebro que se escribe solo es un cerebro en el que no puedes
          confiar.
        - **`capturar reunion`** con tus notas copiadas saca las decisiones y los compromisos y
          te los propone uno a uno.
        - **`qué decidimos sobre …`** te devuelve lo que está vigente hoy, no todo lo que se dijo
          alguna vez.
        - **`pulse`** te dice qué se está pudriendo: contradicciones, compromisos vencidos,
          decisiones que nadie ha revisado en medio año.

        ## Cómo adjuntar algo

        Copia el archivo dentro de `attachments/` y nómbralo con el id de la memoria a la que
        pertenece, o arrástralo sobre la memoria desde el lanzador. En el Markdown queda como un
        enlace relativo normal, así que Obsidian, GitHub y cualquier editor lo abren.

        ## Obsidian

        Esta carpeta ya es un vault de Obsidian válido: Obsidian no pide nada especial, solo una
        carpeta con archivos `.md`. Ábrelo con **Abrir en Obsidian** en Ajustes → Mi cerebro, o en
        Obsidian con «Abrir carpeta como almacén» y eliges esta carpeta. Los enlaces `[[así]]`
        entre memorias funcionan en los dos sitios.

        ## Git

        Si quieres historial y copia de seguridad, esta carpeta puede ser un repositorio git. El
        botón **Convertir en repositorio git** de Ajustes lo inicializa con un `.gitignore`
        sensato. A partir de ahí es git normal: `git remote add origin …` y `git push`.

        Ojo con lo obvio: si subes esto a un repositorio, lo que haya aquí dentro estará donde esté
        ese repositorio. Para memoria de empresa, privado.
        """

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
        let readmePath = (root as NSString).appendingPathComponent("LÉEME.md")
        if !manager.fileExists(atPath: readmePath) {
            try readme.write(toFile: readmePath, atomically: true, encoding: .utf8)
            created.append("LÉEME.md")
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
            return .failed("git init falló. ¿Tienes las herramientas de línea de comandos de Xcode?")
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
