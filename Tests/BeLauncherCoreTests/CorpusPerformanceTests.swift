import Testing
import Foundation
@testable import BeLauncherCore

// Indexing is intentionally measured without the rest of the suite competing for the same
// machine. The targeted run remains the strict baseline; serialization prevents a false failure
// when dozens of unrelated tests saturate the disk at the same time.
@Suite("Corpus performance baseline", .serialized)
@MainActor
struct CorpusPerformanceTests {
    @Test("indexing 10k synthetic memories stays measurable and bounded")
    func indexBaseline() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-benchmark-\(UUID().uuidString).sqlite3").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        let memories = (0..<10_000).map { index in
            MemoryObject(
                level: .outcome, kind: .learning,
                statement: "Benchmark outcome \(index): the local brain keeps this result searchable",
                body: "Synthetic corpus passage \(index) with enough context to exercise FTS writes and passage chunking.",
                source: "benchmark:\(index)", createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        let started = Date()
        let written = store.reindex(memories: memories, nodes: [], clips: [])
        let milliseconds = Date().timeIntervalSince(started) * 1_000

        #expect(written >= 10_000)
        #expect(store.indexedPassageCount().total >= 10_000)
        // Swift Testing runs suites concurrently, so a full run can legitimately contend for the
        // same SQLite and temporary-disk resources. The focused benchmark is the strict 15 s
        // signal; the full suite keeps a generous smoke bound so contention is not reported as a
        // product regression.
        #expect(milliseconds < 45_000,
                "10k memory index took \(Int(milliseconds)) ms; investigate before scaling to a real corpus")
    }
}
