import Foundation

/// The whole path, from a typed question to cited passages.
///
/// Kept in one place because the parts are useless separately and easy to wire up wrong: an index
/// written with one embedding model and searched with another returns confident nonsense, and a
/// query embedded without normalising scores against a normalised corpus quietly ranks by vector
/// length instead of by meaning. Both are invisible from the outside — every search still returns
/// something — so the wiring lives here and is exercised end to end by the diagnostic.
@MainActor
public final class BrainSearch {

    public struct Progress: Sendable, Equatable {
        public let passages: Int
        public let vectorised: Int
        public let engine: String?

        public var isComplete: Bool { passages > 0 && vectorised >= passages }
        public var percent: Double { passages == 0 ? 0 : Double(vectorised) / Double(passages) }

        public init(passages: Int, vectorised: Int, engine: String?) {
            self.passages = passages
            self.vectorised = vectorised
            self.engine = engine
        }
    }

    private let store: Store
    private let embedder: Embedder
    public private(set) var engine: EmbeddingEngine?

    public init(store: Store, embedder: Embedder = Embedder(), engine: EmbeddingEngine? = nil) {
        self.store = store
        self.embedder = embedder
        self.engine = engine
    }

    /// Finds an embedding model without asking anyone to configure one.
    ///
    /// A launcher that needs a settings trip before its headline feature does anything is a
    /// launcher nobody sees the headline feature of. If a model is already installed it is simply
    /// used; if not, search still works by word and says why it is not doing more.
    @discardableResult
    public func detectEngine(hostedKeyAvailable: Bool = false) async -> EmbeddingEngine? {
        var installed: [String: [String]] = [:]
        for provider in await LocalModels.installed(including: EmbeddingEngine.isEmbeddingModel) {
            installed[provider.providerID] = provider.models
        }
        engine = EmbeddingEngine.best(localModels: installed, hostedKeyAvailable: hostedKeyAvailable)
        return engine
    }

    // MARK: - Indexing

    public func progress() -> Progress {
        let counts = store.indexedPassageCount()
        return Progress(passages: counts.total, vectorised: counts.vectorised, engine: engine?.model)
    }

    /// Cuts everything into passages. Cheap, synchronous, no network.
    @discardableResult
    public func index(memories: [MemoryObject], nodes: [WorkNode], clips: [Clip]) -> Int {
        store.reindex(memories: memories, nodes: nodes, clips: clips)
    }

    /// Embeds whatever is still missing a vector, a batch at a time.
    ///
    /// Returns how many were done so a caller can loop until it returns zero. Batching rather than
    /// one long pass because the person is using the launcher while this runs: a failure halfway
    /// through costs one batch, and the vectors already written stay written.
    @discardableResult
    public func embedPending(limit: Int = Embedder.batchSize) async throws -> Int {
        guard let engine else { throw EmbeddingError.noEngine }
        let pending = store.passagesNeedingVectors(model: engine.model, limit: limit)
        guard !pending.isEmpty else { return 0 }

        let vectors = try await embedder.embed(pending.map(\.text), using: engine)
        for (passage, vector) in zip(pending, vectors) {
            store.storeVector(vector, for: passage.id, model: engine.model)
        }
        return pending.count
    }

    /// Runs to completion, giving the window a turn between batches.
    ///
    /// This used to say it never ran while somebody was typing. It does: the app starts it at
    /// launch, which is precisely when somebody reaches for the launcher. Saying otherwise in a
    /// comment did not make it true — it only meant nobody looked here when the window froze.
    ///
    /// Every batch reads and writes SQLite, and this class is on the main actor, so a tight loop
    /// over a hundred and forty batches holds the main thread for the whole pass. The `yield`
    /// hands control back between batches so a keystroke is serviced instead of queued behind the
    /// rest of the brain. The batches themselves are fast now; this is what keeps them polite.
    @discardableResult
    public func embedEverything(maximumBatches: Int = 500) async throws -> Int {
        var total = 0
        for _ in 0..<maximumBatches {
            let done = try await embedPending()
            if done == 0 { break }
            total += done
            await Task.yield()
        }
        return total
    }

    // MARK: - Asking

    public func search(_ query: String, limit: Int = 8) async -> Retriever.Result {
        var vector: [Float] = []
        if let engine {
            // A query that fails to embed degrades to word search rather than to an error: the
            // model being asleep is not a reason to tell someone their brain is broken.
            vector = (try? await embedder.embed([query], using: engine))?.first ?? []
        }
        return Retriever.retrieve(
            query: query,
            queryVector: vector,
            nearest: { [store] in store.nearest(to: vector, limit: $0) },
            words: { [store] in store.matchingWords(query, limit: $0) },
            passage: { [store] in store.passage(id: $0) },
            related: { [store] in store.relatedSources(to: $0) },
            passages: { [store] in store.passages(for: $0) },
            limit: limit
        )
    }
}
