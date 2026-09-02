//
//  ConnectionCheckTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

@MainActor
private final class CheckSourceSpy: ConnectionCheckSource {
    var isListening = true
    var probe = CaptureProbe()
    var providerAnswer: Result<String, any Error> = .success("ok")
    var recognitionPhase: SpeechModelPhase = .ready
    var granted: (microphone: Bool, screen: Bool) = (true, true)
    private(set) var measuredFor: TimeInterval?

    func measureChannels(for seconds: TimeInterval) async -> CaptureProbe {
        measuredFor = seconds
        return probe
    }

    func askProvider() async -> Result<String, any Error> { providerAnswer }

    func permissions() async -> (microphone: Bool, screen: Bool) { granted }
}

private struct Unreachable: LocalizedError {
    var errorDescription: String? { "сеть недоступна" }
}

private func frame(_ channel: Channel, level: Float, count: Int = 512) -> AudioFrame {
    AudioFrame(channel: channel, samples: [Float](repeating: level, count: count), sampleRate: 16_000)
}

@Suite("Проверка связи")
@MainActor
struct ConnectionCheckTests {

    private func outcome(_ results: [CheckResult], _ subject: CheckResult.Subject) -> CheckResult.Outcome? {
        results.first { $0.subject == subject }?.outcome
    }

    @Test("Всё живо — пять строк, все зелёные")
    func everythingWorks() async {
        let spy = CheckSourceSpy()
        var probe = CaptureProbe()
        probe.take(frame(.you, level: 0.4))
        probe.take(frame(.them, level: 0.3))
        spy.probe = probe

        let results = await ConnectionCheck(source: spy).run()

        #expect(results.count == CheckResult.Subject.allCases.count)
        #expect(results.allSatisfy { $0.outcome == .works })
    }

    /// Ровно тот отказ, ради которого проверка написана: захват числится
    /// запущенным, кадры не приходят, приложение молчит.
    @Test("Канал без единого кадра — это поломка, а не тишина")
    func aChannelWithNoFramesIsBroken() async {
        let spy = CheckSourceSpy()
        var probe = CaptureProbe()
        probe.take(frame(.them, level: 0.3))   // собеседник слышен
        spy.probe = probe                       // а микрофон не прислал ничего

        let results = await ConnectionCheck(source: spy).run()

        #expect(outcome(results, .microphone) == .broken)
        #expect(outcome(results, .them) == .works)
        let detail = results.first { $0.subject == .microphone }?.detail ?? ""
        #expect(detail.contains("Стоп"), "строка должна называть то, что помогло вживую")
    }

    /// Кадры идут, а в них нули — молчаливый отказ из `docs/audio-traps.md`.
    /// На живой машине это состояние воспроизвести нечем, поэтому оно и в тесте.
    @Test("Кадры без сигнала не считаются успехом")
    func framesOfSilenceAreNotAPass() async {
        let spy = CheckSourceSpy()
        var probe = CaptureProbe()
        probe.take(frame(.you, level: 0))
        probe.take(frame(.them, level: 0))
        spy.probe = probe

        let results = await ConnectionCheck(source: spy).run()

        #expect(outcome(results, .microphone) == .noSound)
        #expect(outcome(results, .them) == .noSound)
    }

    @Test("Без прослушивания каналы не проверяются, и это сказано")
    func channelsNeedListening() async {
        let spy = CheckSourceSpy()
        spy.isListening = false

        let results = await ConnectionCheck(source: spy).run()

        #expect(outcome(results, .microphone) == .noSound)
        #expect(spy.measuredFor == nil, "мерить нечего — и не мерили")
        #expect(results.first { $0.subject == .microphone }?.detail.contains("Прослушивание") == true)
    }

    @Test("Отказ провайдера назван его же словами и не отменяет остальных")
    func aProviderFailureIsNamed() async {
        let spy = CheckSourceSpy()
        spy.providerAnswer = .failure(Unreachable())
        var probe = CaptureProbe()
        probe.take(frame(.you, level: 0.4))
        probe.take(frame(.them, level: 0.4))
        spy.probe = probe

        let results = await ConnectionCheck(source: spy).run()

        #expect(outcome(results, .provider) == .broken)
        #expect(results.first { $0.subject == .provider }?.detail == "сеть недоступна")
        #expect(outcome(results, .microphone) == .works, "одна поломка не отменяет остальные проверки")
    }

    /// Пустой ответ — не успех: рассуждающая модель тратит бюджет на невидимые
    /// токены и закрывает поток, не сказав ничего.
    @Test("Пустой ответ провайдера — поломка")
    func anEmptyProviderAnswerIsBroken() async {
        let spy = CheckSourceSpy()
        spy.providerAnswer = .success("   ")

        let results = await ConnectionCheck(source: spy).run()
        #expect(outcome(results, .provider) == .broken)
    }

    @Test("Модель на загрузке — ожидание, а не поломка")
    func aLoadingModelIsNotBroken() async {
        let spy = CheckSourceSpy()
        spy.recognitionPhase = .downloading(fraction: 0.3)

        let results = await ConnectionCheck(source: spy).run()
        #expect(outcome(results, .recognition) == .noSound)
    }

    @Test("Каждое отсутствующее разрешение названо отдельно")
    func eachMissingPermissionIsNamed() async {
        for (granted, needle) in [((false, true), "микрофону"), ((true, false), "записи экрана")] {
            let spy = CheckSourceSpy()
            spy.granted = granted
            let results = await ConnectionCheck(source: spy).run()
            #expect(outcome(results, .permissions) == .broken)
            #expect(results.first { $0.subject == .permissions }?.detail.contains(needle) == true)
        }
    }
}

@Suite("Учёт кадров")
struct CaptureProbeTests {

    @Test("Пустой учёт — это «кадров не было»")
    func emptyMeansNoFrames() {
        #expect(CaptureProbe().you.verdict == .noFrames)
    }

    @Test("Кадр из нулей — тишина, а не сигнал")
    func zeroesAreSilence() {
        var probe = CaptureProbe()
        probe.take(frame(.you, level: 0))
        #expect(probe.you.verdict == .silent)
        #expect(probe.them.verdict == .noFrames, "каналы считаются раздельно")
    }

    @Test("Пик берётся по модулю: отрицательная полуволна — тоже звук")
    func peakIgnoresSign() {
        var probe = CaptureProbe()
        probe.take(frame(.you, level: -0.5))
        guard case .sound(let peak) = probe.you.verdict else {
            Issue.record("ожидался звук, а получено \(probe.you.verdict)")
            return
        }
        #expect(abs(peak - 0.5) < 0.0001)
    }

    /// Порог отделяет сигнал от нулей, а не громкую речь от тихой.
    @Test("Порог тишины ниже любой настоящей речи")
    func theFloorIsLow() {
        var probe = CaptureProbe()
        probe.take(frame(.you, level: 0.01))
        #expect(probe.you.verdict == .sound(peak: 0.01))
    }
}
