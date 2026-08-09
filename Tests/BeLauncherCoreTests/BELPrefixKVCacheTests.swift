import Foundation
import Testing
@testable import BeLauncherCore

struct BELPrefixKVCacheTests {
    private let key = BELPrefixKVCacheKey(
        modelID: "local.core", modelRevision: "rev-1", scope: .working,
        boundary: "session-a", prefixDigest: "sha256:prefix-a")

    @Test("cache hit is isolated by privacy scope and boundary")
    func scopeIsolation() async {
        let cache = BELPrefixKVCache()
        #expect(await cache.insert(Data("private".utf8), for: key))
        #expect(await cache.value(for: key) == Data("private".utf8))

        let otherSession = BELPrefixKVCacheKey(
            modelID: key.modelID, modelRevision: key.modelRevision, scope: .working,
            boundary: "session-b", prefixDigest: key.prefixDigest)
        let longTerm = BELPrefixKVCacheKey(
            modelID: key.modelID, modelRevision: key.modelRevision, scope: .longTerm,
            boundary: "vault-a", prefixDigest: key.prefixDigest)
        #expect(await cache.value(for: otherSession) == nil)
        #expect(await cache.value(for: longTerm) == nil)
        #expect(await cache.statistics().hits == 1)
        #expect(await cache.statistics().misses == 2)
    }

    @Test("invalid keys and oversized values fail closed")
    func rejectsUnsafeEntries() async {
        let cache = BELPrefixKVCache(configuration: .init(maxBytes: 4))
        let invalid = BELPrefixKVCacheKey(
            modelID: "", modelRevision: "rev-1", scope: .working,
            boundary: "session-a", prefixDigest: "sha256:x")
        #expect(await cache.insert(Data("x".utf8), for: invalid) == false)
        #expect(await cache.insert(Data("12345".utf8), for: key) == false)
        #expect(await cache.statistics().rejected == 2)
    }

    @Test("least recently used entries are evicted within the byte budget")
    func evictsLeastRecentlyUsed() async {
        let cache = BELPrefixKVCache(configuration: .init(maxEntries: 2, maxBytes: 8))
        let second = BELPrefixKVCacheKey(
            modelID: key.modelID, modelRevision: key.modelRevision, scope: key.scope,
            boundary: key.boundary, prefixDigest: "sha256:prefix-b")
        let third = BELPrefixKVCacheKey(
            modelID: key.modelID, modelRevision: key.modelRevision, scope: key.scope,
            boundary: key.boundary, prefixDigest: "sha256:prefix-c")
        #expect(await cache.insert(Data("1111".utf8), for: key))
        #expect(await cache.insert(Data("2222".utf8), for: second))
        _ = await cache.value(for: key)
        #expect(await cache.insert(Data("3333".utf8), for: third))
        #expect(await cache.value(for: key) != nil)
        #expect(await cache.value(for: second) == nil)
        #expect(await cache.statistics().evictions == 1)
    }

    @Test("expiration removes bytes and never returns stale KV")
    func expires() async {
        let cache = BELPrefixKVCache(configuration: .init(ttl: 10))
        let start = Date(timeIntervalSince1970: 100)
        #expect(await cache.insert(Data("value".utf8), for: key, now: start))
        #expect(await cache.value(for: key, now: start.addingTimeInterval(11)) == nil)
        #expect(await cache.statistics().entries == 0)
        #expect(await cache.statistics().bytes == 0)
    }

    @Test("removing one boundary leaves another boundary untouched")
    func removesBoundary() async {
        let cache = BELPrefixKVCache()
        let other = BELPrefixKVCacheKey(
            modelID: key.modelID, modelRevision: key.modelRevision, scope: key.scope,
            boundary: "session-b", prefixDigest: key.prefixDigest)
        #expect(await cache.insert(Data("a".utf8), for: key))
        #expect(await cache.insert(Data("b".utf8), for: other))
        #expect(await cache.remove(scope: .working, boundary: "session-a") == 1)
        #expect(await cache.value(for: key) == nil)
        #expect(await cache.value(for: other) == Data("b".utf8))
    }
}
