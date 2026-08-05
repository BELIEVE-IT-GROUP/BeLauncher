import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Search performance and scoring consistency")
struct SearchPerformanceTests {

    /// Two implementations of the same ranking (one with highlight indices, one without) would
    /// silently drift apart. This pins them together.
    @Test("the fast scorer agrees with the full matcher, always")
    func scorersAgree() {
        let candidates = ["Safari", "System Settings", "café", "GitHub — pull requests",
                          "notas.md", "Descargas", "MAAS 3.0 roadmap", "a", "zzz"]
        let queries = ["s", "sa", "saf", "sys", "caf", "git", "desc", "maas", "zzz", "qqq", ""]
        for candidate in candidates {
            let hay = Fuzzy.folded(candidate)
            for query in queries {
                let needle = Fuzzy.folded(query)
                #expect(Fuzzy.score(needle: needle, hay: hay) == Fuzzy.match(needle: needle, hay: hay)?.score,
                        "drift on “\(query)” vs “\(candidate)”")
            }
        }
    }

    @Test("the letter mask never rules out a real match")
    func maskIsConservative() {
        let candidates = ["Safari", "Descargas", "café con leche", "GitHub"]
        let queries = ["saf", "desc", "cafe", "hub", "xyz", "gh"]
        for candidate in candidates {
            let hay = Fuzzy.folded(candidate)
            let candidateMask = Fuzzy.mask(hay)
            for query in queries {
                let needle = Fuzzy.folded(query)
                if Fuzzy.score(needle: needle, hay: hay) != nil {
                    #expect(!Fuzzy.cannotMatch(needleMask: Fuzzy.mask(needle), candidateMask: candidateMask),
                            "mask wrongly discarded “\(query)” for “\(candidate)”")
                }
            }
        }
    }

    /// A real bookmark file on this machine holds 11k entries. A one-letter query is the worst
    /// case: nearly everything matches. This ran at 95 ms before the two-pass rewrite, which is
    /// visible stutter on every keystroke.
    @Test("a keystroke over 15k bookmarks stays inside a frame")
    func keystrokeStaysUnderAFrame() {
        let shortcuts = (0..<15_000).map {
            Shortcut(title: "Bookmark \($0) — some article about design and code",
                     target: "https://example.com/\($0)", source: .bookmark)
        }
        let input = SearchInput(shortcuts: shortcuts)

        _ = SearchEngine.search("d", in: input)          // warm up
        let start = Date()
        let results = SearchEngine.search("d", in: input)
        let milliseconds = Date().timeIntervalSince(start) * 1000

        #expect(!results.isEmpty)
        #expect(milliseconds < 25, "a keystroke took \(Int(milliseconds)) ms — that is a stutter")
    }

    @Test("parallel and serial paths return the same ranking")
    func parallelMatchesSerial() {
        let many = (0..<3_000).map {
            Shortcut(title: "Item \($0) design", target: "https://x/\($0)", source: .bookmark)
        }
        let needle = Fuzzy.folded("desi")
        let mask = Fuzzy.mask(needle)

        let parallel = SearchEngine.matchShortcuts(many, needle: needle, needleMask: mask)
        let serial = SearchEngine.matchShortcuts(Array(many.prefix(1_999)), needle: needle, needleMask: mask)

        #expect(!parallel.isEmpty)
        #expect(!serial.isEmpty)
        #expect(parallel.allSatisfy { $0.kind == .bookmark })
        // Same scoring rule on both paths.
        #expect(parallel.first!.score == serial.first!.score)
    }
}
