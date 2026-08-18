//
//  PronunciationBracketsTests.swift
//  GhostMeetTests
//

import Testing
@testable import GhostMeet

@Suite("Скобки с произношением: то, что промпт не добивает")
struct PronunciationBracketsTests {

    @Test("Скобка после латиницы — на своём месте, её не трогают")
    func latinKeepsItsGloss() {
        let text = "Мы держим nginx (энджин-икс) перед сервисом."
        #expect(PronunciationBrackets.fixed(text) == text)
    }

    /// «кластер (кластер)» читать нечем: слева уже русское слово, а в скобке то
    /// же самое. Пользователь произносит это вслух — и говорит слово дважды.
    @Test("Скобка после кириллицы убирается вместе с лишним пробелом")
    func cyrillicLosesItsGloss() {
        #expect(PronunciationBrackets.fixed("Поднимаем кластер (кластер) на трёх узлах.")
                == "Поднимаем кластер на трёх узлах.")
        #expect(PronunciationBrackets.fixed("очередь (очередь)") == "очередь")
    }

    /// Порядок важен: содержимое скобки произносят **вместо** латиницы, а не
    /// перед ней. Вывернутая пара заставляет прочесть термин дважды.
    @Test("Вывернутая пара переставляется")
    func invertedPairIsPutRight() {
        #expect(PronunciationBrackets.fixed("Берём (кубернетис) Kubernetes и живём.")
                == "Берём Kubernetes (кубернетис) и живём.")
    }

    /// Узость правила — не осторожность, а требование: тронув эти скобки, мы
    /// сломаем работающий текст.
    @Test("Формулы, код и русские пояснения в скобках остаются как были")
    func leavesEverythingElseAlone() {
        for text in [
            "Сложность O(n log n), узкое место — сортировка.",
            "Это важно (и вот почему): очередь не резиновая.",
            "Вызов get(ctx, id) возвращает ошибку.",
            "PostgreSQL (постгрес) держит связи в пуле.",
        ] {
            #expect(PronunciationBrackets.fixed(text) == text, "испорчено: \(text)")
        }
    }

    /// Подсказка приходит потоком, и разметка разбирается заново на каждом
    /// фрагменте. Испортить недописанный текст хуже, чем не поправить его.
    @Test("Ни один префикс потока не портится")
    func everyPrefixSurvives() {
        let full = "Берём Kubernetes (кубернетис), а кластер (кластер) держим на трёх узлах."
        for length in 1...full.count {
            let prefix = String(full.prefix(length))
            let fixed = PronunciationBrackets.fixed(prefix)
            // Правка допустима, порча — нет: результат либо сам префикс, либо
            // то, во что он превратится, когда допишется.
            #expect(fixed.isEmpty == false)
            #expect(fixed.contains("((") == false, "сдвоенная скобка на префиксе «\(prefix)»")
            #expect(fixed.contains("()") == false, "пустая скобка на префиксе «\(prefix)»")
        }
    }

    /// Незакрытая скобка — это либо недописанный текст, либо оговорка модели.
    /// В обоих случаях трогать её нельзя.
    @Test("Незакрытая скобка остаётся нетронутой")
    func unclosedBracketIsLeftAlone() {
        #expect(PronunciationBrackets.fixed("кластер (класт") == "кластер (класт")
        #expect(PronunciationBrackets.fixed("Kubernetes (кубер") == "Kubernetes (кубер")
    }

    @Test("Текст без скобок возвращается как есть")
    func textWithoutBracketsIsUntouched() {
        let text = "Обычная фраза без единой скобки."
        #expect(PronunciationBrackets.fixed(text) == text)
    }
}

@Suite("Корректор скобок стоит на пути разметки, но не в коде")
struct BracketFixerPlacementTests {

    @Test("Абзац подсказки чинится")
    func paragraphIsFixed() throws {
        let blocks = SuggestionMarkup.blocks(of: "Поднимаем кластер (кластер) на трёх узлах.")
        let paragraph = try #require(blocks.first)
        #expect(paragraph.text == "Поднимаем кластер на трёх узлах.")
    }

    /// Код не произносят вслух: там скобка — синтаксис, и правка ломает пример.
    @Test("Блок кода не трогается вовсе")
    func codeIsLeftAlone() throws {
        let source = """
        Вот решение:

        ```go
        кластер (кластер)
        items := get(ctx, id)
        ```
        """
        let code = try #require(SuggestionMarkup.blocks(of: source).first { block in
            if case .code = block.kind { return true }
            return false
        })
        #expect(code.text.contains("кластер (кластер)"))
        #expect(code.text.contains("get(ctx, id)"))
    }

    @Test("Пункт списка и заголовок чинятся так же, как абзац")
    func listAndHeadingAreFixed() throws {
        let blocks = SuggestionMarkup.blocks(of: "## Очередь (очередь)\n- кластер (кластер) на трёх узлах")
        #expect(blocks.contains { $0.text == "Очередь" })
        #expect(blocks.contains { $0.text == "кластер на трёх узлах" })
    }
}
