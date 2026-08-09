import Foundation

/// The only identity a prefix/KV cache may see. Callers provide digests, never prompt text.
public struct BELPrefixKVCacheKey: Sendable, Hashable, Codable {
    public enum PrivacyScope: String, Sendable, Codable, CaseIterable {
        case working
        case longTerm
    }

    public let schemaVersion: Int
    public let modelID: String
    public let modelRevision: String
    public let scope: PrivacyScope
    /// A session boundary for working memory, or a vault boundary for long-term memory.
    public let boundary: String
    public let prefixDigest: String

    public init(schemaVersion: Int = 1, modelID: String, modelRevision: String,
                scope: PrivacyScope, boundary: String, prefixDigest: String) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.scope = scope
        self.boundary = boundary
        self.prefixDigest = prefixDigest
    }

    public var isValid: Bool {
        schemaVersion > 0 && !modelID.isEmpty && !modelRevision.isEmpty
            && !boundary.isEmpty && !prefixDigest.isEmpty
    }
}

/// An in-memory, privacy-scoped prefix cache. It is deliberately not persisted.
public actor BELPrefixKVCache {
    public struct Configuration: Sendable, Equatable {
        public let maxEntries: Int
        public let maxBytes: Int
        public let ttl: TimeInterval

        public init(maxEntries: Int = 32, maxBytes: Int = 64 * 1024 * 1024,
                    ttl: TimeInterval = 15 * 60) {
            self.maxEntries = maxEntries
            self.maxBytes = maxBytes
            self.ttl = ttl
        }
    }

    public struct Metrics: Sendable, Equatable {
        public let hits: Int
        public let misses: Int
        public let rejected: Int
        public let evictions: Int
        public let entries: Int
        public let bytes: Int

        public init(hits: Int = 0, misses: Int = 0, rejected: Int = 0,
                    evictions: Int = 0, entries: Int = 0, bytes: Int = 0) {
            self.hits = hits
            self.misses = misses
            self.rejected = rejected
            self.evictions = evictions
            self.entries = entries
            self.bytes = bytes
        }
    }

    private struct Entry: Sendable {
        let value: Data
        let createdAt: Date
        var lastAccess: UInt64
    }

    private let configuration: Configuration
    private var entries: [BELPrefixKVCacheKey: Entry] = [:]
    private var clock: UInt64 = 0
    private var hitCount = 0
    private var missCount = 0
    private var rejectedCount = 0
    private var evictionCount = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns nil for an unknown, expired, or invalid key. A miss never reveals a reason to a
    /// caller that could use it to infer another scope's contents.
    public func value(for key: BELPrefixKVCacheKey, now: Date = .now) -> Data? {
        guard key.isValid, configuration.maxEntries > 0, configuration.maxBytes > 0 else {
            rejectedCount += 1
            return nil
        }
        guard var entry = entries[key] else {
            missCount += 1
            return nil
        }
        guard now.timeIntervalSince(entry.createdAt) <= configuration.ttl else {
            entries.removeValue(forKey: key)
            missCount += 1
            bytes -= entry.value.count
            return nil
        }
        clock &+= 1
        entry.lastAccess = clock
        entries[key] = entry
        hitCount += 1
        return entry.value
    }

    /// Stores opaque runtime bytes only when the key and configured capacity are valid.
    @discardableResult
    public func insert(_ value: Data, for key: BELPrefixKVCacheKey, now: Date = .now) -> Bool {
        guard key.isValid, !value.isEmpty,
              value.count <= configuration.maxBytes,
              configuration.maxEntries > 0 else {
            rejectedCount += 1
            return false
        }
        if let old = entries.removeValue(forKey: key) { bytes -= old.value.count }
        clock &+= 1
        entries[key] = Entry(value: value, createdAt: now, lastAccess: clock)
        bytes += value.count
        trimIfNeeded()
        return entries[key] != nil
    }

    /// Clears one privacy boundary without affecting any other session or vault.
    @discardableResult
    public func remove(scope: BELPrefixKVCacheKey.PrivacyScope, boundary: String) -> Int {
        let keys = entries.keys.filter { $0.scope == scope && $0.boundary == boundary }
        for key in keys { removeValue(forKey: key) }
        return keys.count
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: false)
        bytes = 0
    }

    public func statistics() -> Metrics {
        Metrics(hits: hitCount, misses: missCount, rejected: rejectedCount,
                evictions: evictionCount, entries: entries.count, bytes: bytes)
    }

    private func removeValue(forKey key: BELPrefixKVCacheKey) {
        if let entry = entries.removeValue(forKey: key) { bytes -= entry.value.count }
    }

    private func trimIfNeeded() {
        while entries.count > configuration.maxEntries || bytes > configuration.maxBytes {
            guard let victim = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
            else { break }
            removeValue(forKey: victim)
            evictionCount += 1
        }
    }

    private var bytes: Int = 0
}
