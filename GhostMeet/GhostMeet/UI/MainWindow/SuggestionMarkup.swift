//
//  SuggestionMarkup.swift
//  GhostMeet
//

import CoreGraphics
import Foundation
import SwiftUI

/// One piece of a suggestion as the card draws it.
///
/// The kinds are the ones an interview answer is actually made of — a paragraph,
/// a list of three things, a fragment of code — and no more than that. Anything
/// richer would be markup the model rarely emits and the user never has time to
/// read on a call.
nonisolated struct SuggestionBlock: Equatable, Sendable, Identifiable {

    nonisolated enum Kind: Equatable, Sendable {
        case paragraph
        /// A `#`-headed line. The level is kept, but the card draws one weight for
        /// all of them: the window is 420 points wide and a hierarchy of six type
        /// sizes in it would be decoration, not structure.
        case heading(level: Int)
        /// A list item. `marker` is what gets drawn — «•» for a bullet, «3.» for a
        /// numbered one — so the view never has to know which of the two it is.
        case listItem(marker: String, indent: Int)
        /// A fenced block, kept verbatim. `isClosed` is false while the closing
        /// fence has not arrived yet, which during streaming is most of the time.
        case code(language: String, isClosed: Bool)
    }

    /// Position in the answer. Stable while the answer grows, because blocks are
    /// only ever appended — which is what keeps `ForEach` from rebuilding the
    /// whole card on every fragment.
    let id: Int

    let kind: Kind

    /// Inline markdown for everything except code, which is verbatim text.
    let text: String

    var isCode: Bool {
        if case .code = kind { return true }
        return false
    }
}

/// Turns what the model wrote into blocks the card can draw.
///
/// The model answers in markdown whether or not it is asked to, and a technical
/// answer read as raw text — asterisks, backticks, a fragment of code in the same
/// proportional font as the prose — is hardest to read exactly when it has to be
/// read fastest.
///
/// **Everything here has to survive being handed half an answer.** The card is
/// re-parsed on every fragment, so this type sees each prefix of the text in
/// turn: a fence with no closing fence, a `**` with nothing after it yet, a list
/// item that is one dash so far. The rule is that a prefix must never look
/// broken — an unterminated fence is already a code block, and a delimiter that
/// has not been closed yet is closed here rather than shown as punctuation.
///
/// No parser is taken in for this. `AttributedString` does inline markdown out of
/// the box, blocks are a line-by-line split, and a BYOK app with no backend has
/// no business shipping a markdown library to make its answers prettier.
nonisolated enum SuggestionMarkup {

    // MARK: - Blocks

    /// Splits an answer — whole or half-written — into what the card draws.
    static func blocks(of source: String) -> [SuggestionBlock] {
        var blocks: [SuggestionBlock] = []
        var paragraph: [String] = []

        // Code being collected, and the fence that opened it. `nil` means we are
        // outside a fence.
        var code: [String]?
        var fence = 0
        var language = ""

        func flushParagraph() {
            defer { paragraph.removeAll() }
            // Balanced before the emptiness check, not after: a paragraph that is
            // nothing but the delimiter the model is halfway through typing
            // becomes empty here, and an empty paragraph would be a blank line
            // opening and closing in the middle of the card.
            // Скобки с произношением правятся здесь — там же, где абзац, и
            // только здесь: в блок кода этот путь не заходит, а внутри кода
            // скобка часть синтаксиса, и любая правка ломает пример.
            let text = PronunciationBrackets.fixed(balanced(paragraph.joined(separator: "\n")))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            blocks.append(SuggestionBlock(id: blocks.count, kind: .paragraph, text: text))
        }

        func flushCode(isClosed: Bool) {
            guard var lines = code else { return }
            code = nil
            if !isClosed {
                // Half a closing fence is a fence being typed, not a line of code.
                if let last = lines.last, isPartialFence(last, opened: fence) {
                    lines.removeLast()
                }
                // Nor is the newline that has arrived ahead of the next line: left
                // in, it grows the box by a blank line on every line break, which
                // during streaming is a box that twitches. A blank line inside the
                // code appears as soon as something follows it, and a closed block
                // keeps whatever the model wrote, blank lines included.
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    lines.removeLast()
                }
            }
            blocks.append(
                SuggestionBlock(
                    id: blocks.count,
                    kind: .code(language: language, isClosed: isClosed),
                    text: lines.joined(separator: "\n")
                )
            )
        }

        for line in lines(of: source) {
            if code != nil {
                if closesFence(line, opened: fence) {
                    flushCode(isClosed: true)
                } else {
                    code?.append(line)
                }
                continue
            }

            if let opening = openingFence(line) {
                flushParagraph()
                fence = opening.length
                language = opening.language
                code = []
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(line) {
                flushParagraph()
                blocks.append(
                    SuggestionBlock(
                        id: blocks.count,
                        kind: .heading(level: heading.level),
                        text: PronunciationBrackets.fixed(balanced(heading.text))
                    )
                )
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                blocks.append(
                    SuggestionBlock(
                        id: blocks.count,
                        kind: .listItem(marker: item.marker, indent: item.indent),
                        text: PronunciationBrackets.fixed(balanced(item.text))
                    )
                )
                continue
            }

            paragraph.append(line)
        }

        flushParagraph()
        // A fence with nothing to close it is the normal mid-stream state, not an
        // error: the block is drawn as code from the first line inside it, and the
        // closing fence — when it comes — changes nothing the user can see.
        flushCode(isClosed: false)
        return blocks
    }

    private static func lines(of source: String) -> [String] {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    // MARK: - Line shapes

    /// A line that opens a fenced block, and the info string on it.
    private static func openingFence(_ line: String) -> (length: Int, language: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ticks = leadingRun(of: "`", in: trimmed)
        guard ticks >= 3 else { return nil }
        let language = String(trimmed.dropFirst(ticks)).trimmingCharacters(in: .whitespaces)
        // An info string with a backtick in it is not a fence, by CommonMark and
        // by common sense: it is prose that happens to contain code.
        guard !language.contains("`") else { return nil }
        return (ticks, language)
    }

    /// Whether this line closes a fence of the given length: backticks and
    /// nothing else.
    private static func closesFence(_ line: String, opened: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ticks = leadingRun(of: "`", in: trimmed)
        return ticks >= opened && ticks == trimmed.count
    }

    /// Whether this is the beginning of a closing fence, arrived one backtick at
    /// a time.
    private static func isPartialFence(_ line: String, opened: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ticks = leadingRun(of: "`", in: trimmed)
        return ticks > 0 && ticks < opened && ticks == trimmed.count
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = leadingRun(of: "#", in: trimmed)
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// A bullet or a numbered item, with what should be drawn in front of it.
    ///
    /// The marker has to be followed by a space, which is what keeps `**жирный**`
    /// at the start of a line from being read as a bullet and `---` from being
    /// read as one either.
    private static func listItem(_ line: String) -> (marker: String, indent: Int, text: String)? {
        let spaces = leadingRun(of: " ", in: line)
        var rest = Substring(line).dropFirst(spaces)
        // Two spaces per level is the usual nesting; deeper than two levels the
        // window has no room for, so it flattens there.
        let indent = min(spaces / 2, 2)

        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            return ("•", indent, String(after.dropFirst()))
        }

        var digits = ""
        while let first = rest.first, first.isNumber, digits.count < 3 {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let separator = rest.first, separator == "." || separator == ")" else {
            return nil
        }
        let after = rest.dropFirst()
        guard after.first == " " else { return nil }
        return (digits + ".", indent, String(after.dropFirst()))
    }

    private static func leadingRun(of character: Character, in text: some StringProtocol) -> Int {
        var count = 0
        for current in text {
            guard current == character else { break }
            count += 1
        }
        return count
    }

    // MARK: - Half-written inline markup

    /// Closes the delimiters the model has opened but not yet closed, and drops
    /// the one it is in the middle of typing.
    ///
    /// This is what makes the streaming answer readable rather than a text with
    /// punctuation crawling through it. Without it every emphasis and every inline
    /// code span shows its asterisks and backticks for as long as it takes the
    /// model to write the closing pair — which at reading speed is most of the
    /// time the fragment is on screen.
    ///
    /// Two rules keep it from inventing markup that is not there:
    ///
    /// - A run only opens if a non-space follows it. `O(n * log n)` therefore
    ///   stays multiplication; an asterisk closing an emphasis needs a non-space
    ///   before it for the same reason. Both are CommonMark's flanking rule, cut
    ///   down to the part that matters here.
    /// - A run at the very end of the text that opened nothing is dropped rather
    ///   than left on screen: it is a delimiter the model is in the middle of
    ///   typing, and half of `**` is not punctuation the user asked to see.
    static func balanced(_ text: String) -> String {
        let characters = Array(text)
        // Delimiters opened and not yet closed, innermost last.
        var open: [String] = []
        // Where a trailing run sits that neither opened nor closed anything. Only
        // ever set for a run that ends the text, so it needs no resetting.
        var danglingTail: Int?
        var index = 0

        while index < characters.count {
            let character = characters[index]
            guard character == "`" || character == "*" else {
                index += 1
                continue
            }

            var length = 1
            while index + length < characters.count, characters[index + length] == character {
                length += 1
            }
            let end = index + length
            let marker = String(repeating: character, count: length)
            let after: Character? = end < characters.count ? characters[end] : nil
            let before: Character? = index > 0 ? characters[index - 1] : nil
            let insideCode = open.last?.first == "`"

            if character == "`" {
                if insideCode, open.last == marker {
                    open.removeLast()
                } else if insideCode {
                    // A run of a different length inside a code span is literal.
                    if after == nil { danglingTail = index }
                } else if after != nil {
                    open.append(marker)
                } else {
                    danglingTail = index
                }
            } else if !insideCode {
                // Asterisks inside a code span are literal text.
                if open.last == marker, let before, !before.isWhitespace {
                    open.removeLast()
                } else if let after, !after.isWhitespace {
                    open.append(marker)
                } else if after == nil {
                    danglingTail = index
                }
            }

            index = end
        }

        var result = danglingTail.map { String(characters[0..<$0]) } ?? text
        // A run of asterisks only closes emphasis if a non-space comes before it.
        // The model writes «**O(n » and the space is the last thing that arrived,
        // so a closer appended straight onto it would be read as punctuation and
        // printed — the very asterisks this method exists to hide. The trailing
        // space is not lost by dropping it: nothing draws it at the end of a line.
        // Code spans need no such rule and get none: a backtick span may open on
        // a space, and trimming would leave an unmatched run instead.
        if open.last?.first == "*" {
            while let last = result.last, last.isWhitespace { result.removeLast() }
        }
        result += open.reversed().joined()
        return result
    }

    // MARK: - Inline markdown

    /// One line of inline markdown as the card draws it.
    ///
    /// Inline code gets its font and its background here rather than being left
    /// to the presentation intent alone: an identifier in the same proportional
    /// face as the sentence around it is the single thing this ticket exists to
    /// fix, and it is worth stating outright.
    static func inline(_ source: String, size: CGFloat) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            // Block syntax is already handled above; asking for it again here
            // would swallow the list markers this file just drew.
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }

        let code = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in code {
            attributed[range].font = .system(size: size, design: .monospaced)
            attributed[range].backgroundColor = Color.primary.opacity(0.08)
        }
        return attributed
    }
}
