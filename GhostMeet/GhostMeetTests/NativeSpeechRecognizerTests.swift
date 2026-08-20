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
