import Foundation

/// Finding the right passages, then following the graph out from them.
///
/// Three things happen, in this order, and the third is the one that makes this a brain rather
/// than a search box:
///
/// 1. **Meaning.** The question becomes a vector and the nearest passages come back. This is what
///    lets "cuánto cobramos por el Pro" find "el precio base es 1000 euros" — no shared word.
/// 2. **Words.** BM25 over the same passages. This is what saves the vector's blind spots: an
///    invoice number, a surname the model has never seen, an exact product code. The two rankings
///    are fused by position rather than by score, because their scores live on unrelated scales.
/// 3. **Relations.** Every strong hit is walked one hop through the work graph, and whatever it is
///    attached to is pulled in behind it. Asking what was promised to Andrés has to reach a
///    commitment that came out of a meeting he was in and never mentions his name — no amount of
///    text similarity finds that, because the text genuinely does not contain the answer. An edge
///    does.
public struct Retriever: Sendable {

    /// The single Brain context boundary. Retrieval remains the implementation, while callers
    /// declare how much memory they are allowed to see instead of choosing arbitrary hit counts.
    public enum BeBrainContextProvider {
        public enum MemoryScope: String, Sendable, Equatable {
            case none
            case working
            case longTerm
        }

        public struct Selection: Sendable, Equatable {
            public let level: BELActionDefinition.BrainContextLevel
            public let scope: MemoryScope
            public let hits: [Retrieved]
            public let estimatedTokens: Int
            public let gap: String?
            public let wasTruncated: Bool

            public init(level: BELActionDefinition.BrainContextLevel,
                        scope: MemoryScope? = nil, hits: [Retrieved],
                        estimatedTokens: Int, gap: String?, wasTruncated: Bool) {
                self.level = level
                self.scope = scope ?? Self.scope(for: level)
                self.hits = hits
                self.estimatedTokens = estimatedTokens
                self.gap = gap
                self.wasTruncated = wasTruncated
            }

            private static func scope(for level: BELActionDefinition.BrainContextLevel)
                -> MemoryScope {
                switch level {
                case .b0, .b1: .none
                case .b2: .working
                case .b3: .longTerm
                }
            }
        }

        public static func retrieve(
            result: Result,
            level: BELActionDefinition.BrainContextLevel,
            tokenBudget: Int = Retriever.defaultContextTokenBudget
        ) -> Selection {
            let allowed: [Retrieved]
            switch level {
            case .b0, .b1:
                allowed = []
            case .b2:
                allowed = Array(result.hits.prefix(4))
            case .b3:
                allowed = result.hits
            }
            let bounded = Retriever.context(from: allowed, tokenBudget: tokenBudget)
            return Selection(level: level, hits: bounded.hits,
                             estimatedTokens: bounded.estimatedTokens,
                             gap: result.gap, wasTruncated: bounded.wasTruncated)
        }
    }

    public struct ContextSelection: Sendable, Equatable {
        public let hits: [Retrieved]
        public let estimatedTokens: Int
        public let wasTruncated: Bool

        public init(hits: [Retrieved], estimatedTokens: Int, wasTruncated: Bool) {
            self.hits = hits
            self.estimatedTokens = estimatedTokens
            self.wasTruncated = wasTruncated
        }
    }

    public struct Result: Sendable, Equatable {
        public let hits: [Retrieved]
        /// Named so the UI can say which half was working, instead of a spinner that means
        /// nothing: "sin modelo de embeddings" is actionable, "no encontré nada" is not.
        public let usedMeaning: Bool
        public let usedWords: Bool
        /// Why the answer is thin, when it is.
        public let gap: String?

        public init(hits: [Retrieved], usedMeaning: Bool, usedWords: Bool, gap: String? = nil) {
            self.hits = hits
            self.usedMeaning = usedMeaning
            self.usedWords = usedWords
            self.gap = gap
        }
    }

    /// How similar a passage has to be before it counts as meaning the same thing.
    ///
    /// Measured, not guessed: on a real corpus, correct answers landed between 0.50 and 0.76 and
    /// the nearest wrong passage sat below 0.46. A floor keeps the vector side from confidently
    /// filling an answer with the twelve least-irrelevant paragraphs it owns when the brain simply
    /// does not know — which is how a memory becomes untrustworthy.
    public static let meaningFloor: Float = 0.42

    /// How many hits get walked into the graph. Only the strongest: expanding everything turns one
    /// question into the whole database.
    public static let expandFrom = 3
    public static let expansionScore: Double = 0.001
    /// A conservative default for Brain prompts. Callers may lower it for a small local model.
    public static let defaultContextTokenBudget = 6_000

    /// Selects complete passages until the budget is reached. If the first passage is larger than
    /// the budget, it is shortened while retaining citation metadata. If even the citation
    /// envelope cannot fit, it fails closed rather than returning an over-budget fake guarantee.
    public static func context(
        from hits: [Retrieved], tokenBudget: Int = defaultContextTokenBudget
    ) -> ContextSelection {
        guard tokenBudget > 0 else {
            return ContextSelection(hits: [], estimatedTokens: 0, wasTruncated: !hits.isEmpty)
        }

        var selected: [Retrieved] = []
        var used = 0
        var truncated = false
        for hit in hits {
            let candidate = normalised(hit)
            let cost = estimatedTokens(for: candidate)
            if used + cost <= tokenBudget {
                selected.append(candidate)
                used += cost
                continue
            }

            guard selected.isEmpty else {
                truncated = true
                break
            }

            // Reserve room for the title, source and citation envelope before fitting text.
            let envelope = candidate.passage.title.utf8.count
                + candidate.passage.source.id.utf8.count + 67
            guard envelope + 1 <= tokenBudget * 4 else {
                truncated = true
                break
            }
            // The ellipsis and ceiling in estimatedTokens need four extra characters of room.
            let availableCharacters = max(1, (tokenBudget * 4) - envelope - 4)
            var text = String(candidate.passage.text.prefix(availableCharacters))
                .trimmingCharacters(in: .whitespaces)
            var shortenedHit: Retrieved?
            while !text.isEmpty {
                let shortened = IndexedPassage(
                    id: candidate.passage.id, source: candidate.passage.source,
                    title: candidate.passage.title, ordinal: candidate.passage.ordinal,
                    text: text + (text.count < candidate.passage.text.count ? "…" : ""),
                    occurredAt: candidate.passage.occurredAt, hasVector: candidate.passage.hasVector
                )
                let attempt = Retrieved(passage: shortened, score: candidate.score,
                                        route: candidate.route, via: candidate.via)
                if estimatedTokens(for: attempt) <= tokenBudget {
                    shortenedHit = attempt
                    break
                }
                text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard let shortenedHit else {
                truncated = true
                break
            }
            used = estimatedTokens(for: shortenedHit)
            selected.append(shortenedHit)
            truncated = true
            break
        }
        return ContextSelection(hits: selected, estimatedTokens: used, wasTruncated: truncated)
    }

    public static func estimatedTokens(for hit: Retrieved) -> Int {
        let title = IndexedPassage.label(hit.passage.title)
        return max(1, (hit.passage.text.utf8.count + title.utf8.count
                + hit.passage.source.id.utf8.count + 67 + 3) / 4)
    }

    /// Keeps an explicitly selected document inside the same predictable budget as retrieved
    /// evidence. A selected Markdown file is evidence too; it must not become an unbounded second
    /// prompt merely because it came from the UI instead of search.
    public static func boundedText(_ text: String, tokenBudget: Int) -> String {
        guard tokenBudget > 0 else { return "" }
        let limit = tokenBudget * 4
        guard text.count > limit else { return text }
        let shortened = String(text.prefix(max(1, limit - 1)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened + "…"
    }

    private static func normalised(_ hit: Retrieved) -> Retrieved {
        let title = IndexedPassage.label(hit.passage.title)
        guard title != hit.passage.title else { return hit }
        let passage = IndexedPassage(
            id: hit.passage.id, source: hit.passage.source, title: title,
            ordinal: hit.passage.ordinal, text: hit.passage.text,
            occurredAt: hit.passage.occurredAt, hasVector: hit.passage.hasVector
        )
        return Retrieved(passage: passage, score: hit.score, route: hit.route, via: hit.via)
    }

    public static func retrieve(
        query: String,
        queryVector: [Float],
        nearest: (_ limit: Int) -> [(id: String, similarity: Float)],
        words: (_ limit: Int) -> [String],
        passage: (String) -> IndexedPassage?,
        related: (IndexedSource) -> [IndexedSource] = { _ in [] },
        passages: (IndexedSource) -> [IndexedPassage] = { _ in [] },
        limit: Int = 8
    ) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            return Result(hits: [], usedMeaning: false, usedWords: false)
        }

        // Both sides are asked for more than will be shown: fusion needs depth to work with, and
        // a passage ranked eighth by meaning and second by word is often the best answer there is.
        let byMeaning = queryVector.isEmpty
            ? []
            : nearest(limit * 3).filter { $0.similarity >= meaningFloor }
        let byWords = words(limit * 3)

        let meaningIDs = byMeaning.map(\.id)
        let ranked = Semantic.fuse([meaningIDs, byWords])

        var seen = Set<String>()
        var hits: [Retrieved] = []
        let meaningSet = Set(meaningIDs)
        let wordSet = Set(byWords)

        for entry in ranked {
            guard let found = passage(entry.id) else { continue }
            let route: Retrieved.Route = switch (meaningSet.contains(entry.id), wordSet.contains(entry.id)) {
            case (true, true): .both
            case (true, false): .meaning
            default: .words
            }
            hits.append(Retrieved(passage: found, score: entry.score, route: route))
            seen.insert(entry.id)
            if hits.count >= limit { break }
        }

        // The hop. Sources already present are skipped, so expansion adds context rather than
        // repeating what was already found by other means.
        var expansions: [Retrieved] = []
        for hit in hits.prefix(expandFrom) {
            for neighbour in related(hit.passage.source) {
                for candidate in passages(neighbour) where !seen.contains(candidate.id) {
                    seen.insert(candidate.id)
                    expansions.append(Retrieved(passage: candidate, score: expansionScore,
                                                route: .related, via: hit.passage.title))
                    break   // one passage per neighbour: a hop is context, not a second search
                }
            }
        }

        let gap: String?
        if hits.isEmpty {
            gap = queryVector.isEmpty
                ? L("Nothing matches those words, and without an embedding model there is no search by meaning.")
                : L("The brain knows nothing about this yet.")
        } else if queryVector.isEmpty {
            gap = L("Words only. Searching by meaning needs an embedding model.")
        } else {
            gap = nil
        }

        return Result(hits: hits + expansions.prefix(limit / 2),
                      usedMeaning: !byMeaning.isEmpty, usedWords: !byWords.isEmpty, gap: gap)
    }

    // MARK: - The prompt

    /// Assembles retrieved passages into something a model can answer from without inventing.
    ///
    /// Passages are numbered and the instruction is explicit about citing them, because the
    /// failure everyone has seen is a fluent answer built half from the notes and half from the
    /// model's own priors, with no way to tell which sentence is which. An answer that says "no
    /// consta" is worth more than a plausible one.
    /// The instruction is in English even when the passages are not.
    ///
    /// This was written in Spanish and it cost accuracy twice over. Instruction-following is
    /// measurably better in English on every local model small enough to run on a laptop, and the
    /// grounding rules are the part that must not be ignored — an instruction to refuse is worth
    /// nothing if it is the instruction the model paraphrases away. Worse, a Spanish instruction
    /// over English passages made the model answer in Spanish about English material, which reads
    /// like a bug to the person who asked.
    ///
    /// The language of the *answer* follows the question, not the interface and not this file. A
    /// bilingual corpus produces bilingual answers, which is correct: someone who asks in Spanish
    /// about an English meeting wants the answer in Spanish and the quotes as they were written.
    public static func prompt(for question: String, hits: [Retrieved],
                              tokenBudget: Int? = nil) -> (system: String, user: String) {
        let selection = tokenBudget.map { context(from: hits, tokenBudget: $0) }
        let contextHits = selection?.hits ?? hits
        let truncation = selection?.wasTruncated == true
            ? " Some passages were truncated to fit the context budget; do not infer what is missing."
            : ""
        let system = """
        Answer using only what appears in the numbered passages. Cite the source with [n] after \
        every claim. If the passages do not contain the answer, say so in one sentence and stop. \
        Do not fill gaps with your own knowledge, do not assume, do not generalise. \
        Write the answer in the same language as the question, and quote passages in the language \
        they were written in. Be direct.\(truncation)
        """
        var lines: [String] = []
        for (index, hit) in contextHits.enumerated() {
            let when = DateFormatter.retrievalStamp().string(from: hit.passage.occurredAt)
            lines.append("[\(index + 1)] (\(hit.passage.source.kind.label) · \(hit.passage.title) · \(when))\n\(hit.passage.text)")
        }
        let user = """
        Question: \(question)

        Passages:
        \(lines.joined(separator: "\n\n"))
        """
        return (system, user)
    }
}

extension DateFormatter {
    /// Fresh each call: DateFormatter is not Sendable and a shared one would race the background
    /// indexer.
    ///
    /// The locale follows the interface language. Dates inside a prompt are read by a model, but
    /// the same stamp is shown next to a citation in the UI, and "5 Aug 2026" next to English text
    /// is the difference between a product and a port.
    static func retrievalStamp() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Loc.language.locale
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }
}
