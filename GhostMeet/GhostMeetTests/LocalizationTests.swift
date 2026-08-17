//
//  LocalizationTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// Слова, которым по-английски положено остаться кириллицей: название языка
/// пишут на нём самом, иначе выбирать его будет не по чему.
private let deliberatelyCyrillicInEnglish: Set<String> = ["Русский"]

/// Английская таблица строк из **собранного бандла**.
///
/// Читается бандл, а не наш каталог: вопрос не в том, что мы написали, а в том,
/// что доехало. Это записанная грабля проекта — `INFOPLIST_KEY_*` для незнакомых
/// Xcode ключей молча выбрасывается, и та же осторожность стоит того здесь.
private func englishTable() throws -> [String: String] {
    let url = try #require(
        Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"),
        "в бандле нет en.lproj/Localizable.strings — английского в приложении просто нет"
    )
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(plist as? [String: String])
}

@Suite("Английский в приложении есть и он полный")
struct LocalizationTests {

    @Test("Английская таблица доехала до бандла и не пуста")
    func theEnglishTableIsInTheBundle() throws {
        let table = try englishTable()
        // Порог, а не точное число: набор строк растёт с каждой правкой окна, и
        // тест, который надо править под каждую новую надпись, начинают править
        // не глядя. Ловится здесь другое — обвал: каталог, не попавший в сборку.
        #expect(table.count > 200, "строк в английской таблице всего \(table.count)")
    }

    /// **Главная проверка, и она про забытую строку, а не про кривой перевод.**
    /// Ключ у нас — сам русский текст, поэтому строка, которую забыли перевести,
    /// не падает и не пустеет: она возвращается по-русски и встаёт посреди
    /// английского экрана. Увидит её пользователь, а не мы, — если не искать
    /// кириллицу в английской таблице.
    @Test("В английском тексте не осталось кириллицы")
    func nothingCyrillicSurvivesInEnglish() throws {
        let cyrillic = CharacterSet(charactersIn: "А"..."я").union(CharacterSet(charactersIn: "ёЁ"))
        for (key, value) in try englishTable() {
            guard !deliberatelyCyrillicInEnglish.contains(value) else { continue }
            #expect(
                value.rangeOfCharacter(from: cyrillic) == nil,
                "«\(key)» по-английски осталось русским: «\(value)»"
            )
        }
    }

    /// **Таблица в бандле — ещё не английский интерфейс.** Между ней и экраном
    /// стоит разрешение строки, и оно может не сработать: `Text(строка)` не
    /// переводится вовсе, в отличие от `Text(ключ)`, — на этом уже попались
    /// подписи полей настроек. Поэтому тест просит английский бандл ровно так,
    /// как его просит система, и смотрит, что вернулось.
    @Test("Английский бандл действительно отдаёт английский текст")
    func theEnglishBundleResolves() throws {
        let url = try #require(Bundle.main.url(forResource: "en", withExtension: "lproj"))
        let english = try #require(Bundle(url: url))

        #expect(english.localizedString(forKey: "Слушать", value: nil, table: nil) == "Listen")
        #expect(english.localizedString(forKey: "Стоп", value: nil, table: nil) == "Stop")
        #expect(english.localizedString(forKey: "Профиль", value: nil, table: nil) == "Profile")
        #expect(english.localizedString(forKey: "Обновления", value: nil, table: nil) == "Updates")
    }

    /// Плейсхолдер, потерянный в переводе, — это не опечатка, а пустое место
    /// там, где должно стоять имя профиля или номер версии.
    @Test("Плейсхолдеры в переводе те же, что в оригинале")
    func placeholdersSurviveTranslation() throws {
        let specifier = try Regex("%(?:lld|\\d*\\.?\\d*[@df]|%)")
        for (key, value) in try englishTable() {
            let inKey = key.matches(of: specifier).map { String(key[$0.range]) }.sorted()
            let inValue = value.matches(of: specifier).map { String(value[$0.range]) }.sorted()
            #expect(inKey == inValue, "«\(key)»: было \(inKey), стало \(inValue)")
        }
    }
}

@Suite("Язык интерфейса — это не язык подсказки")
struct AppLanguageTests {

    @Test("По умолчанию — как в системе, а не русский")
    func defaultsToTheSystem() {
        let defaults = UserDefaults(suiteName: "GhostMeetLanguageTest-\(UUID().uuidString)")!
        #expect(AppLanguage.stored(in: defaults) == .system)
    }

    @Test("Выбор пишется туда, откуда его читает macOS")
    func writesWhereTheSystemLooks() {
        let name = "GhostMeetLanguageTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        AppLanguage.english.apply(to: defaults)
        #expect(defaults.array(forKey: AppLanguage.appleLanguagesKey) as? [String] == ["en"])
        #expect(AppLanguage.stored(in: defaults) == .english)
        #expect(AppLanguage.effective(in: defaults) == .english)

        AppLanguage.russian.apply(to: defaults)
        #expect(AppLanguage.stored(in: defaults) == .russian)
        #expect(AppLanguage.effective(in: defaults) == .russian)
    }

    /// «Как в системе» значит «продолжай следовать системе», в том числе когда
    /// её поменяют в системных настройках, — поэтому наш ключ снимается, а не
    /// переписывается нынешним значением.
    ///
    /// Проверяется **выбор**, а не то, что видно в `AppleLanguages`: убрать
    /// оттуда системное значение нельзя и не нужно — `UserDefaults` проваливается
    /// в глобальный домен, где macOS держит свой список. Ровно на это тест и
    /// наткнулся: пока выбор читался оттуда же, «как в системе» на русской
    /// машине показывалось как «Русский».
    @Test("«Как в системе» возвращает выбор к системному")
    func systemRemovesTheKey() {
        let name = "GhostMeetLanguageTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        AppLanguage.english.apply(to: defaults)
        AppLanguage.system.apply(to: defaults)

        #expect(AppLanguage.stored(in: defaults) == .system)
        // Своего значения больше нет; что видно снаружи — дело системы.
        #expect(defaults.persistentDomain(forName: name)?[AppLanguage.appleLanguagesKey] == nil)
    }

    @Test("Полный идентификатор вроде en-GB читается как английский")
    func readsARegionalIdentifier() {
        let name = "GhostMeetLanguageTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(["en-GB"], forKey: AppLanguage.appleLanguagesKey)
        #expect(AppLanguage.effective(in: defaults) == .english)
    }

    /// Ради этого разделения написан отдельный тикет: подсказку читают вслух
    /// собеседнику, и на английском собеседовании она обязана быть английской
    /// независимо от того, на каком языке пользователь держит окно.
    @Test("Язык интерфейса не участвует в сборке промпта")
    func theInterfaceLanguageNeverReachesThePrompt() {
        // Промпт собирается из литералов, сверенных с docs/GhostMeet-Prompts.md,
        // и ни одного слоя между ним и настройками нет. Проверяется это с той
        // стороны, где ошибка была бы возможна: язык интерфейса живёт в
        // `AppleLanguages`, и промпт этого ключа не видит.
        #expect(SolvePrompt.system.isEmpty == false)
        #expect(SolvePrompt.system.contains(AppLanguage.appleLanguagesKey) == false)
    }
}
