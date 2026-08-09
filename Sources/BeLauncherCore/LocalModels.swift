import Foundation

/// Finds the models already running on this Mac, instead of asking the person to know.
///
/// "Si tienes Ollama o LM Studio corriendo, funcionan sin clave" is true and useless: it puts the
/// burden of checking on the person who came here precisely because they did not want to think
/// about it. Both expose a plain HTTP list on localhost, so the app can just look and say what it
/// found — including, when it finds nothing, how to get one.
public enum LocalModels {

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

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

    /// Where each local provider lists what it has loaded. This is derived from the canonical
    /// registry so adding a local runner does not require a second catalogue in the app target.
    static var catalogues: [(providerID: String, name: String, url: String)] {
        ModelProviderRegistry.all
            .filter { $0.isPrivate }
            .compactMap { descriptor in
                guard let url = descriptor.modelsEndpoint else { return nil }
                return (descriptor.id, descriptor.name, url)
            }
    }

    /// Ollama answers `{"models":[{"name":"llama3.2:latest",...}]}`, LM Studio answers the OpenAI
    /// shape `{"data":[{"id":"..."}]}`. Both are read here so a new local runner is one line.
    public static func models(in json: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return []
        }
        if let models = object["models"] as? [[String: Any]] {
            return uniqueModels(models.compactMap { $0["name"] as? String })
        }
        if let data = object["data"] as? [[String: Any]] {
            return uniqueModels(data.compactMap { $0["id"] as? String })
        }
        return []
    }

    private static func uniqueModels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    /// Looks for every local runner at once. A short timeout on purpose: this runs while a window
    /// is opening, and a runner that is not there must not cost anyone a spinner.
    /// `including` decides which models count. It defaults to the chat filter because that is
    /// what every caller wanted until embeddings existed — and the default silently hid every
    /// embedding model from the semantic index, which then reported "no hay ningún modelo" on a
    /// machine with three of them installed.
    public static func installed(timeout: TimeInterval = 1.2,
                                 including accept: @Sendable @escaping (String) -> Bool = canChat,
                                 transport: @escaping Transport = { try await URLSession.shared.data(for: $0) })
    async -> [Installation] {
        await withTaskGroup(of: Installation?.self) { group in
            for entry in catalogues {
                group.addTask {
                    guard let url = URL(string: entry.url) else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = timeout
                    guard let (data, response) = try? await transport(request),
                          (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                        return nil
                    }
                    let models = models(in: data).filter(accept)
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

    /// Models that cannot hold a conversation, however many of them are installed.
    ///
    /// An Ollama library is usually a mix: a couple of chat models and several embedding models
    /// pulled by some other tool. Picking the first name in the list lands on `nomic-embed-text`
    /// about as often as not, and asking an embedding model to translate a sentence fails in a way
    /// that looks exactly like the app being broken.
    static let embeddingMarkers = ["embed", "bge-", "gte-", "e5-", "minilm", "rerank"]

    public static func canChat(_ model: String) -> Bool {
        let name = model.lowercased()
        return !embeddingMarkers.contains { name.contains($0) }
    }

    /// Chooses a model that is actually present in the discovered catalogue. A saved choice wins
    /// only while it still exists; otherwise the first chat-capable model is used. Returning nil
    /// is important: it prevents a default name such as `llama3.2` from being sent to a runner
    /// that has no such model.
    public static func selectedModel(in installation: Installation,
                                     saved: String? = nil) -> String? {
        if let saved, installation.models.contains(saved), canChat(saved) { return saved }
        return installation.models.first(where: canChat)
    }

    /// What to tell someone who has no local model. One command, not a research project.
    public static let howToGetOne = """
        Ningún modelo de chat disponible. Para tener IA gratis y privada en este Mac:
        instala Ollama desde ollama.com y ejecuta «ollama pull qwen2.5».
        Si ya tienes Ollama abierto, puede que solo tengas modelos de embeddings
        (nomic-embed-text, bge…), que no saben conversar.
        BeLauncher lo detecta solo la próxima vez que abras esta pantalla.
        """
}
