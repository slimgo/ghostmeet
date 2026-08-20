//
//  PronunciationBrackets.swift
//  GhostMeet
//

import Foundation

/// Tidies up pronunciation brackets — what the prompt asks for and does not
/// always land.
///
/// In a Russian conversation the model is told to follow every Latin term with a
/// pronunciation in brackets: `nginx (энджин-икс)`. The user reads the suggestion
/// **aloud** and says the bracket's contents instead of the Latin, which cannot
/// be read aloud inside a Russian sentence.
///
/// **Why the remainder is fixed in code rather than by another line of prompt.**
/// The prompt already says this outright and with an example; this project has
/// recorded that prohibitions get obeyed to the letter while examples get
/// executed, so a tenth wording of one rule would loosen its neighbours sooner
/// than it would land this one. And whether the character to the left of a
/// bracket is Latin needs no judgement — parsing answers it. What is mechanical
/// has no business being decided by a prompt.
enum PronunciationBrackets {

    /// Fixes text that **may still be half-written**.
    ///
    /// A suggestion arrives as a stream and the markup is parsed afresh on every
    /// fragment, so the rule is single and strict: only what is already complete
    /// gets touched. An unclosed bracket, a cut-off word, a bracket still being
    /// typed — none of them are touched at all. Corrupting half-arrived text is
    /// worse than leaving it unfixed.
    static func fixed(_ text: String) -> String {
        guard text.contains("(") else { return text }
        var result = ""
        result.reserveCapacity(text.count)

        var rest = Substring(text)
        while let open = rest.firstIndex(of: "(") {
            guard let close = rest[rest.index(after: open)...].firstIndex(of: ")") else {
                // The bracket is not closed yet: either the text is unfinished
                // or it never will be. Either way the rest is passed through.
                result += rest
                return result
            }
            let inside = rest[rest.index(after: open)..<close]
            let before = rest[..<open]

            guard isGloss(inside) else {
                result += rest[..<rest.index(after: close)]
                rest = rest[rest.index(after: close)...]
                continue
            }

            let after = rest[rest.index(after: close)...]
            if latinTerm(endingAt: before) != nil {
                // Latin on the left — the bracket is exactly where it belongs.
                result += rest[..<rest.index(after: close)]
                rest = after
            } else if let term = latinTerm(startingAfter: after) {
                // «(кубернетис) Kubernetes» — an inverted pair, and it is checked
                // **before** the duplicate: this one has Cyrillic on its left too
                // («Берём»), so the order of the checks decides whether the pair
                // gets reordered or swallowed.
                //
                // The order matters to the reader as well: the bracket's contents
                // are said **instead of** the Latin, not before it, or the term is
                // spoken twice.
                result += before
                result += term.text
                result += " (\(inside))"
                rest = term.rest
            } else if repeatsWord(endingAt: before, inside: inside) {
                // «кластер (кластер)» — a gloss on a Russian word that repeats it.
                // There is nothing to read: the user would say the word twice.
                //
                // **Duplicates only, and that is necessity rather than caution.**
                // On the single signal "Cyrillic inside brackets" a gloss is
                // indistinguishable from an ordinary aside — «Это важно (и вот
                // почему)» — and an aside must not be thrown away: it carries
                // meaning. Matching the word on the left *is* the defect, and
                // nothing besides it.
                result += trimmedTrailingSpace(before)
                rest = after
            } else {
                result += rest[..<rest.index(after: close)]
                rest = after
            }
        }
        result += rest
        return result
    }

    // MARK: -

    /// A gloss is a bracket holding nothing but Cyrillic, hyphens and spaces.
    ///
    /// Narrow on purpose. `O(n log n)` is not a gloss, and neither is «(и это
    /// важно)» after a Russian phrase: the first would break, the second would be
    /// lost. Only what is certainly a pronunciation gets touched.
    private static func isGloss(_ inside: Substring) -> Bool {
        guard !inside.isEmpty else { return false }
        return inside.allSatisfy { character in
            character.isCyrillic || character == "-" || character == " " || character == "\u{2011}"
        }
    }

    /// Whether the bracket repeats the word standing in front of it.
    ///
    /// Compared without case or hyphens: «Кластер (кластер)» and «хеш-мапа
    /// (хешмапа)» are the same defect.
    private static func repeatsWord(endingAt before: Substring, inside: Substring) -> Bool {
        let word = before.reversed().drop(while: \.isWhitespace).prefix { $0.isCyrillic }
        guard !word.isEmpty else { return false }
        return normalised(String(word.reversed())) == normalised(String(inside))
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0 != "-" && $0 != " " && $0 != "\u{2011}" }
    }

    private static func latinTerm(endingAt before: Substring) -> Substring? {
        let trimmed = before.reversed().drop(while: \.isWhitespace)
        guard let first = trimmed.first, first.isLatinTerm else { return nil }
        return before
    }

    /// The Latin term at the start of the remainder, with what follows it.
    private static func latinTerm(startingAfter rest: Substring) -> (text: Substring, rest: Substring)? {
        let start = rest.drop(while: \.isWhitespace)
        guard let first = start.first, first.isLatinTerm else { return nil }
        let end = start.firstIndex { !$0.isLatinTerm } ?? start.endIndex
        // A word reaching exactly the end of the text may be unfinished: in a
        // stream «Kub» would become a term, and a fragment later it is
        // «Kubernetes».
        guard end != start.endIndex else { return nil }
        return (start[..<end], start[end...])
    }

    private static func trimmedTrailingSpace(_ text: Substring) -> Substring {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous] == " " else { break }
            end = previous
        }
        return text[..<end]
    }
}

private extension Character {
    var isCyrillic: Bool {
        unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    /// What a Latin term may contain: letters, digits and the punctuation that
    /// makes up names from code — `created_at`, `large-v3`, `Vue.js`.
    var isLatinTerm: Bool {
        isASCII && (isLetter || isNumber || self == "_" || self == "-" || self == ".")
    }
}
