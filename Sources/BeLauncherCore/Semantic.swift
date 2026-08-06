import Foundation
import NaturalLanguage

/// Meaning, rather than letters.
///
/// Everything the launcher searched until now compared characters: type "cuánto cobramos por el
/// Pro" and a memory that reads "el precio base es 1000 EUR" never appears, because the two share
/// no word. That is not a memory, it is a filing cabinet with a fuzzy label reader — and it is
/// exactly the gap between what a brain is supposed to do and what a folder does.
///
/// The unit here is the *passage*, not the file. A decision is three lines inside a note about
/// something else; retrieving the whole note buries it, and answering from the whole note makes
/// the model read four pages to quote one sentence. Passages are what get embedded, ranked and
/// cited, and every one of them remembers which object it was cut from.
public enum Semantic {

    // MARK: - Cutting text into passages

    /// Roughly a paragraph. Small enough that a hit points at the sentence that matters, large
    /// enough that a sentence still carries its context — a passage reading "sube a 59" with the
    /// subject two sentences earlier is a hit nobody can use.
    public static let targetCharacters = 700
    /// Passages overlap so a statement split across a boundary survives in one of the two halves.
    public static let overlapCharacters = 140
    /// Below this a passage is a fragment: a heading, a stray line. Embedding those fills the
    /// index with near-identical noise that outranks real answers.
    public static let minimumCharacters = 40

    public struct Passage: Sendable, Equatable {
        /// Position within its source, so citations can be shown in reading order.
        public let ordinal: Int
        public let text: String

        public init(ordinal: Int, text: String) {
            self.ordinal = ordinal
            self.text = text
        }
    }

    /// Splits on sentence ends first and only falls back to a hard cut when a single sentence is
    /// longer than a passage — which happens with pasted logs and minified anything.
    public static func passages(of text: String, target: Int = targetCharacters,
                                overlap: Int = overlapCharacters) -> [Passage] {
        let clean = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        guard clean.count > target else {
            return clean.count >= minimumCharacters ? [Passage(ordinal: 0, text: clean)] : []
        }

        var result: [Passage] = []
        var current = ""
        var carry = ""

        func flush() {
            let body = (carry + current).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count >= minimumCharacters {
                result.append(Passage(ordinal: result.count, text: body))
            }
            // The tail of what was just emitted becomes the head of the next one.
            carry = overlap > 0 ? String(current.suffix(overlap)) : ""
            current = ""
        }

        for sentence in sentences(of: clean) {
            if current.count + sentence.count > target, !current.isEmpty { flush() }
            if sentence.count > target {
                // One sentence longer than a whole passage: cut it by length, since there is no
                // boundary left to respect.
                var rest = Substring(sentence)
                while !rest.isEmpty {
                    let piece = rest.prefix(target)
                    rest = rest.dropFirst(piece.count)
                    current = String(piece)
                    flush()
                }
                continue
            }
            current += sentence
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flush() }
        return result
    }

    /// Sentence boundaries, keeping the punctuation and the whitespace attached so the passages
    /// re-assemble into the original text.
    ///
    /// This started as a hand-written scan for full stops and a test caught it splitting
    /// "Sr. García" in two — which would cut a passage in the middle of a person's name and hand
    /// the retriever a fragment. The system tokenizer already knows every abbreviation in the
    /// languages it supports, in every language it supports, which is not a table worth
    /// maintaining by hand for a launcher.
    static func sentences(of text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        // The language has to be stated. Left to guess, the tokenizer gets a short line wrong in
        // exactly the way it is supposed to prevent: "Hablé con el Sr. García" came back as two
        // sentences until this line existed. Detection can decline to answer on a fragment, so
        // Spanish is the floor — it is the language this app is used in.
        tokenizer.setLanguage(NLLanguageRecognizer.dominantLanguage(for: text) ?? .spanish)
        var result: [String] = []
        var cursor = text.startIndex

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // From the end of the previous sentence, so the whitespace between them travels with
            // the text and the passages still concatenate back into the original.
            result.append(String(text[cursor..<range.upperBound]))
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex { result.append(String(text[cursor...])) }
        return result.isEmpty ? [text] : result
    }

    // MARK: - Vectors

    /// Cosine similarity, assuming both sides are already unit length.
    ///
    /// Vectors are normalised once when they are written, which turns every comparison at query
    /// time into a dot product. With tens of thousands of passages that is the difference between
    /// a search that feels instant and one that does not.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total: Float = 0
        for index in a.indices { total += a[index] * b[index] }
        return total
    }

    /// Scales a vector to length 1. A zero vector stays zero rather than becoming NaN, which is
    /// what an empty or unembeddable passage produces.
    public static func normalise(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        let length = sqrt(sum)
        guard length > 1e-9 else { return vector }
        return vector.map { $0 / length }
    }

    /// Averages the per-token vectors a contextual model produces into one vector for the passage.
    public static func pool(_ vectors: [[Float]]) -> [Float] {
        guard let width = vectors.first?.count, width > 0 else { return [] }
        var total = [Float](repeating: 0, count: width)
        var counted = 0
        for vector in vectors where vector.count == width {
            for index in 0..<width { total[index] += vector[index] }
            counted += 1
        }
        guard counted > 0 else { return [] }
        for index in total.indices { total[index] /= Float(counted) }
        return normalise(total)
    }

    // MARK: - Storage form

    /// Vectors go to SQLite as raw little-endian Float32. JSON would triple the size and cost a
    /// parse per row on every query; a BLOB is read straight back into memory.
    public static func encode(_ vector: [Float]) -> Data {
        var copy = vector.map { $0.bitPattern.littleEndian }
        return copy.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let start = index * 4
            var bits: UInt32 = 0
            for byte in 0..<4 {
                bits |= UInt32(data[data.startIndex + start + byte]) << (8 * UInt32(byte))
            }
            result[index] = Float(bitPattern: UInt32(littleEndian: bits))
        }
        return result
    }

    // MARK: - Combining two rankings

    /// Reciprocal rank fusion.
    ///
    /// Meaning search and word search fail in opposite directions: the vector side misses an exact
    /// product code or a surname it has never seen, the keyword side misses every paraphrase.
    /// Fusing them by *rank* rather than by score is what makes the combination safe — the two
    /// scores are on scales that have nothing to do with each other, so averaging them lets
    /// whichever engine happens to produce bigger numbers decide the outcome.
    public static let fusionConstant: Double = 60

    public static func fuse(_ rankings: [[String]], weights: [Double] = []) -> [(id: String, score: Double)] {
        var totals: [String: Double] = [:]
        for (listIndex, ranking) in rankings.enumerated() {
            let weight = listIndex < weights.count ? weights[listIndex] : 1
            for (position, id) in ranking.enumerated() {
                totals[id, default: 0] += weight / (fusionConstant + Double(position + 1))
            }
        }
        return totals
            .map { (id: $0.key, score: $0.value) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }
}

import CryptoKit

extension Semantic {
    /// A content fingerprint, so an unchanged source keeps its vectors instead of being
    /// re-embedded on every pass. Cryptographic rather than a cheap hash because a collision here
    /// means silently serving stale text as if it were current.
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
