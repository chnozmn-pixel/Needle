import Foundation
import NaturalLanguage

/// Expands an Everything-style `semantic:` query into related literal terms.
///
/// Apple's word embedding model is used only while parsing the query, so the
/// search itself keeps using the in-memory n-gram posting lists and stays
/// interactive even on very large indexes. Sentence-embedding distance was
/// measured at roughly 25 ms per comparison, which is far too slow to run for
/// every indexed entry; word neighbours give a bounded, useful expansion with
/// no per-entry cost.
///
/// Only the English embedding model ships with macOS. For other languages the
/// original text is preserved and semantic expansion degrades to a literal
/// search rather than failing.
public enum SemanticSearch {

    /// Whether the system provides a word embedding model.
    public static var isAvailable: Bool {
        NLEmbedding.wordEmbedding(for: .english) != nil
    }

    /// Returns the literal query text followed by related single-word terms.
    ///
    /// The result is deterministic for a given string and model: the original
    /// phrase is always first, neighbours are appended in model order, and
    /// duplicates are removed case-insensitively.
    public static func expand(_ text: String, maximumNeighborsPerWord: Int = 6) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var terms: [String] = [trimmed]
        var seen = Set([trimmed.lowercased()])

        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return terms }

        let words = significantWords(in: trimmed)
        var remaining = maximumNeighborsPerWord * max(1, words.count)
        let cap = 1 + max(6, maximumNeighborsPerWord * max(1, words.count))

        for word in words {
            guard remaining > 0 else { break }
            for (neighbor, _) in embedding.neighbors(for: word, maximumCount: maximumNeighborsPerWord) {
                let clean = neighbor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard clean.utf8.count >= 3,
                      clean.allSatisfy({ $0.isLetter }),
                      seen.insert(clean).inserted else { continue }
                terms.append(clean)
                remaining -= 1
                if remaining <= 0 || terms.count >= cap { break }
            }
            if terms.count >= cap { break }
        }
        return terms
    }

    /// Splits a phrase into words that are useful to a word embedding model.
    private static func significantWords(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter {
                current.append(ch)
            } else if !current.isEmpty {
                append(current, to: &words)
                current = ""
            }
        }
        if !current.isEmpty { append(current, to: &words) }
        return words
    }

    private static func append(_ word: String, to words: inout [String]) {
        guard word.utf8.count >= 3, !words.contains(word) else { return }
        words.append(word)
    }
}
