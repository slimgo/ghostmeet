//
//  NativeSpeechRecognizerTests.swift
//  GhostMeetTests
//

import AVFoundation
import Foundation
import Speech
import Testing
@testable import GhostMeet

/// Stands in for the system's asset store.
///
/// Exists so these tests never touch `AssetInventory`: reaching it on a clean
/// machine downloads a language pack, and a suite that downloads a language pack
/// is a suite nobody can run.
@available(macOS 26, *)
private struct AssetsSpy: SpeechAssetInstaller {
    var known: Set<String> = ["ru-RU", "en-US"]
    var failure: (any Error)?

    func supports(_ locale: Locale) async -> Bool {
        known.contains(locale.identifier(.bcp47))
    }

    func install(_ locale: Locale) async throws {
        if let failure { throw failure }
    }
}

private struct InstallFailed: LocalizedError {
    var errorDescription: String? { "ассеты не встали" }
}

/// Доступность проверяется **в теле каждого теста**, а не на сюите: `@Suite`
/// и `@available` несовместимы — макрос Testing отказывается разворачиваться на
/// типе с ограничением по версии. На macOS младше 26 такой тест выходит сразу,
/// и это честно: проверять там нечего, движка не существует.
@Suite("Системный распознаватель: подготовка")
struct NativeSpeechPreparationTests {

    @Test("До установки ассетов реплика возвращается без слов, а не ждёт")
    func aTurnBeforeReadinessIsRefused() async throws {
        guard #available(macOS 26, *) else { return }

        let recognizer = NativeSpeechRecognizer(locale: Locale(identifier: "ru-RU"), assets: AssetsSpy())
        let audio = SpeechAudio(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)

        await #expect(throws: NativeSpeechRecognizer.RecognitionError.self) {
            _ = try await recognizer.transcribe(audio)
        }
    }

    /// Та же сделка, что у Whisper: реплика, запустившая установку, слов не
    /// получает — но следующие получают, потому что она же установку и начала.
    @Test("Отказанная реплика запускает подготовку")
    func arefusedTurnStartsPreparation() async throws {
        guard #available(macOS 26, *) else { return }

        let recognizer = NativeSpeechRecognizer(locale: Locale(identifier: "ru-RU"), assets: AssetsSpy())
        let audio = SpeechAudio(samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)

        _ = try? await recognizer.transcribe(audio)
        await recognizer.prepared()

        #expect(await recognizer.phase == .ready)
    }

    @Test("Язык, которого система не знает, называется прямо")
    func anUnknownLocaleIsNamed() async throws {
        guard #available(macOS 26, *) else { return }

        let recognizer = NativeSpeechRecognizer(
            locale: Locale(identifier: "xx-XX"),
            assets: AssetsSpy()
        )
        await recognizer.prepare()
        await recognizer.prepared()

        guard case .failed(let message) = await recognizer.phase else {
            Issue.record("ожидался отказ, а фаза \(await recognizer.phase)")
            return
        }
        #expect(message.contains("xx-XX"))
    }

    @Test("Сорвавшаяся установка оставляет причину, а не тишину")
    func aFailedInstallSaysWhy() async throws {
        guard #available(macOS 26, *) else { return }

        let recognizer = NativeSpeechRecognizer(
            locale: Locale(identifier: "ru-RU"),
            assets: AssetsSpy(failure: InstallFailed())
        )
        await recognizer.prepare()
        await recognizer.prepared()

        #expect(await recognizer.phase == .failed("ассеты не встали"))
    }

    @Test("Смена языка сбрасывает готовность")
    func switchingLocaleResetsReadiness() async throws {
        guard #available(macOS 26, *) else { return }

        let recognizer = NativeSpeechRecognizer(locale: Locale(identifier: "ru-RU"), assets: AssetsSpy())
        await recognizer.prepare()
        await recognizer.prepared()
        #expect(await recognizer.phase == .ready)

        await recognizer.use(Locale(identifier: "en-US"))
        #expect(await recognizer.phase == .idle)
        #expect(await recognizer.locale == Locale(identifier: "en-US"))
    }

    @Test("Пустая реплика не доходит до движка")
    func emptyAudioIsRejected() async throws {
        guard #available(macOS 26, *) else { return }

        let recognizer = NativeSpeechRecognizer(locale: Locale(identifier: "ru-RU"), assets: AssetsSpy())
        await recognizer.prepare()
        await recognizer.prepared()

        await #expect(throws: NativeSpeechRecognizer.RecognitionError.emptyAudio) {
            _ = try await recognizer.transcribe(SpeechAudio(samples: [], sampleRate: 16_000))
        }
    }
}

@Suite("Системный распознаватель: формат звука")
struct NativeSpeechAudioFormatTests {

    /// **Главная ловушка этого движка, и она из `docs/audio-traps.md`.** Он
    /// просит 16 кГц Int16, а конвейер несёт Float32: отданные как есть сэмплы
    /// не дадут ошибки — они дадут тишину.
    @Test("Float32 приводится к тому, что просит движок, и звук не теряется")
    func float32IsConvertedToWhatTheEngineAsks() throws {
        guard #available(macOS 26, *) else { return }

        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let samples = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let audio = SpeechAudio(samples: samples, sampleRate: 16_000)

        let buffer = try #require(NativeSpeechRecognizer.buffer(from: audio, in: target))
        #expect(buffer.format.commonFormat == .pcmFormatInt16)
        #expect(buffer.frameLength == 16_000)

        let channel = try #require(buffer.int16ChannelData)
        let loudest = (0..<Int(buffer.frameLength)).map { abs(Int(channel[0][$0])) }.max() ?? 0
        #expect(loudest > 1_000, "конверсия отдала тишину — та самая ловушка")
    }

    @Test("Частота приводится к запрошенной")
    func sampleRateIsResampled() throws {
        guard #available(macOS 26, *) else { return }

        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let audio = SpeechAudio(
            samples: (0..<48_000).map { Float(sin(Double($0) * 0.02)) * 0.5 },
            sampleRate: 48_000
        )

        let buffer = try #require(NativeSpeechRecognizer.buffer(from: audio, in: target))
        #expect(buffer.format.sampleRate == 16_000)
        // Секунда звука остаётся секундой: ±5% на хвосты ресемплера.
        #expect(abs(Int(buffer.frameLength) - 16_000) < 800)
    }

    @Test("Формат, совпадающий с нашим, проходит без конверсии")
    func matchingFormatIsPassedThrough() throws {
        guard #available(macOS 26, *) else { return }

        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let audio = SpeechAudio(samples: [Float](repeating: 0.25, count: 800), sampleRate: 16_000)

        let buffer = try #require(NativeSpeechRecognizer.buffer(from: audio, in: target))
        #expect(buffer.frameLength == 800)
        #expect(buffer.floatChannelData?[0][0] == 0.25)
    }
}

@Suite("Выбор движка распознавания")
struct SpeechEngineChoiceTests {

    @Test("Whisper есть всегда, системный — только на macOS 26")
    func availabilityFollowsTheSystem() {
        #expect(SpeechEngine.whisper.isAvailable)
        if #available(macOS 26, *) {
            #expect(SpeechEngine.system.isAvailable)
            #expect(SpeechEngine.available.count == 2)
        } else {
            #expect(SpeechEngine.system.isAvailable == false)
            #expect(SpeechEngine.available == [.whisper])
        }
    }

    /// Язык нужен только системному движку: Whisper определяет его сам, и
    /// спрашивать про него — предлагать выбор, который ничего не меняет.
    @Test("Язык звонка спрашивается только у системного движка")
    func onlyTheSystemEngineNeedsALanguage() {
        #expect(SpeechEngine.system.needsExplicitLanguage)
        #expect(SpeechEngine.whisper.needsExplicitLanguage == false)
    }

    @Test("Цена выбора названа у обоих движков и не совпадает")
    func bothEnginesStateTheirPrice() {
        for engine in SpeechEngine.allCases {
            #expect(engine.tradeOff.isEmpty == false)
            #expect(engine.displayName.isEmpty == false)
        }
        #expect(SpeechEngine.whisper.tradeOff != SpeechEngine.system.tradeOff)
    }

    @Test("Локали языков — те, что понимает система")
    func languagesMapToLocales() {
        #expect(SpeechLanguage.russian.localeIdentifier == "ru-RU")
        #expect(SpeechLanguage.english.localeIdentifier == "en-US")
    }

    /// Настройки могут приехать с новой системы — например, вместе с домашней
    /// папкой. Движок, которого здесь нет, обязан откатиться, а не остаться
    /// выбранным: распознавание указывало бы на то, чего не существует.
    @Test("Недоступный движок из настроек откатывается к Whisper")
    @MainActor
    func anUnavailableStoredEngineFallsBack() {
        withOwnDefaults { defaults in
            defaults.set(try? JSONEncoder().encode(SpeechEngine.system), forKey: "settings.speechEngine")
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())

            if #available(macOS 26, *) {
                #expect(store.speechEngine == .system)
            } else {
                #expect(store.speechEngine == .whisper)
            }
        }
    }

    @Test("Выбор языка переживает перезапуск")
    @MainActor
    func theChoiceIsRemembered() {
        withOwnDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.interviewLanguage = .english
            #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).interviewLanguage == .english)
        }
    }

    /// Реплика, уже ушедшая в распознавание, остаётся на своём движке: речь в
    /// этом приложении не отменяется, и слова принадлежат транскрипту.
    @Test("Подмена движка не трогает уже начатую реплику")
    func aTurnInFlightKeepsItsEngine() async throws {
        let slow = SlowRecognizer(text: "первый движок")
        let switchable = SwitchableSpeechRecognizer(engine: .whisper, recognizer: slow)
        let audio = SpeechAudio(samples: [0.1, 0.2], sampleRate: 16_000)

        async let inFlight = switchable.transcribe(audio)
        await slow.waitUntilStarted()
        await switchable.swap(to: .whisper, recognizer: SlowRecognizer(text: "второй движок", released: true))
        await slow.release()

        #expect(try await inFlight == "первый движок")
        #expect(try await switchable.transcribe(audio) == "второй движок")
    }
}

/// Распознаватель, который ждёт, пока его отпустят.
private actor SlowRecognizer: SpeechRecognizer {
    private let text: String
    private var started: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var isReleased = false

    /// `released: true` — распознаватель, который не задерживается: второй в
    /// тесте нужен только чтобы ответить, и ждущий отпускания повесил бы прогон.
    init(text: String, released: Bool = false) {
        self.text = text
        self.isReleased = released
    }

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        hasStarted = true
        started?.resume()
        started = nil
        if !isReleased {
            await withCheckedContinuation { gate = $0 }
        }
        return text
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }
}


/// Свой изолированный домен настроек: одноимённый помощник в соседнем файле
/// объявлен `private`, а два теста, делящих домен, портят друг другу состояние.
private func withOwnDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "GhostMeetSpeechEngineTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(defaults)
}

@Suite("Язык собеседования объявляется, а не угадывается")
struct InterviewLanguageTests {

    /// Объявленный язык бьёт письменность транскрипта. Ради этого настройка и
    /// заведена: на живом английском звонке определение по буквам сработало один
    /// раз, а дальше модель отвечала на языке инструкций.
    @Test("Объявленный язык сильнее транскрипта")
    func aDeclaredLanguageBeatsTheScript() {
        let russianTurns = [Turn(channel: .them, text: "Расскажите про очереди сообщений и как вы их масштабировали", timestamp: 0, duration: 3)]
        #expect(InterviewLanguage.english.conversation(given: russianTurns) == .english)

        let englishTurns = [Turn(channel: .them, text: "Tell me how you scaled the message queues in that project", timestamp: 0, duration: 3)]
        #expect(InterviewLanguage.russian.conversation(given: englishTurns) == .russian)
    }

    @Test("Авто ведёт себя ровно как прежнее определение")
    func autoMatchesDetection() {
        for turns in [
            [Turn(channel: .them, text: "Расскажите про очереди сообщений и как вы их масштабировали", timestamp: 0, duration: 3)],
            [Turn(channel: .them, text: "Tell me how you scaled the message queues in that project", timestamp: 0, duration: 3)],
            [Turn]()
        ] {
            #expect(InterviewLanguage.automatic.conversation(given: turns)
                    == ConversationLanguage.detected(in: turns))
        }
    }

    /// Системный распознаватель язык не определяет, поэтому «авто» обязано дать
    /// ему конкретный — иначе он молча слушает не тот.
    @Test("Даже на авто у распознавателя есть язык")
    func autoStillGivesTheRecogniserALanguage() {
        for language in InterviewLanguage.allCases {
            #expect(SpeechLanguage.allCases.contains(language.spoken))
        }
    }

    @Test("Выбор языка переживает перезапуск")
    @MainActor
    func theChoiceSurvivesARestart() {
        withOwnDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(store.interviewLanguage == .automatic, "по умолчанию — авто")

            store.interviewLanguage = .english
            #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()).interviewLanguage == .english)
        }
    }

    @Test("У каждого значения есть имя и объяснение, и они разные")
    func everyChoiceExplainsItself() {
        let explanations = Set(InterviewLanguage.allCases.map(\.explanation))
        #expect(explanations.count == InterviewLanguage.allCases.count)
        for language in InterviewLanguage.allCases {
            #expect(language.displayName.isEmpty == false)
        }
    }
}
