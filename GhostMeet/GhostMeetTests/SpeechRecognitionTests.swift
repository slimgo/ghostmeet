//
//  SpeechRecognitionTests.swift
//  GhostMeetTests
//

import Foundation
import Observation
import Testing
@testable import GhostMeet

// MARK: - Fixture

/// Waits for something a background task is on its way to doing.
///
/// No sleeping and no wall-clock deadline: the scenarios stay as fast as the
/// machine running them.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<5_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

/// Runs `body` against a throwaway `UserDefaults` suite and wipes it afterwards.
@MainActor
private func withTemporaryDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
    let name = "GhostMeetSpeechTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try await body(defaults)
}

// MARK: - Реплики получают текст

@Suite("Распознавание реплик")
@MainActor
struct SpeechRecognitionTests {

    @Test("Собеседник задал вопрос — его слова появились в транскрипте")
    func closedTurnGetsItsWords() async {
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(transcription: { _ in "расскажите про ваш опыт" })
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()

        #expect(call.transcript.count == 1)
        #expect(call.transcript.first?.channel == .them)
        #expect(call.transcript.first?.text == "расскажите про ваш опыт")
    }

    @Test("Русская и английская реплики распознаются подряд, без единого переключения")
    func russianAndEnglishNeedNoSetting() async {
        // Язык — свойство реплики, а не настройки: распознавание получает только
        // звук и возвращает то, что было сказано, на том языке, на котором это
        // было сказано.
        let spoken = ["Расскажите про ваш опыт", "Now let us talk about concurrency"]
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

        #expect(call.transcript.map(\.text) == spoken)
    }

    @Test("Движок сорвался на реплике — она осталась в транскрипте как нераспознанная")
    func failedRecognitionKeepsTheTurn() async {
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(
                transcription: { _ in throw FakeSpeechModelProvider.Failure(reason: "движок сорвался") }
            )
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()

        #expect(call.transcript.count == 1, "потерять реплику хуже, чем показать её без слов")
        #expect(call.transcript.first?.text == "")
        #expect(call.transcript.first?.duration ?? 0 > 1.4, "длина реплики известна и без распознавания")
    }

    @Test("Сбой на одном канале не уносит с собой реплику другого")
    func oneChannelFailureLeavesTheOtherAlone() async {
        // Каналы различаются только длиной реплик: сам канал распознаванию
        // принципиально не виден, оно получает звук и больше ничего.
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(transcription: { samples in
                let seconds = Double(samples.count) / WhisperModel.requiredSampleRate
                guard seconds > 3 else {
                    throw FakeSpeechModelProvider.Failure(reason: "движок сорвался")
                }
                return "расскажите про ваш опыт"
            })
        )
        await call.recognizer.prepare()
        await call.recognizer.prepared()

        call.saysSomething(lasting: 1.0, on: .you)
        call.saysSomething(lasting: 3.0, on: .them)
        await call.engine.waitForRecognition()

        #expect(call.transcript.map(\.channel) == [.you, .them])
        #expect(call.transcript.first?.text == "", "сорвавшаяся реплика осталась без слов")
        #expect(call.transcript.last?.text == "расскажите про ваш опыт", "соседний канал не пострадал")
    }

    @Test("Реплика закрылась раньше, чем скачалась модель — она не потерялась и не заморозила звонок")
    func turnsBeforeTheModelIsReadyAreKeptWithoutText() async {
        let gate = Gate()
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(
                download: .held(gate),
                transcription: { _ in "расскажите про ваш опыт" }
            )
        )

        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()

        #expect(call.transcript.count == 1)
        #expect(call.transcript.first?.text == "")

        // Скачивание идёт, но звонок продолжается: реплики закрываются как обычно.
        #expect(
            await eventually { await call.recognizer.phase == .downloading(fraction: 0.25) },
            "прогресс должен быть виден, пока модель качается"
        )
        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()
        #expect(call.transcript.count == 2, "сессия осталась отзывчивой, пока модель качалась")

        await gate.open()
        await call.recognizer.prepared()

        // Модель доехала — следующая реплика уже со словами.
        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()

        #expect(call.transcript.count == 3)
        #expect(call.transcript.last?.text == "расскажите про ваш опыт")
    }

    @Test("Модель не загрузилась совсем — сессия продолжается, а не падает")
    func aModelThatNeverLoadsDoesNotKillTheSession() async {
        let call = RecognitionFixture(
            provider: FakeSpeechModelProvider(download: .failing("нет сети"))
        )

        call.saysSomething(lasting: 1.5, on: .them)
        await call.engine.waitForRecognition()
        #expect(await eventually { await call.recognizer.phase == .failed("нет сети") })

        call.saysSomething(lasting: 1.5, on: .you)
        await call.engine.waitForRecognition()

        #expect(call.transcript.count == 2)
        #expect(call.transcript.allSatisfy { $0.text.isEmpty })
    }

    @Test("Тишина не доходит до распознавания и не тянет модель из сети")
    func silenceNeverReachesTheModel() async {
        let provider = FakeSpeechModelProvider()
        let call = RecognitionFixture(provider: provider)

        call.staysQuiet(for: 5.0, on: .them)
        await call.engine.waitForRecognition()

        #expect(call.transcript.isEmpty)
        #expect(provider.fetched.isEmpty, "модель не должна качаться из-за пустой комнаты")
    }
}

// MARK: - Загрузка модели

@Suite("Загрузка модели распознавания")
@MainActor
struct SpeechModelLoadingTests {

    @Test("Пока модель качается, состояние проходит все ступени и заканчивается готовностью")
    func phasesRunFromDownloadToReady() async {
        let recognizer = WhisperSpeechRecognizer(
            model: .base,
            provider: FakeSpeechModelProvider(download: .reporting([0.2, 0.6, 1.0]))
        )

        let updates = await recognizer.phaseUpdates()
        await recognizer.prepare()
        await recognizer.prepared()

        var seen: [SpeechModelPhase] = []
        for await phase in updates {
            seen.append(phase)
            if phase == .ready { break }
        }

        #expect(seen.first == .idle)
        #expect(seen.last == .ready)
        #expect(seen.contains(.loading))
        #expect(seen.contains { if case .downloading = $0 { return true } else { return false } })
    }

    @Test("Сообщение о состоянии человекочитаемо и показывает проценты")
    func phaseDescribesItselfForTheWindow() {
        #expect(SpeechModelPhase.downloading(fraction: 0.42).summary.contains("42"))
        #expect(SpeechModelPhase.failed("нет сети").summary.contains("нет сети"))
        #expect(SpeechModelPhase.downloading(fraction: 0.5).isBusy)
        #expect(SpeechModelPhase.ready.isReady)
        #expect(!SpeechModelPhase.failed("нет сети").isBusy)
    }

    @Test("Повторный запрос загрузки не запускает вторую скачку")
    func preparingTwiceFetchesOnce() async {
        let provider = FakeSpeechModelProvider()
        let recognizer = WhisperSpeechRecognizer(model: .base, provider: provider)

        await recognizer.prepare()
        await recognizer.prepared()
        await recognizer.prepare()
        await recognizer.prepared()

        #expect(provider.fetched == [.base])
    }

    @Test("Сорвавшуюся загрузку можно повторить, не перезапуская приложение")
    func aFailedDownloadCanBeRetried() async {
        let provider = FakeSpeechModelProvider(download: .failing("нет сети"))
        let recognizer = WhisperSpeechRecognizer(model: .base, provider: provider)

        await recognizer.prepare()
        await recognizer.prepared()
        #expect(await recognizer.phase == .failed("нет сети"))

        await recognizer.prepare()
        await recognizer.prepared()
        #expect(provider.fetched == [.base, .base])
    }

    @Test("Смена модели сбрасывает загруженную и не оставляет старую в работе")
    func switchingModelDropsTheLoadedOne() async {
        let provider = FakeSpeechModelProvider(transcription: { _ in "готово" })
        let recognizer = WhisperSpeechRecognizer(model: .base, provider: provider)

        await recognizer.prepare()
        await recognizer.prepared()
        #expect(await recognizer.phase == .ready)

        await recognizer.use(.small)

        #expect(await recognizer.model == .small)
        #expect(await recognizer.phase == .idle)

        await recognizer.prepare()
        await recognizer.prepared()
        #expect(provider.fetched == [.base, .small])
    }
}

// MARK: - Выбор модели

@Suite("Выбор модели распознавания")
@MainActor
struct SpeechModelSelectionTests {

    @Test("В списке нет ни одной одноязычной модели: русский не требует отдельной настройки")
    func everyOfferedModelIsMultilingual() {
        for model in WhisperModel.allCases {
            #expect(
                !model.variant.contains(".en"),
                "\(model.variant) понимает только английский — такой выбор пришлось бы переключать посреди звонка"
            )
        }
        #expect(WhisperModel.allCases.contains(.default))
        #expect(WhisperModel.requiredSampleRate == 16_000)
    }

    @Test("Выбранная модель переживает перезапуск приложения")
    func chosenModelSurvivesRestart() async {
        await withTemporaryDefaults { defaults in
            let first = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(first.speechModel == .default)
            first.speechModel = .small

            // Второе хранилище над теми же defaults — это и есть перезапуск.
            let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(second.speechModel == .small)
        }
    }

    @Test("Незнакомое значение в настройках откатывается к модели по умолчанию")
    func unknownStoredModelFallsBackToTheDefault() async {
        await withTemporaryDefaults { defaults in
            defaults.set(try? JSONEncoder().encode("модель-которой-нет"), forKey: "settings.speechModel")

            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(store.speechModel == .default)
        }
    }

    @Test("Выбор модели в настройках доезжает до распознавания")
    func choosingAModelReachesTheRecognizer() async {
        await withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let status = SpeechModelStatus(store: store, provider: FakeSpeechModelProvider())

            status.model = .small

            #expect(store.speechModel == .small, "выбор попал в настройки")
            #expect(await eventually { await status.recognizer.model == .small })
        }
    }

    @Test("Модель не начинает качаться сама, только по явной команде")
    func nothingIsDownloadedUntilAsked() async {
        await withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let provider = FakeSpeechModelProvider()
            let status = SpeechModelStatus(store: store, provider: provider)

            status.model = .small
            #expect(provider.fetched.isEmpty, "смена модели не должна тянуть гигабайты сама по себе")

            status.prepare()
            #expect(await eventually { provider.fetched == [.small] })
        }
    }

    @Test("Прогресс загрузки виден в интерфейсе")
    func progressReachesTheInterface() async {
        await withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let gate = Gate()
            let status = SpeechModelStatus(
                store: store,
                provider: FakeSpeechModelProvider(download: .held(gate))
            )

            status.prepare()
            #expect(await eventually { status.phase == .downloading(fraction: 0.25) })

            await gate.open()
            #expect(await eventually { status.phase == .ready })
        }
    }

    @Test("Изменение модели видно наблюдателю сразу, без перезапуска")
    func modelChangeIsObservable() async {
        await withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let notified = MutableBox(false)

            withObservationTracking {
                _ = store.speechModel
            } onChange: {
                notified.value = true
            }

            store.speechModel = .tiny
            #expect(notified.value)
        }
    }
}

// MARK: - Приведение звука к тому, что нужно модели

@Suite("Звук на входе распознавания")
struct SpeechAudioTests {

    @Test("Звук источника с чужой частотой приводится к 16 кГц")
    func audioIsResampledToWhatTheModelNeeds() {
        let sourceRate: Double = 48_000
        let seconds = 0.5
        let samples = (0..<Int(sourceRate * seconds)).map { index in
            Float(sin(Double(index) * 0.01))
        }

        let resampled = SpeechAudio(samples: samples, sampleRate: sourceRate)
            .resampled(to: WhisperModel.requiredSampleRate)

        #expect(resampled.count == Int(WhisperModel.requiredSampleRate * seconds))
        #expect(resampled.first == samples.first)
    }

    @Test("Звук, уже пришедший на нужной частоте, не пересчитывается")
    func audioAtTheRightRateIsLeftAlone() {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let audio = SpeechAudio(samples: samples, sampleRate: WhisperModel.requiredSampleRate)

        #expect(audio.resampled(to: WhisperModel.requiredSampleRate) == samples)
    }

    @Test("Пустая реплика не доходит до модели")
    func emptyAudioIsRefused() async {
        let recognizer = WhisperSpeechRecognizer(
            model: .base,
            provider: FakeSpeechModelProvider(transcription: { _ in "не должно быть вызвано" })
        )
        await recognizer.prepare()
        await recognizer.prepared()

        await #expect(throws: WhisperSpeechRecognizer.RecognitionError.emptyAudio) {
            try await recognizer.transcribe(SpeechAudio(samples: [], sampleRate: 16_000))
        }
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

private final class MutableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
