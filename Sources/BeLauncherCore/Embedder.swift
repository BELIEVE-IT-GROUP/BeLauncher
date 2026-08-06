import Foundation

/// Turning passages into vectors.
///
/// The obvious choice was the one macOS ships — `NLContextualEmbedding`, on-device, no setup, no
/// server. It was measured against a corpus of real statements and it does not work for this:
/// "qué prometió Andrés" retrieved a note about secrets management, and "dónde guardamos las
/// claves" retrieved one about buying coffee. That model returns per-token hidden states, which is
/// a different job from deciding whether two sentences mean the same thing; mean-pooling them puts
/// every vector inside a narrow cone where an answer scores 0.870 and pure noise scores 0.856.
/// Centring the vectors widened that gap five-fold and still ranked the wrong passage first.
/// `NLEmbedding.sentenceEmbedding` was worse: one query in four, with a single sentence winning
/// almost everything.
///
/// So the vectors come from a retrieval model. On the same corpus `bge-m3` answered four of four
/// with margins between +0.046 and +0.342, at 224 ms a passage — which only matters while
/// indexing, since indexing happens once and in the background.
///
/// The cost of that decision is honest and stated everywhere it applies: real semantic search
/// needs a model this machine does not come with. Without one the launcher still searches by word
/// and by graph, and says so, rather than pretending.
public struct EmbeddingEngine: Sendable, Equatable, Identifiable {

    public enum Shape: String, Sendable, Equatable, Codable {
        /// Ollama's own endpoint: `{"model": ..., "input": [...]}`.
        case ollama
        /// The OpenAI embeddings shape, which LM Studio and OpenAI itself both speak.
        case openAI
    }

    public var id: String { providerID + "·" + model }
    public let providerID: String
    public let name: String
    public let shape: Shape
    public let endpoint: String
    public let model: String
    /// Empty for anything running on this machine.
    public let keychainAccount: String

    public var isLocal: Bool { keychainAccount.isEmpty }

    public init(providerID: String, name: String, shape: Shape, endpoint: String,
                model: String, keychainAccount: String = "") {
        self.providerID = providerID
        self.name = name
        self.shape = shape
        self.endpoint = endpoint
        self.model = model
        self.keychainAccount = keychainAccount
    }

    // MARK: - Choosing one

    /// Local embedding models in the order they actually performed, best first.
    ///
    /// This is a measurement, not a reputation ranking: on the same twelve statements and four
    /// questions, `bge-m3` answered all four and `nomic-embed-text` answered two, despite both
    /// being popular choices. Anything unrecognised still goes in the list, at the end — an
    /// embedding model nobody has benchmarked here beats no vectors at all.
    public static let preferredLocalModels = ["bge-m3", "multilingual-e5", "e5-", "mxbai-embed",
                                              "snowflake-arctic-embed", "nomic-embed", "embed"]

    public static func rank(_ model: String) -> Int {
        let name = model.lowercased()
        for (index, marker) in preferredLocalModels.enumerated() where name.contains(marker) {
            return index
        }
        return preferredLocalModels.count
    }

    /// Picks the best engine available, preferring anything that never leaves the machine.
    ///
    /// A hosted key wins over nothing, but never over a local model: this index holds everything
    /// the person works on, and shipping that to a third party to make search nicer is not a
    /// trade the app gets to make quietly.
    public static func best(localModels: [String: [String]], hostedKeyAvailable: Bool) -> EmbeddingEngine? {
        var candidates: [(rank: Int, engine: EmbeddingEngine)] = []

        for (providerID, models) in localModels {
            let shape: Shape = providerID == "ollama" ? .ollama : .openAI
            let endpoint = providerID == "ollama"
                ? "http://127.0.0.1:11434/api/embed"
                : "http://127.0.0.1:1234/v1/embeddings"
            let name = providerID == "ollama" ? "Ollama" : "LM Studio"
            for model in models where isEmbeddingModel(model) {
                candidates.append((rank(model), EmbeddingEngine(
                    providerID: providerID, name: name, shape: shape,
                    endpoint: endpoint, model: model)))
            }
        }
        if let best = candidates.min(by: { $0.rank == $1.rank ? $0.engine.model < $1.engine.model : $0.rank < $1.rank }) {
            return best.engine
        }
        guard hostedKeyAvailable else { return nil }
        return EmbeddingEngine(
            providerID: "openai", name: "OpenAI", shape: .openAI,
            endpoint: "https://api.openai.com/v1/embeddings",
            model: "text-embedding-3-small", keychainAccount: "openai"
        )
    }

    /// The inverse of the filter the chat side uses: here an embedding model is the point.
    public static func isEmbeddingModel(_ model: String) -> Bool {
        let name = model.lowercased()
        return LocalModels.embeddingMarkers.contains { name.contains($0) }
    }

    public static let howToGetOne = """
    La búsqueda por significado necesita un modelo de embeddings en tu Mac. \
    Con Ollama instalado: «ollama pull bge-m3». Es el que mejor respondió en las pruebas \
    y ocupa unos 2 GB. Mientras no haya ninguno, BeLauncher busca por palabras y por \
    relaciones, que sigue funcionando pero no entiende sinónimos.
    """
}

public enum EmbeddingError: Error, Equatable, CustomStringConvertible {
    case noEngine
    case missingKey(String)
    case transport(String)
    case emptyResponse
    /// The engine answered with a different number of vectors than passages sent, which would
    /// silently pair each passage with someone else's vector.
    case countMismatch(sent: Int, received: Int)

    public var description: String {
        switch self {
        case .noEngine:
            EmbeddingEngine.howToGetOne
        case .missingKey(let provider):
            "Falta la clave de \(provider) para calcular los vectores."
        case .transport(let reason):
            "No pude calcular los vectores: \(reason)"
        case .emptyResponse:
            "El modelo de embeddings no devolvió nada."
        case .countMismatch(let sent, let received):
            "El modelo devolvió \(received) vectores para \(sent) pasajes."
        }
    }
}

/// Talks to whichever engine was chosen.
///
/// The transport is injectable for the same reason the intelligence client's is: the interesting
/// failures — a truncated response, a mismatched count, an engine that went away mid-index — are
/// the ones worth testing, and none of them can be provoked reliably against a real server.
public struct Embedder: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public var transport: Transport
    public var keyLookup: @Sendable (String) -> String?

    public init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        keyLookup: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.transport = transport
        self.keyLookup = keyLookup
    }

    /// How many passages go in one request. Large enough that indexing a few thousand passages is
    /// a handful of round trips, small enough that one failure does not lose ten minutes of work.
    public static let batchSize = 16

    public func embed(_ texts: [String], using engine: EmbeddingEngine) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var request = URLRequest(url: URL(string: engine.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Indexing runs in the background against a model that may be loading from disk on the
        // first call; the default 60 seconds is not enough for a cold 2 GB model.
        request.timeoutInterval = 180

        if !engine.keychainAccount.isEmpty {
            guard let key = keyLookup(engine.keychainAccount), !key.isEmpty else {
                throw EmbeddingError.missingKey(engine.name)
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = switch engine.shape {
        case .ollama: ["model": engine.model, "input": texts]
        case .openAI: ["model": engine.model, "input": texts]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            let (received, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let detail = String(data: received, encoding: .utf8) ?? ""
                throw EmbeddingError.transport("\(http.statusCode) \(detail.prefix(200))")
            }
            data = received
        } catch let error as EmbeddingError {
            throw error
        } catch {
            throw EmbeddingError.transport(error.localizedDescription)
        }

        let vectors = try Embedder.parse(data, shape: engine.shape)
        guard !vectors.isEmpty else { throw EmbeddingError.emptyResponse }
        // Without this check a short response would pair passage 5 with passage 2's vector and the
        // index would be quietly, permanently wrong — the worst kind of bug, because every search
        // still returns something.
        guard vectors.count == texts.count else {
            throw EmbeddingError.countMismatch(sent: texts.count, received: vectors.count)
        }
        return vectors.map(Semantic.normalise)
    }

    /// Both shapes, because Ollama returns a bare array and OpenAI wraps each vector in an object
    /// carrying its index.
    public static func parse(_ data: Data, shape: EmbeddingEngine.Shape) throws -> [[Float]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EmbeddingError.emptyResponse
        }
        switch shape {
        case .ollama:
            let raw = root["embeddings"] as? [[Any]] ?? []
            return raw.map { $0.compactMap { ($0 as? NSNumber)?.floatValue } }
        case .openAI:
            let rows = root["data"] as? [[String: Any]] ?? []
            // Sorted by the index the API states rather than by arrival order, which is the whole
            // reason that field exists.
            return rows
                .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
                .map { ($0["embedding"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.floatValue } }
        }
    }
}
