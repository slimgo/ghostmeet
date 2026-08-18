//
//  PronunciationBrackets.swift
//  GhostMeet
//

import Foundation

/// Приводит в порядок скобки с произношением — то, что промпт просит, но не
/// всегда добивает.
///
/// В русском разговоре модели велено ставить за латиницей скобку с произношением:
/// `nginx (энджин-икс)`. Пользователь читает подсказку **вслух** и произносит
/// содержимое скобки вместо латиницы, которую вслух не прочесть.
///
/// **Почему остаток чинится кодом, а не ещё одной строкой промпта.** Промпт уже
/// говорит это прямо и с примером; в проекте записано, что запреты обходятся по
/// букве, а образцы исполняются, — десятая формулировка одного правила скорее
/// расшатает остальные, чем добьёт это. А вопрос «слева от скобки латиница или
/// нет» решается разбором строки и суждения не требует. То, что механическое,
/// промптом решать незачем.
enum PronunciationBrackets {

    /// Чинит текст, который **может быть недописан**.
    ///
    /// Подсказка приходит потоком, и разметка разбирается заново на каждом
    /// фрагменте. Поэтому правило одно и жёсткое: трогается только то, что уже
    /// дописано целиком. Незакрытая скобка, оборванное слово, скобка, которая
    /// ещё набирается, — не трогаются вовсе. Испортить наполовину пришедший
    /// текст хуже, чем не поправить его.
    static func fixed(_ text: String) -> String {
        guard text.contains("(") else { return text }
        var result = ""
        result.reserveCapacity(text.count)

        var rest = Substring(text)
        while let open = rest.firstIndex(of: "(") {
            guard let close = rest[rest.index(after: open)...].firstIndex(of: ")") else {
                // Скобка ещё не закрыта: либо текст недописан, либо её и не
                // закроют. В обоих случаях остаток отдаётся как есть.
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
                // Слева латиница — скобка ровно там, где ей положено.
                result += rest[..<rest.index(after: close)]
                rest = after
            } else if let term = latinTerm(startingAfter: after) {
                // «(кубернетис) Kubernetes» — вывернутая пара, и проверяется она
                // **раньше** дубля: слева тут тоже кириллица («Берём»), и
                // порядок проверок решает, переставим мы пару или съедим её.
                //
                // Порядок важен и для читающего: содержимое скобки произносят
                // **вместо** латиницы, а не перед ней, иначе термин звучит дважды.
                result += before
                result += term.text
                result += " (\(inside))"
                rest = term.rest
            } else if repeatsWord(endingAt: before, inside: inside) {
                // «кластер (кластер)» — глосс к русскому слову, дублирующий его.
                // Читать нечем: пользователь произнесёт слово дважды.
                //
                // **Только дубль, и это не осторожность, а необходимость.** По
                // одному признаку «в скобках кириллица» неотличимы глосс и
                // обычное пояснение — «Это важно (и вот почему)», — а пояснение
                // выбрасывать нельзя: оно несёт смысл. Совпадение со словом
                // слева и есть тот самый дефект, и ничего кроме него.
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

    /// Глосс — это скобка, внутри которой только кириллица, дефисы и пробелы.
    ///
    /// Узко намеренно. `O(n log n)` — не глосс, `(и это важно)` после русской
    /// фразы — тоже: первое сломается, второе потеряется. Трогается лишь то, что
    /// заведомо является произношением.
    private static func isGloss(_ inside: Substring) -> Bool {
        guard !inside.isEmpty else { return false }
        return inside.allSatisfy { character in
            character.isCyrillic || character == "-" || character == " " || character == "\u{2011}"
        }
    }

    /// Повторяет ли скобка слово, стоящее перед ней.
    ///
    /// Сравнение без регистра и без дефисов: «Кластер (кластер)» и «хеш-мапа
    /// (хешмапа)» — один и тот же дефект.
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

    /// Латинский термин в начале остатка — вместе с тем, что за ним осталось.
    private static func latinTerm(startingAfter rest: Substring) -> (text: Substring, rest: Substring)? {
        let start = rest.drop(while: \.isWhitespace)
        guard let first = start.first, first.isLatinTerm else { return nil }
        let end = start.firstIndex { !$0.isLatinTerm } ?? start.endIndex
        // Слово, дошедшее ровно до конца текста, могло не дописаться: в потоке
        // «Kub» превратилось бы в термин, а через фрагмент это «Kubernetes».
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

    /// Что может входить в латинский термин: буквы, цифры и знаки, из которых
    /// состоят имена из кода — `created_at`, `large-v3`, `Vue.js`.
    var isLatinTerm: Bool {
        isASCII && (isLetter || isNumber || self == "_" || self == "-" || self == ".")
    }
}
