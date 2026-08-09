# X3: privacy-scoped prefix/KV cache

Status: **implemented as an in-memory core primitive; LiteRT provider integration remains gated**.

## Contract

`BELPrefixKVCache` stores opaque `Data` only in an actor. A caller must supply all of the following
to address an entry:

- schema version;
- model ID and exact model revision;
- privacy scope (`working` or `longTerm`);
- a non-empty privacy boundary (session or vault identity);
- a digest of the prefix, never the prefix itself.

There is no `.none` scope, no disk persistence, and no fallback that broadens a boundary. An invalid
key, empty value, oversized value, disabled capacity, expired entry, or missing entry fails closed.
The cache is an optimization only: a miss must execute the normal model path.

## Resource and invalidation policy

The default cache is capped at 32 entries and 64 MiB with a 15-minute TTL. Entries are evicted by
least-recently-used order and are removed by byte count as well as entry count. A caller can remove
one scope/boundary without touching another, or clear the entire process cache. Model revision and
schema version are part of the key, so a model update cannot reuse old KV state.

Metrics contain only counters and sizes: hits, misses, rejected inserts, evictions, entry count and
bytes. No prompt, token, path, source ID or digest is emitted by the metrics API.

## Evidence

`Tests/BeLauncherCoreTests/BELPrefixKVCacheTests.swift` covers five production invariants:

1. working and long-term/session boundaries cannot read one another;
2. malformed and oversized entries are rejected;
3. LRU and byte caps evict the least recently used entry;
4. expired data is not returned and its bytes are released;
5. removing one boundary leaves another boundary available.

The focused command passed on macOS arm64:

```sh
swift test --filter BELPrefixKVCacheTests
```

## Integration gate

The cache is not wired to the current Ollama/LM Studio providers and does not claim to accelerate
them. X2 must first prove a real LiteRT model and expose a stable prefix/KV serialization contract.
Only then may an adapter translate runtime KV bytes into this primitive, with a benchmark proving
that cache hits preserve output and that a scope switch produces a miss. Until those checks exist,
the production path remains ordinary decoding.
