import AVFoundation
import Foundation
import Testing
@testable import GhostMeet

/// Пока режим устройства переключали мы сами, переживать было нечего. С ADR-0009
/// его переключает кто угодно — Phone, WhatsApp, Teams, — и замерено на стенде:
/// потребитель без подписки получает **ноль кадров** с этого момента и не
/// восстанавливается даже после того, как виновник вышел.
@Suite("Захват переживает чужую смену конфигурации устройства")
struct CaptureRecoveryTests {

    /// Считает попытки и рассказывает, чем каждая кончилась.
    private final class Bench: @unchecked Sendable {
        /// Сколько первых попыток обязаны провалиться.
        var failuresLeft: Int
        private(set) var restarts = 0
        private(set) var reported: [MicCaptureStatus] = []
        private let lock = NSLock()

        init(failuresLeft: Int = 0) {
            self.failuresLeft = failuresLeft
        }

        func restart() throws {
            lock.lock()
            restarts += 1
            let mustFail = failuresLeft > 0
            if mustFail { failuresLeft -= 1 }
            lock.unlock()
            if mustFail {
                throw MicCaptureService.CaptureError.inputFormatUnavailable
            }
        }

        func report(_ status: MicCaptureStatus) {
            lock.lock()
            reported.append(status)
            lock.unlock()
        }

        var statuses: [MicCaptureStatus] {
            lock.lock()
            defer { lock.unlock() }
            return reported
        }
    }

    /// Задержки не выжидаются: проверяется правило попыток, а не таймер.
    private static let immediately: CaptureRecovery.Scheduler = { _, work in work() }

    /// Отложенные шаги, которые тест запускает руками.
    ///
    /// Нужен там, где важно, что попытка **ещё не закончилась**: восстановление
    /// ждёт свою задержку, и именно в этот промежуток приходят остальные
    /// уведомления той же самой смены устройства.
    private final class Steps: @unchecked Sendable {
        private var queue: [@Sendable () -> Void] = []
        private let lock = NSLock()

        var scheduler: CaptureRecovery.Scheduler {
            { [self] _, work in
                lock.lock()
                queue.append(work)
                lock.unlock()
            }
        }

        var pending: Int {
            lock.lock()
            defer { lock.unlock() }
            return queue.count
        }

        /// Выполняет всё запланированное, включая то, что появится по ходу.
        func drain() {
            while true {
                lock.lock()
                let next = queue.isEmpty ? nil : queue.removeFirst()
                lock.unlock()
                guard let next else { return }
                next()
            }
        }
    }

    private func recovery(
        bench: Bench,
        delays: [TimeInterval] = [0.1, 0.5, 1.5]
    ) -> CaptureRecovery {
        CaptureRecovery(
            delays: delays,
            schedule: Self.immediately,
            restart: { try bench.restart() },
            report: { bench.report($0) }
        )
    }

    @Test("Уведомление о смене конфигурации поднимает захват заново")
    func aConfigurationChangeRestartsCapture() {
        let bench = Bench()
        let recovery = recovery(bench: bench)
        let engine = AVAudioEngine()
        recovery.watch(engine)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        #expect(bench.restarts == 1)
        #expect(bench.statuses == [.restarting(attempt: 1), .capturing])
        recovery.stopWatching()
    }

    @Test("Устройство возвращается не сразу — попытки продолжаются до успеха")
    func aDeviceThatComesBackLateIsWaitedFor() {
        // Воткнули наушники посреди звонка: первая попытка приходится на момент,
        // когда устройство ещё договаривается, и падает.
        let bench = Bench(failuresLeft: 2)
        let recovery = recovery(bench: bench)
        recovery.configurationChanged()

        #expect(bench.restarts == 3)
        #expect(bench.statuses.last == .capturing)
        #expect(bench.statuses.filter(\.isFailure).isEmpty, "устройство вернулось — говорить не о чем")
    }

    @Test("Исчерпание попыток даёт видимое состояние, а не тишину")
    func anExhaustedBudgetIsSaidOutLoud() {
        let bench = Bench(failuresLeft: 99)
        let recovery = recovery(bench: bench, delays: [0.1, 0.5, 1.5])
        recovery.configurationChanged()

        // Ровно столько попыток, сколько задержек: сыпать ими до конца звонка
        // хуже, чем один раз честно сказать, что микрофон не вернулся.
        #expect(bench.restarts == 3)
        guard case .lost(let reason) = bench.statuses.last else {
            Issue.record("после исчерпания попыток состояние обязано быть видимым: \(bench.statuses)")
            return
        }
        #expect(reason == CaptureRecovery.lostMessage)
        #expect(!reason.isEmpty)
    }

    @Test("Пачка уведомлений об одной смене устройства — одно восстановление")
    func aBurstOfNotificationsRestartsOnce() {
        // Одно переключение устройства порождает несколько уведомлений подряд;
        // три уведомления не должны стать тремя гонками за один и тот же движок.
        let bench = Bench(failuresLeft: 1)
        let steps = Steps()
        let recovery = CaptureRecovery(
            delays: [0.1, 0.5, 1.5],
            schedule: steps.scheduler,
            restart: { try bench.restart() },
            report: { bench.report($0) }
        )
        let engine = AVAudioEngine()
        recovery.watch(engine)

        for _ in 0..<3 {
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
        }

        // Пока задержка первой попытки не вышла, движка никто не трогал.
        #expect(bench.restarts == 0)
        #expect(steps.pending == 1, "три уведомления запланировали одну попытку, а не три")

        steps.drain()

        // Первая попытка провалилась, вторая подняла захват. Уведомления два и
        // три пришли, пока восстановление шло, и ничего не добавили.
        #expect(bench.restarts == 2)
        #expect(bench.statuses.last == .capturing)
        recovery.stopWatching()
    }

    @Test("Остановка захвата снимает подписку — чужая смена больше не поднимает движок")
    func stoppingCaptureUnsubscribes() {
        let bench = Bench()
        let recovery = recovery(bench: bench)
        let engine = AVAudioEngine()
        recovery.watch(engine)
        recovery.stopWatching()

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        #expect(bench.restarts == 0)
        #expect(bench.statuses.isEmpty)
    }

    @Test("Смена конфигурации чужого движка нас не касается")
    func onlyOurOwnEngineIsWatched() {
        let bench = Bench()
        let recovery = recovery(bench: bench)
        let ours = AVAudioEngine()
        let theirs = AVAudioEngine()
        recovery.watch(ours)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: theirs
        )

        #expect(bench.restarts == 0)
        recovery.stopWatching()
    }

    @Test("У каждого состояния микрофона есть текст для пользователя")
    func everyStatusExplainsItself() {
        let statuses: [MicCaptureStatus] = [
            .idle,
            .capturing,
            .restarting(attempt: 2),
            .lost(reason: CaptureRecovery.lostMessage),
        ]
        for status in statuses {
            #expect(!status.message.isEmpty, "\(status) молчит, а молчание читается как исправность")
        }
        #expect(MicCaptureStatus.restarting(attempt: 2).message.contains("2"))
        #expect(!MicCaptureStatus.capturing.isFailure)
        #expect(MicCaptureStatus.lost(reason: "x").isFailure)
    }
}

/// Что сессия делает с тем, что рассказал микрофон.
@MainActor
@Suite("Сессия видит перезапуск микрофона")
struct MicStatusInSessionTests {

    private func controller() -> SessionController {
        SessionController(engine: SessionEngine(clock: ManualClock()))
    }

    @Test("Перезапуск дозакрывает открытую реплику, а не теряет её молча")
    func aRestartClosesTheOpenTurn() {
        let clock = ManualClock()
        let engine = SessionEngine(recognizer: RecognizerSpy(reply: ""), clock: clock)
        let controller = SessionController(engine: engine)

        // Пользователь говорит; реплика открыта и паузой ещё не закрыта.
        for _ in 0..<4 {
            clock.advance(by: 0.1)
            engine.ingest(AudioFrames.speech(channel: .you, duration: 0.1))
        }
        #expect(engine.transcript.isEmpty)

        controller.apply(micStatus: .restarting(attempt: 1))

        #expect(engine.transcript.count == 1, "речь до перезапуска обязана доехать до транскрипта")
        #expect(engine.transcript.first?.channel == .you)
    }

    @Test("Микрофон не вернулся — в окне появляется причина")
    func aLostMicrophoneBecomesAVisibleFailure() {
        let controller = controller()

        controller.apply(micStatus: .lost(reason: CaptureRecovery.lostMessage))

        #expect(controller.failure == .captureFailed(CaptureRecovery.lostMessage))
        #expect(controller.failure?.isPermissionDenied == false)
        #expect(controller.failure?.message.isEmpty == false)
    }

    @Test("Микрофон вернулся — причина из окна убирается")
    func aRecoveredMicrophoneClearsTheFailure() {
        let controller = controller()
        controller.apply(micStatus: .lost(reason: CaptureRecovery.lostMessage))

        controller.apply(micStatus: .capturing)

        #expect(controller.failure == nil)
        #expect(controller.micStatus == .capturing)
    }

    @Test("Запрет доступа к микрофону перезапуском не стирается")
    func aDeniedMicrophoneOutranksARecovery() async {
        // Отказ в доступе чинится в «Системных настройках» и живёт дольше любой
        // смены устройства: стереть его успешным перезапуском значило бы убрать
        // с экрана единственную подсказку, которую пользователь может выполнить.
        let controller = SessionController(
            engine: SessionEngine(sources: [], clock: ManualClock()),
            requestMicrophoneAccess: { false }
        )
        controller.start()
        await controller.waitForStart()
        #expect(controller.failure == .microphoneDenied)

        controller.apply(micStatus: .capturing)

        #expect(controller.failure == .microphoneDenied)
    }
}

/// Что пользователь увидит вместо голого кода Core Audio.
///
/// Живой прогон дал `10868` посреди окна и ничего больше — человек с таким
/// числом сделать не может ничего. Разбор кодов проверяется здесь, потому что
/// сам отказ движка воспроизводится только сменой устройства руками.
@Suite("Отказ микрофона объяснён словами")
struct MicCaptureErrorTests {

    @Test("Смена устройства объясняется и говорит, что делать")
    func theDeviceSwitchRefusalIsExplained() {
        let text = MicCaptureService.CaptureError.engineExplanation(-10868)

        #expect(text.contains("10868"), "код остаётся: по нему ищут в интернете")
        #expect(text.contains("сменился"), "названа причина, а не только номер")
        #expect(
            text.contains("прослушивание"),
            "названо действие: без него сообщение — это жалоба, а не помощь"
        )
    }

    @Test("Незнакомый код не притворяется знакомым")
    func anUnknownCodeStaysHonest() {
        let text = MicCaptureService.CaptureError.engineExplanation(-12345)

        #expect(text.contains("-12345"))
        #expect(!text.contains("наушники"), "не выдумываем причину, которой не знаем")
    }

    @Test("Отсутствие устройства ввода — отдельный случай")
    func aMissingInputDeviceIsItsOwnCase() {
        #expect(MicCaptureService.CaptureError.engineExplanation(-10877).contains("не найдено"))
    }
}

@Suite("Восстановление не реагирует на собственную перенастройку")
struct RecoverySuppressionTests {

    /// Замер на живом API: назначение устройства входному узлу порождает ровно
    /// одно `AVAudioEngineConfigurationChange`. Оно приходит после того, как
    /// перезапуск закончился, — и запускает следующий, который снова назначает.
    /// Вживую это вышло потоком реплик `You` по 0.08 с без единого слова.
    @Test("Уведомление, вызванное нами, не запускает восстановление")
    func ourOwnChangeIsIgnored() async {
        let restarted = Counter()
        let recovery = CaptureRecovery(
            delays: [0],
            restart: { restarted.increment() },
            report: { _ in }
        )

        recovery.suppressChanges(for: 1)
        recovery.configurationChanged()

        try? await Task.sleep(for: .milliseconds(150))
        #expect(restarted.value == 0, "перезапуск случился по нашему же уведомлению")
    }

    /// Окно, а не счётчик: пропущенное уведомление стоит одной задержки, а
    /// застрявший счётчик оглушил бы канал до конца звонка.
    @Test("После окна настоящая смена устройства снова слышна")
    func arealChangeStillWorks() async {
        let restarted = Counter()
        let recovery = CaptureRecovery(
            delays: [0],
            restart: { restarted.increment() },
            report: { _ in }
        )

        recovery.suppressChanges(for: 0.05)
        try? await Task.sleep(for: .milliseconds(120))
        recovery.configurationChanged()

        // Ожидание условия, а не фиксированная пауза: под параллельным прогоном
        // перезапуск с нулевой задержкой один раз не уложился в 200 мс, и тест
        // упал на гонке, которой в коде нет.
        var waited: Duration = .zero
        while restarted.value == 0, waited < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        #expect(restarted.value == 1, "настоящая смена устройства должна восстанавливать канал")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
