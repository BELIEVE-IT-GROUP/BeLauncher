import Foundation

/// Turning retrieved passages into rows for the command bar.
///
/// Kept apart from the retriever so the ranking stays testable without any notion of a list, and
/// apart from the search engine because these rows arrive late — the passage index answers in
/// tens of milliseconds but the query still has to be embedded first, and a launcher that waits
/// for that before drawing anything is a launcher that feels slow at the one thing it must never
/// feel slow at.
public enum RecallResults {

    /// A passage becomes a row whose title is where it came from and whose subtitle is the part
    /// that matched — the opposite of the usual arrangement, because "Reunión con Acme" tells you
    /// nothing and the sentence about the price is the entire reason the row is there.
    public static func rows(from result: Retriever.Result, limit: Int = 5) -> [SearchResult] {
        result.hits.prefix(limit).enumerated().map { position, hit in
            SearchResult(
                id: "recall-\(hit.passage.id)",
                kind: .recall,
                title: excerpt(hit.passage.text),
                subtitle: subtitle(for: hit),
                // Below anything typed and matched directly: someone who typed an app's name wants
                // the app, even when the brain has something eloquent to say about it.
                score: 40 - position,
                matched: [],
                // The full passage, not its id: the useful thing to do with a recalled
                // sentence is take it somewhere, and a row whose Enter copies an internal
                // identifier is a row that lies about what it does.
                payload: hit.passage.text
            )
        }
    }

    /// The sentence, not the paragraph. Long enough to be an answer, short enough for one row.
    static func excerpt(_ text: String, limit: Int = 120) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        // Cut on a word so the row does not end mid-syllable.
        let clipped = String(flattened.prefix(limit))
        guard let space = clipped.lastIndex(of: " ") else { return clipped + "…" }
        return String(clipped[clipped.startIndex..<space]) + "…"
    }

    /// Says where it came from and why it surfaced.
    ///
    /// The route is shown on purpose. "Por significado" against a passage that shares no word with
    /// what was typed is the moment someone understands the thing is not grepping — and when the
    /// row is wrong, it is also the explanation for why a search returned something surprising.
    static func subtitle(for hit: Retrieved) -> String {
        var parts = [hit.passage.source.kind.label]
        if !hit.passage.title.isEmpty, hit.passage.title != hit.passage.text {
            parts.append(String(hit.passage.title.prefix(40)))
        }
        parts.append(reason(hit))
        return parts.joined(separator: " · ")
    }

    static func reason(_ hit: Retrieved) -> String {
        switch hit.route {
        case .meaning: "por significado"
        case .words: "por palabras"
        case .both: "coincide en todo"
        case .related: "relacionado con \(hit.via ?? "otro resultado")"
        }
    }
}
