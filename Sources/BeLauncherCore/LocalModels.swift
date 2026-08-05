import Foundation

/// Finds the models already running on this Mac, instead of asking the person to know.
///
/// "Si tienes Ollama o LM Studio corriendo, funcionan sin clave" is true and useless: it puts the
/// burden of checking on the person who came here precisely because they did not want to think
/// about it. Both expose a plain HTTP list on localhost, so the app can just look and say what it
/// found — including, when it finds nothing, how to get one.
public enum LocalModels {

    public struct Installation: Sendable, Equatable, Identifiable {
        public let providerID: String
        public let name: String
        public let models: [String]
        public var id: String { providerID }
        public var isRunning: Bool { !models.isEmpty }

        public init(providerID: String, name: String, models: [String]) {
            self.providerID = providerID
            self.name = name
            self.models = models
        }
    }

    /// Where each local provider lists what it has loaded.
    static let catalogues: [(providerID: String, name: String, url: String)] = [
        ("ollama", "Ollama", "http://127.0.0.1:11434/api/tags"),
        ("lmstudio", "LM Studio", "http://127.0.0.1:1234/v1/models"),
    ]

    /// Ollama answers `{"models":[{"name":"llama3.2:latest",...}]}`, LM Studio answers the OpenAI
    /// shape `{"data":[{"id":"..."}]}`. Both are read here so a new local runner is one line.
    public static func models(in json: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return []
        }
        if let models = object["models"] as? [[String: Any]] {
            return models.compactMap { $0["name"] as? String }
        }
        if let data = object["data"] as? [[String: Any]] {
            return data.compactMap { $0["id"] as? String }
        }
        return []
    }

    /// Looks for every local runner at once. A short timeout on purpose: this runs while a window
    /// is opening, and a runner that is not there must not cost anyone a spinner.
    public static func installed(timeout: TimeInterval = 1.2) async -> [Installation] {
        await withTaskGroup(of: Installation?.self) { group in
            for entry in catalogues {
                group.addTask {
                    guard let url = URL(string: entry.url) else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = timeout
                    guard let (data, _) = try? await URLSession.shared.data(for: request) else {
                        return nil
                    }
                    let models = models(in: data)
                    guard !models.isEmpty else { return nil }
                    return Installation(providerID: entry.providerID, name: entry.name,
                                        models: models)
                }
            }
            var found: [Installation] = []
            for await installation in group {
                if let installation { found.append(installation) }
            }
            return found.sorted { $0.name < $1.name }
        }
    }

    /// What to tell someone who has no local model. One command, not a research project.
    public static let howToGetOne = """
        Ninguno corriendo. Para tener IA gratis y privada en este Mac:
        instala Ollama desde ollama.com y ejecuta «ollama pull llama3.2».
        BeLauncher lo detecta solo la próxima vez que abras esta pantalla.
        """
}
