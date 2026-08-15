//
//  PhantomTurnsTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

// MARK: - Звонок, в котором распознаватель сочинял

@Suite("Фантомные реплики")
@MainActor
struct PhantomTurnsTests {

    /// Четыре фразы, которых в звуке не было, из звонка 15 августа 2026 года, —
    /// с каналом и временем, под которыми они стоят в сохранённом транскрипте.
    private static let recordedPhantoms: [(text: String, channel: Channel, at: String)] = [
        ("Thank you.", .you, "04:23"),
        ("you", .you, "22:24"),
        ("Продолжение следует...", .them, "24:10"),
        ("Thank you.", .you, "33:28"),
    ]

    @Test("Четыре фантома разобранного звонка словами не становятся")
    func theFourPhantomsOfTheRecordedCallNeverBecomeWords() async {
        let phantoms = Self.recordedPhantoms
        let next = Counter()
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(transcription: { _ in phantoms[await next.take()].text })
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        for phantom in phantoms {
            call.saysSomething(lasting: 1.5, on: phantom.channel)
            await call.engine.waitForRecognition()
        }

        #expect(call.transcript.count == phantoms.count, "звук там был — реплики остаются на месте")
        for (turn, phantom) in zip(call.transcript, phantoms) {
            #expect(turn.text.isEmpty, "\(phantom.at): «\(phantom.text)» никто не произносил")
        }
        #expect(call.transcript.map(\.channel) == phantoms.map(\.channel))
    }

    @Test("Фантом в канале Them не занимает места настоящего вопроса")
    func aPhantomInThemDoesNotDisplaceTheQuestion() async {
        // 24:10 разобранного звонка: подключился второй интервьюер и спросил про
        // пробы живости и готовности, а в транскрипт попало «Продолжение
        // следует...». Худший класс отказа в этом проекте — ответ выходит связным
        // и не про то, что спросили, — и потому фильтр обязан работать в обоих
        // каналах, а не только в том, где фантом всего лишь врёт о пользователе.
        let spoken = ["Продолжение следует...", "Как вы настраиваете пробы живости и готовности?"]
        let next = Counter()
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(transcription: { _ in spoken[await next.take()] })
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()
        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()

        let rendered = TranscriptFormatter.format(call.engine.transcript, limit: TranscriptFormatter.wholeCall)
        #expect(!rendered.contains("Продолжение следует"), "выдуманного собеседник не говорил")
        #expect(rendered.contains("пробы живости и готовности"), "а вопрос дошёл до модели целиком")
    }

    @Test("Фантом в канале You не выдаёт себя за начало ответа пользователя")
    func aPhantomInYouIsNotTheUserSpeaking() async {
        // Жанр «коротко» устроен вокруг того, что пользователь уже говорит вслух,
        // и `hasStartedAnswering` — то место, где это решается. Фантом «Thank
        // you.» сразу после вопроса собеседника отвечал на этот вопрос «да».
        let spoken = ["Где вы сознательно откатились обратно к обычным интерфейсам?", "Thank you."]
        let next = Counter()
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(transcription: { _ in spoken[await next.take()] })
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()
        call.saysSomething(lasting: 1.5, on: .you)
        await call.engine.waitForRecognition()

        #expect(
            !TranscriptFormatter.hasStartedAnswering(call.engine.transcript),
            "пользователь не сказал ни слова — отвечать за него нельзя"
        )
        #expect(
            !TranscriptFormatter.format(call.engine.transcript, limit: TranscriptFormatter.wholeCall)
                .contains("You:"),
            "строки пользователя в промпте нет вовсе"
        )
    }

    @Test("«Спасибо.» отдельной репликой — это речь, и она остаётся")
    func plainRussianThanksSurvivesOnItsOwn() async {
        // Цена ошибки здесь ровно та же, что у ложного срабатывания
        // дедупликации, только адресат другой: «Спасибо.» в русскоязычном
        // собеседовании говорят постоянно и одной репликой целиком.
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(transcription: { _ in "Спасибо." })
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        call.saysSomething(lasting: 1.5, on: .you)
        await call.engine.waitForRecognition()

        #expect(call.transcript.first?.text == "Спасибо.")
    }

    @Test("Реплика, где фантомная фраза лишь часть, сохраняется целиком и неизменной")
    func speechThatMerelyContainsAPhantomIsKeptWordForWord() async {
        let said = "Thanks, я понял, а если шардировать"
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(transcription: { _ in said })
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        call.saysSomething(lasting: 1.5, on: .you)
        await call.engine.waitForRecognition()

        #expect(call.transcript.first?.text == said, "вырезать слово значило бы испортить реплику")
    }
}

// MARK: - Опознание самой фразы

@Suite("Фантомная фраза")
struct PhantomSpeechTests {

    @Test("Каждая фраза списка опознаётся — и в том виде, в каком её печатает распознаватель")
    func everyListedPhraseIsRecognised() {
        for phrase in PhantomSpeech.phrases {
            #expect(PhantomSpeech.isPhantom(phrase), "«\(phrase)» стоит в списке")
            #expect(PhantomSpeech.isPhantom(phrase.uppercased()), "регистр решать не должен")
            #expect(PhantomSpeech.isPhantom("  \(phrase)  "), "пробелы по краям тоже")
        }
    }

    @Test("Пунктуация ничего не решает: фраза узнаётся с точками и без")
    func punctuationDoesNotMatter() {
        #expect(PhantomSpeech.isPhantom("Thank you."))
        #expect(PhantomSpeech.isPhantom("Thank you"))
        #expect(PhantomSpeech.isPhantom("Thank you!"))
        #expect(PhantomSpeech.isPhantom("Продолжение следует..."))
        #expect(PhantomSpeech.isPhantom("Продолжение следует"))
    }

    @Test("Совпадение только целиком: фантомная фраза внутри речи речь не отменяет")
    func containmentIsNeverEnough() {
        #expect(!PhantomSpeech.isPhantom("Thanks, я понял, а если шардировать"))
        #expect(!PhantomSpeech.isPhantom("Thank you, теперь давайте про индексы"))
        #expect(!PhantomSpeech.isPhantom("you know, это зависит от нагрузки"))
        #expect(!PhantomSpeech.isPhantom("Спасибо за просмотр логов, там всё видно"))
    }

    @Test("«Спасибо» в списке нет и появиться не должно")
    func plainThanksIsNotAPhantom() {
        #expect(!PhantomSpeech.isPhantom("Спасибо."))
        #expect(!PhantomSpeech.isPhantom("Спасибо"))
        #expect(!PhantomSpeech.isPhantom("Спасибо!"))
        #expect(
            !PhantomSpeech.phrases.contains { LeakDedup.words($0) == ["спасибо"] },
            "его говорят постоянно и одной репликой целиком"
        )
    }

    @Test("Нормализация — та же, что у дедупликации по тексту, а не своя")
    func normalisationIsTheOneLeakDedupUses() {
        // Два одинаковых приведения текста разошлись бы на первой же правке, и
        // разошлись бы молча: обе стороны продолжали бы работать, просто на
        // разных словах.
        for phrase in PhantomSpeech.phrases {
            #expect(PhantomSpeech.isPhantom(LeakDedup.words(phrase).joined(separator: " ")))
        }
        #expect(LeakDedup.words("Ещё раз") == ["еще", "раз"], "та самая нормализация: регистр, пунктуация, ё")
    }

    @Test("Пустой текст и одна пунктуация фантомом не считаются")
    func emptyTextIsNotAPhantom() {
        #expect(!PhantomSpeech.isPhantom(""))
        #expect(!PhantomSpeech.isPhantom("   "))
        #expect(!PhantomSpeech.isPhantom("..."))
    }
}

// MARK: - Мелочи для сценариев

/// Hands out 0, 1, 2… so a scripted fake can answer differently each time.
private actor Counter {
    private var value = 0

    func take() -> Int {
        defer { value += 1 }
        return value
    }
}
