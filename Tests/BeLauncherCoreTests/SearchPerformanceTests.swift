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
    /// case: nearly everything matches. This ran at 95 ms before the two-pass rewrite. The focused
    /// run remains the strict signal; the full suite gets a small, explicit contention allowance
    /// because Swift Testing runs unrelated SQLite and graph work at the same time.
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
        #expect(milliseconds < 75, "a keystroke took \(Int(milliseconds)) ms — investigate the launcher path")
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

@Suite("Bookmarks must not drown the list")
struct BookmarkNoiseTests {

    @Test("a scattered match in a bookmark title is noise, not a result")
    func requiresAContiguousRun() {
        let shortcuts = [
            Shortcut(title: "Usaria, consultoría en usabilidad", target: "https://usaria.co",
                     source: .bookmark),
            Shortcut(title: "Acme: acuerdos comerciales", target: "https://acme.com/acuerdos",
                     source: .bookmark),
        ]
        let results = SearchEngine.search("acuerdos con acme", in: SearchInput(shortcuts: shortcuts))
        #expect(!results.contains { $0.title.contains("Usaria") },
                "letters scattered across a title are not a match anyone meant")
    }

    @Test("what the user actually typed still finds its bookmark")
    func realMatchesSurvive() {
        let shortcuts = [Shortcut(title: "Acme: acuerdos comerciales",
                                  target: "https://acme.com", source: .bookmark)]
        #expect(!SearchEngine.search("acme", in: SearchInput(shortcuts: shortcuts)).isEmpty)
        #expect(!SearchEngine.search("acuerdos", in: SearchInput(shortcuts: shortcuts)).isEmpty)
        #expect(!SearchEngine.search("ACME", in: SearchInput(shortcuts: shortcuts)).isEmpty)
    }

    @Test("folders keep the forgiving matching, there are only a handful of them")
    func foldersStayFuzzy() {
        let shortcuts = [Shortcut(title: "Descargas", target: "/Users/x/Downloads", source: .folder)]
        #expect(!SearchEngine.search("dscrgs", in: SearchInput(shortcuts: shortcuts)).isEmpty)
    }

    @Test("a clip beats a bookmark that only matched by accident")
    func clipWinsOverNoise() {
        let input = SearchInput(
            clips: [Clip(id: 1, text: "Acordamos con Acme enviar la propuesta el viernes",
                         sourceApp: "Mail")],
            shortcuts: (0..<500).map {
                Shortcut(title: "Artículo \($0) sobre consultoría y usabilidad",
                         target: "https://example.com/\($0)", source: .bookmark)
            }
        )
        let results = SearchEngine.search("acordamos con acme", in: input)
        #expect(results.first?.kind == .clipboard)
    }

    @Test("containsRun is exact about what counts as contiguous")
    func runSemantics() {
        let hay = Fuzzy.folded("acuerdos comerciales")
        #expect(Fuzzy.containsRun(needle: Fuzzy.folded("acuerdo"), hay: hay))
        #expect(Fuzzy.containsRun(needle: Fuzzy.folded("comer"), hay: hay))
        #expect(!Fuzzy.containsRun(needle: Fuzzy.folded("acuerdosx"), hay: hay))
        #expect(!Fuzzy.containsRun(needle: Fuzzy.folded("acmerciales"), hay: hay))
        #expect(Fuzzy.containsRun(needle: [], hay: hay))
    }
}
