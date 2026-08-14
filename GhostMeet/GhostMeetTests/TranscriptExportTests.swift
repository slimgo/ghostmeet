//
//  TranscriptExportTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

// MARK: - Support

/// A fixed anchor: uptime 1000 corresponds to a known wall-clock moment, so a
/// turn stamped at 1000 and a suggestion stamped at that date are simultaneous.
private let origin = Date(timeIntervalSince1970: 1_800_000_000)
private let anchor = TranscriptExport.Anchor(uptime: 1_000, date: origin)

private func turn(
    _ channel: Channel,
    _ text: String,
    at uptime: TimeInterval,
    isLeak: Bool = false
) -> Turn {
    Turn(channel: channel, text: text, timestamp: uptime, duration: 1, isLeak: isLeak)
}

private func suggestion(
    _ text: String,
    at offset: TimeInterval,
    state: Suggestion.State = .complete,
    notice: String? = nil
) -> Suggestion {
    Suggestion(
        text: text,
        state: state,
        notice: notice,
        startedAt: origin.addingTimeInterval(offset)
    )
}

private let metadata = TranscriptExport.Metadata(
    savedAt: origin,
    profile: "Синьор фулстек",
    provider: "Polza.AI, anthropic/claude-haiku-4.5",
    source: "Google Chrome"
)

private func export(
    turns: [Turn] = [],
    suggestions: [Suggestion] = [],
    metadata: TranscriptExport.Metadata = metadata
) -> String {
    TranscriptExport.markdown(
        turns: turns,
        suggestions: suggestions,
        metadata: metadata,
        anchor: anchor
    )
}

// MARK: - Порядок

@Suite("Реплики и подсказки ложатся в одну ленту по времени")
struct TranscriptExportOrderTests {

    @Test("Подсказка встаёт между репликами, а не в начало и не в конец")
    func interleavesAnswersWithSpeech() {
        let text = export(
            turns: [
                turn(.them, "Расскажите про event loop", at: 1_000),
                turn(.you, "Есть стек вызовов", at: 1_030)
            ],
            suggestions: [suggestion("Микрозадачи разгребаются первыми", at: 15)]
        )

        let them = text.range(of: "Расскажите про event loop")
        let hint = text.range(of: "Микрозадачи разгребаются первыми")
        let you = text.range(of: "Есть стек вызовов")

        #expect(them != nil && hint != nil && you != nil)
        #expect(them!.lowerBound < hint!.lowerBound, "подсказка обязана стоять после вопроса")
        #expect(hint!.lowerBound < you!.lowerBound, "и до ответа, который был позже неё")
    }

    @Test("Порядок не зависит от того, в каком порядке передали списки")
    func sortsRegardlessOfInputOrder() {
        let straight = export(
            turns: [turn(.them, "первый", at: 1_000), turn(.you, "второй", at: 1_060)],
            suggestions: []
        )
        let reversed = export(
            turns: [turn(.you, "второй", at: 1_060), turn(.them, "первый", at: 1_000)],
            suggestions: []
        )

        #expect(straight == reversed)
    }

    @Test("Время в файле относительное, от первой записи")
    func stampsAreRelativeToTheStart() {
        let text = export(turns: [
            turn(.them, "начало", at: 1_000),
            turn(.you, "через полторы минуты", at: 1_090)
        ])

        #expect(text.contains("**Them** · 00:00"))
        #expect(text.contains("**You** · 01:30"))
    }

    @Test("Две шкалы времени сведены якорем: подсказка не уезжает за пределы разговора")
    func anchorsTheTwoClocks() {
        // Реплики стоят на uptime, подсказка — на дате. Без якоря она оказалась
        // бы либо раньше всего, либо позже всего.
        let text = export(
            turns: [turn(.them, "вопрос", at: 1_000), turn(.you, "ответ", at: 1_120)],
            suggestions: [suggestion("подсказка", at: 60)]
        )

        #expect(text.contains("**Подсказка** · 01:00"))
    }
}

// MARK: - Протечки

@Suite("Протечки вычищены, но посчитаны")
struct TranscriptExportLeakTests {

    @Test("Помеченная протечка в файл не попадает")
    func leaksAreLeftOut() {
        let text = export(turns: [
            turn(.them, "какой у вас стек", at: 1_000),
            turn(.you, "какой у вас стек", at: 1_001, isLeak: true),
            turn(.you, "Go и PostgreSQL", at: 1_020)
        ])

        #expect(!text.contains("**You** · 00:01"), "строка протечки не должна была появиться")
        #expect(text.contains("Go и PostgreSQL"))
    }

    @Test("Число выброшенных строк названо в шапке — иначе «чисто» не отличить от «не увидели»")
    func droppedLinesAreCounted() {
        let text = export(turns: [
            turn(.them, "вопрос", at: 1_000),
            turn(.you, "вопрос", at: 1_001, isLeak: true),
            turn(.you, "вопрос", at: 1_002, isLeak: true)
        ])

        #expect(text.contains("выброшено как протечка: 2 строки"))
    }

    @Test("Когда протечек не было, о них не говорится вовсе")
    func silentWhenThereWereNoLeaks() {
        let text = export(turns: [turn(.them, "вопрос", at: 1_000)])

        #expect(!text.contains("протечка"))
    }
}

// MARK: - Состояния ответа

@Suite("Ответ сохраняется таким, каким он был")
struct TranscriptExportSuggestionStateTests {

    @Test("Оборванный ответ сохраняется вместе с причиной, а не выбрасывается")
    func keepsCutAnswersWithTheirReason() {
        let text = export(suggestions: [
            suggestion("Начну с оценки сложности", at: 5, state: .cut("кончился бюджет ответа"))
        ])

        #expect(text.contains("Начну с оценки сложности"))
        #expect(text.contains("кончился бюджет ответа"))
    }

    @Test("Перебитый ответ помечен как перебитый")
    func marksSupersededAnswers() {
        let text = export(suggestions: [suggestion("половина фразы", at: 5, state: .superseded)])

        #expect(text.contains("половина фразы"))
        #expect(text.contains("перебит"))
    }

    @Test("Несостоявшийся ответ оставляет причину вместо текста")
    func keepsTheReasonWhenThereWasNoAnswer() {
        let text = export(suggestions: [suggestion("", at: 5, state: .failed("нет ключа провайдера"))])

        #expect(text.contains("нет ключа провайдера"))
    }

    @Test("Предупреждение над ответом сохраняется вместе с ним")
    func keepsTheNotice() {
        let text = export(suggestions: [
            suggestion("ответ", at: 5, notice: "последняя фраза не успела распознаться")
        ])

        #expect(text.contains("последняя фраза не успела распознаться"))
    }
}

// MARK: - Шапка и края

@Suite("Шапка говорит о звонке, и только правду")
struct TranscriptExportHeaderTests {

    @Test("Профиль, провайдер и источник попадают в шапку")
    func statesWhatTheCallWasArmedWith() {
        let text = export(turns: [turn(.them, "вопрос", at: 1_000)])

        #expect(text.contains("профиль «Синьор фулстек»"))
        #expect(text.contains("Polza.AI, anthropic/claude-haiku-4.5"))
        #expect(text.contains("Источник: Google Chrome"))
    }

    @Test("Незаполненное поле не превращается в подпись с пустотой")
    func omitsWhatIsNotKnown() {
        let bare = TranscriptExport.Metadata(savedAt: origin)
        let text = export(turns: [turn(.them, "вопрос", at: 1_000)], metadata: bare)

        #expect(!text.contains("профиль"))
        #expect(!text.contains("Источник"))
    }

    @Test("Пустой разговор даёт осмысленный файл, а не пустоту и не падение")
    func survivesAnEmptyCall() {
        let text = export()

        #expect(text.contains("# GhostMeet"))
        #expect(text.contains("сохранять нечего"))
    }

    @Test("Нераспознанная реплика видна как нераспознанная, а не как пустая строка")
    func namesAnUnrecognisedTurn() {
        let text = export(turns: [turn(.them, "", at: 1_000)])

        #expect(text.contains("не распознано"))
    }
}

// MARK: - Имя файла

@MainActor
@Suite("Имя файла по умолчанию сортируется само")
struct TranscriptFileNameTests {

    @Test("Дата стоит в имени задом наперёд — папка таких файлов выстраивается по времени")
    func sortsChronologicallyByName() {
        let earlier = TranscriptSaving.suggestedName(for: Date(timeIntervalSince1970: 1_800_000_000))
        let later = TranscriptSaving.suggestedName(for: Date(timeIntervalSince1970: 1_800_090_000))

        #expect(earlier.hasPrefix("GhostMeet-"))
        #expect(earlier.hasSuffix(".md"))
        #expect(earlier < later, "лексикографический порядок обязан совпадать с хронологическим")
    }
}
