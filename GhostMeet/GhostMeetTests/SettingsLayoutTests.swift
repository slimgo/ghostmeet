//
//  SettingsLayoutTests.swift
//  GhostMeetTests
//

import AppKit
import Testing
@testable import GhostMeet

/// Ширина строки, которую подпись занимает системным шрифтом того же размера,
/// каким её рисует форма.
@MainActor
private func width(of label: String) -> CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    return (label as NSString).size(withAttributes: [.font: font]).width
}

/// Подписи полей, у которых подпись стоит **сбоку** — то есть тех, что делят
/// колонку фиксированной ширины.
///
/// Список выписан руками, и это осознанно: он и есть утверждение. Колонка —
/// то, чем чинилась жалоба «поля прыгают», и подпись, которая в неё не влезла,
/// вернёт жалобу с другой стороны: обрезанное многоточием слово вместо
/// прыгающего поля.
///
/// Абзацных полей здесь нет намеренно — у них подпись сверху и вся ширина
/// строки, см. `SettingsParagraphRow`. Именно этот тест и показал, зачем они
/// нужны: «Вопросы к работодателю» просит 161 pt, и колонка, растянутая под
/// такую подпись, сдавила бы все остальные поля окна.
@MainActor
private let sideLabels: [String] = [
    "Активный профиль", "Название", "Роль",
    "Бэкенд", "Слушать", "Модель", "Провайдер", "Базовый адрес",
    "Команда", "API-ключ"
]

@MainActor
@Suite("Колонка меток в настройках вмещает то, что в неё кладут")
struct SettingsLayoutTests {

    /// Жалоба владельца была двойная — «поля прыгают» и «выравнивание везде
    /// вправо», — и причина у неё одна: `Form` со `.formStyle(.grouped)` сам
    /// решает и то, и другое. Решение перенесено в `SettingsRow`, а раз ширина
    /// теперь наша, за неё надо отвечать.
    @Test("Каждая подпись помещается в колонку целиком")
    func everyLabelFitsTheColumn() {
        for label in sideLabels {
            let needed = width(of: label)
            #expect(
                needed <= SettingsMetrics.labelColumn,
                "«\(label)» просит \(Int(needed)) pt, а колонка \(Int(SettingsMetrics.labelColumn)) pt"
            )
        }
    }

    /// Колонка, подобранная впритык, перестанет работать на первой же правке
    /// текста.
    @Test("У колонки остаётся запас, а не ноль")
    func theColumnHasHeadroom() throws {
        let longest = try #require(sideLabels.max(by: { width(of: $0) < width(of: $1) }))
        let slack = SettingsMetrics.labelColumn - width(of: longest)
        #expect(slack >= 12, "самая длинная подпись «\(longest)», запаса всего \(Int(slack)) pt")
    }

    /// **То же самое по-английски, и это не формальность.** Колонка одна на оба
    /// языка, а слова разной длины: «Базовый адрес» — 95 pt, «Base address» —
    /// другое число, и узнать, какое, можно только измерив. Перевод, не влезший
    /// в колонку, даёт то же обрезанное многоточием слово, ради которого всё это
    /// и затевалось.
    @Test("Английские подписи тоже помещаются в колонку")
    func everyEnglishLabelFitsTheColumn() throws {
        let url = try #require(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj")
        )
        let data = try Data(contentsOf: url)
        let table = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
        for label in sideLabels {
            let english = try #require(table[label], "«\(label)» не переведена вовсе")
            let needed = width(of: english)
            #expect(
                needed <= SettingsMetrics.labelColumn,
                "«\(english)» просит \(Int(needed)) pt, а колонка \(Int(SettingsMetrics.labelColumn)) pt"
            )
        }
    }

    /// Длинные подписи существуют, и их место — не в колонке. Тест сторожит
    /// саму развилку: если абзацное поле однажды переведут в боковую подпись,
    /// колонка снова перестанет вмещать.
    @Test("Длинные подписи живут абзацными полями, а не растянутой колонкой")
    func longLabelsAreParagraphFields() {
        let contextLabels = InterviewContext.Field.allCases.map(\.label)
        let longest = contextLabels.map(width(of:)).max() ?? 0
        #expect(
            longest > SettingsMetrics.labelColumn,
            "если контекст собеседования стал коротким, развилка больше не нужна — уберите её вместе с этим тестом"
        )
        for label in contextLabels {
            #expect(sideLabels.contains(label) == false, "«\(label)» слишком длинная для боковой подписи")
        }
    }

    /// Окно одного размера на всех вкладках — иначе жалоба «всё прыгает»
    /// возвращается, только уже целым окном при переключении страницы.
    @Test("Размер окна задан и не берётся из содержимого")
    func theWindowHasOneSize() {
        #expect(SettingsMetrics.windowWidth > 0)
        #expect(SettingsMetrics.windowHeight > 0)
        // Колонка меток плюс зазор не должны съедать окно: контролу остаётся
        // больше половины ширины, иначе поле снова станет уже своего содержимого.
        let forControl = SettingsMetrics.windowWidth - SettingsMetrics.labelColumn - SettingsMetrics.labelGap
        #expect(forControl > SettingsMetrics.windowWidth / 2)
    }
}
