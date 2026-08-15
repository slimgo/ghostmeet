//
//  SCKCaptureTests.swift
//  GhostMeetTests
//

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// A stand-in for ScreenCaptureKit: the test decides which applications are on
/// offer, whether starting fails, and when a buffer arrives.
private final class FakeThemStream: ThemAudioStream, @unchecked Sendable {

    var onFailure: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var _applications: [ShareableApplication]
    private var _scope: SCKAudioScope?
    private var _onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var _stops = 0
    private var _starts = 0
    private var _failuresRemaining = 0
    private var _failure: Error?

    init(applications: [ShareableApplication] = [], failure: Error? = nil) {
        _applications = applications
        _failure = failure
    }

    /// What the next attach does. Settable so a scenario can break the stream
    /// and then let it come back — which is the whole shape of a recovery.
    var failure: Error? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _failure
        }
        set {
            lock.lock()
            _failure = newValue
            lock.unlock()
        }
    }

    /// Applications ScreenCaptureKit is currently offering.
    var applications: [ShareableApplication] {
        get {
            lock.lock(); defer { lock.unlock() }
            return _applications
        }
        set {
            lock.lock()
            _applications = newValue
            lock.unlock()
        }
    }

    /// The stream dies under the service, the way `SCStream` reports it.
    func breaks(with error: Error) {
        lock.lock()
        let handler = onFailure
        _onBuffer = nil
        lock.unlock()
        handler?(error)
    }

    func shareableApplications() async throws -> [ShareableApplication] {
        lock.lock(); defer { lock.unlock() }
        if let _failure { throw _failure }
        return _applications
    }

    func start(
        scope: SCKAudioScope,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        lock.lock()
        _starts += 1
        // A scripted run of failures: the first `_failuresRemaining` attempts
        // refuse, the ones after that work. Lets a scenario check the retry rule
        // itself instead of racing a flag.
        var failure = _failure
        if _failuresRemaining > 0 {
            _failuresRemaining -= 1
            failure = failure ?? StreamBroke()
        }
        if failure == nil {
            _scope = scope
            _onBuffer = onBuffer
        }
        lock.unlock()
        if let failure { throw failure }
    }

    func stop() {
        lock.lock()
        _stops += 1
        _onBuffer = nil
        lock.unlock()
    }

    var startedScope: SCKAudioScope? {
        lock.lock(); defer { lock.unlock() }
        return _scope
    }

    var stops: Int {
        lock.lock(); defer { lock.unlock() }
        return _stops
    }

    /// How many times the service tried to attach a stream.
    var starts: Int {
        lock.lock(); defer { lock.unlock() }
        return _starts
    }

    /// Makes the next `count` attach attempts refuse.
    func refuseNextAttempts(_ count: Int) {
        lock.lock()
        _failuresRemaining = count
        lock.unlock()
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = _onBuffer
        lock.unlock()
        handler?(buffer)
    }
}

/// Collects the frames a source hands over.
private final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [AudioFrame] = []

    var handler: AudioFrameHandler {
        { [self] frame in
            lock.lock()
            _frames.append(frame)
            lock.unlock()
        }
    }

    var frames: [AudioFrame] {
        lock.lock(); defer { lock.unlock() }
        return _frames
    }
}

// MARK: - Fixtures

private enum Fixtures {
    static let chrome = ShareableApplication(
        processIdentifier: 14827,
        bundleIdentifier: "com.google.Chrome",
        name: "Google Chrome",
        executableURL: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    )

    static let chromeHelper = ShareableApplication(
        processIdentifier: 14881,
        bundleIdentifier: "com.google.Chrome.helper",
        name: "Google Chrome Helper (Renderer)",
        executableURL: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/150.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
    )

    static let canary = ShareableApplication(
        processIdentifier: 900,
        bundleIdentifier: "com.google.ChromeCanary",
        name: "Google Chrome Canary",
        executableURL: URL(fileURLWithPath: "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary")
    )

    /// A bare command-line player: no bundle identifier, no application bundle.
    static let afplay = ShareableApplication(
        processIdentifier: 85885,
        bundleIdentifier: nil,
        name: "afplay",
        executableURL: URL(fileURLWithPath: "/usr/bin/afplay")
    )
}

/// One buffer of a sine, in the shape ScreenCaptureKit hands over after mixdown.
private func sineBuffer(
    sampleRate: Double = 48_000,
    frames: AVAudioFrameCount = 4_800
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for index in 0..<Int(frames) {
        samples[index] = sin(2 * .pi * 440 * Float(index) / Float(sampleRate)) * 0.5
    }
    return buffer
}

// MARK: - Опознание приложения-источника

@Suite("ScreenCaptureKit находит выбранное приложение")
struct ShareableApplicationMatchingTests {

    @Test("Браузер опознаётся по bundle-идентификатору")
    func theBrowserIsFoundByItsBundleIdentifier() {
        #expect(Fixtures.chrome.matches(sourceApplicationID: "com.google.Chrome"))
    }

    @Test("Вспомогательные процессы браузера считаются тем же приложением")
    func helpersBelongToTheirBrowser() {
        #expect(Fixtures.chromeHelper.matches(sourceApplicationID: "com.google.Chrome"))
    }

    @Test("Похожий идентификатор чужого приложения не присваивается браузеру")
    func aSeparateApplicationIsNotSwallowedByAPrefix() {
        #expect(!Fixtures.canary.matches(sourceApplicationID: "com.google.Chrome"))
    }

    @Test("Процесс без bundle-идентификатора опознаётся по исполняемому файлу")
    func bareProcessesAreIdentifiedByExecutable() {
        // Тот же вид идентификатора, который выдаёт список Core Audio, — иначе
        // приложение можно было бы выбрать и нельзя найти.
        #expect(Fixtures.afplay.matches(sourceApplicationID: "/usr/bin/afplay"))
    }

    @Test("Приложение опознаётся и по пути до своего .app")
    func applicationsAreIdentifiedByTheirBundlePath() {
        #expect(Fixtures.chrome.matches(sourceApplicationID: "/Applications/Google Chrome.app"))
        #expect(Fixtures.chromeHelper.matches(sourceApplicationID: "/Applications/Google Chrome.app"))
    }

    @Test("Пустой выбор не совпадает ни с чем")
    func anEmptySelectionMatchesNothing() {
        #expect(!Fixtures.chrome.matches(sourceApplicationID: ""))
    }
}

// MARK: - Сведение буферов в моно

@Suite("Свод буферного списка в моно")
struct PCMMixdownTests {

    /// Строит `AudioBufferList` из отдельных буферов на канал — так его отдаёт
    /// и тап, и ScreenCaptureKit, вопреки собственному заявленному формату.
    private func withPlanarList(
        _ channels: [[Float]],
        _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        defer { free(list.unsafeMutablePointer) }

        var storage: [UnsafeMutablePointer<Float>] = []
        defer { for pointer in storage { pointer.deallocate() } }

        for (index, channel) in channels.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
            pointer.update(from: channel, count: channel.count)
            storage.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(channel.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer)
            )
        }
        body(UnsafePointer(list.unsafeMutablePointer))
    }

    /// The same samples in one buffer, channels alternating.
    private func withInterleavedList(
        _ channels: [[Float]],
        _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        let frames = channels[0].count
        var interleaved: [Float] = []
        for frame in 0..<frames {
            for channel in channels { interleaved.append(channel[frame]) }
        }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }

        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: interleaved.count)
        defer { pointer.deallocate() }
        pointer.update(from: interleaved, count: interleaved.count)

        list[0] = AudioBuffer(
            mNumberChannels: UInt32(channels.count),
            mDataByteSize: UInt32(interleaved.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(pointer)
        )
        body(UnsafePointer(list.unsafeMutablePointer))
    }

    @Test("Раздельные буферы каналов сводятся усреднением, а не отбрасыванием")
    func planarChannelsAreAveraged() {
        withPlanarList([[1, 0, -1], [0, 1, 1]]) { list in
            let mono = PCMMixdown.mono(from: list, sampleRate: 48_000)
            let buffer = try! #require(mono)
            #expect(buffer.frameLength == 3)
            let samples = buffer.floatChannelData![0]
            #expect(abs(samples[0] - 0.5) < 0.0001)
            #expect(abs(samples[1] - 0.5) < 0.0001)
            #expect(abs(samples[2] - 0.0) < 0.0001)
        }
    }

    @Test("Чередующиеся каналы сводятся к тем же значениям")
    func interleavedChannelsGiveTheSameResult() {
        withInterleavedList([[1, 0, -1], [0, 1, 1]]) { list in
            let mono = PCMMixdown.mono(from: list, sampleRate: 48_000)
            let buffer = try! #require(mono)
            #expect(buffer.frameLength == 3, "в одном буфере лежат три кадра по два канала")
            let samples = buffer.floatChannelData![0]
            #expect(abs(samples[0] - 0.5) < 0.0001)
            #expect(abs(samples[1] - 0.5) < 0.0001)
            #expect(abs(samples[2] - 0.0) < 0.0001)
        }
    }

    @Test("Пустой буфер не превращается в кадр")
    func anEmptyListYieldsNothing() {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        #expect(PCMMixdown.mono(from: UnsafePointer(list.unsafeMutablePointer), sampleRate: 48_000) == nil)
    }
}

// MARK: - Источник канала Them через ScreenCaptureKit

@Suite("Канал Them через ScreenCaptureKit")
struct SCKCaptureServiceTests {

    @Test("Источник объявляет себя каналом Them, а не You")
    func theServiceBelongsToTheThemChannel() {
        #expect(SCKCaptureService(stream: FakeThemStream()).channel == .them)
    }

    @Test("Без выбранного приложения запуск не падает, а честно говорит, что канал молчит")
    func startingWithoutASourceIsNotAFailure() async throws {
        let service = SCKCaptureService(stream: FakeThemStream())

        try service.start { _ in }
        await service.waitForAttach()

        #expect(service.isRunning, "микрофонный канал не должен страдать из-за незаполненного Them")
        #expect(service.status == .idle)
        service.stop()
        #expect(!service.isRunning)
    }

    @Test("Приложение-источник не показывается системе — захват ждёт его возвращения")
    func aMissingSourceApplicationIsReportedHonestly() async throws {
        let service = SCKCaptureService(
            sourceApplicationID: "com.google.Chrome",
            stream: FakeThemStream(applications: [Fixtures.canary])
        )

        try service.start { _ in }
        await service.waitForAttach()
        defer { service.stop() }

        #expect(service.status == .waitingForSource(application: "com.google.Chrome"))
    }

    @Test("Выбранный браузер захватывается вместе со всеми своими процессами")
    func everyProcessOfTheChosenApplicationIsCaptured() async throws {
        let stream = FakeThemStream(applications: [
            Fixtures.canary,
            Fixtures.chrome,
            Fixtures.chromeHelper,
        ])
        let service = SCKCaptureService(sourceApplicationID: "com.google.Chrome", stream: stream)

        try service.start { _ in }
        await service.waitForAttach()
        defer { service.stop() }

        #expect(service.status == .capturing(application: "Google Chrome"))
        #expect(
            stream.startedScope == .applications([14827, 14881]),
            "неизвестно, какой из процессов браузера зазвучит — захватывать надо все"
        )
    }

    @Test("Захваченный звук доходит до движка как кадры канала Them на 16 кГц")
    func capturedAudioBecomesThemFrames() async throws {
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let service = SCKCaptureService(sourceApplicationID: "com.google.Chrome", stream: stream)
        let sink = FrameSink()

        try service.start(onFrame: sink.handler)
        await service.waitForAttach()
        defer { service.stop() }

        stream.deliver(sineBuffer())

        let frame = try #require(sink.frames.first)
        #expect(frame.channel == .them, "канал определяется источником, а не содержанием")
        #expect(frame.sampleRate == 16_000, "распознавание должно видеть одну форму звука, а не две")
        #expect(frame.rms > 0.1, "звук обязан дойти не только по форме, но и по содержанию")
    }

    @Test("Смена приложения-источника на лету не требует перезапуска сессии")
    func changingTheSourceApplicationTakesEffectAtOnce() async throws {
        let stream = FakeThemStream(applications: [Fixtures.chrome, Fixtures.chromeHelper])
        let service = SCKCaptureService(stream: stream)

        try service.start { _ in }
        await service.waitForAttach()
        defer { service.stop() }
        #expect(service.status == .idle)

        service.sourceApplicationID = "com.google.Chrome"
        await service.waitForAttach()

        #expect(service.status == .capturing(application: "Google Chrome"))
    }

    @Test("Отказ ScreenCaptureKit виден как поломка, а не как тишина")
    func aRefusalIsReportedRatherThanSwallowed() async throws {
        struct Denied: LocalizedError {
            var errorDescription: String? { "Нет доступа к записи экрана" }
        }
        let service = SCKCaptureService(
            sourceApplicationID: "com.google.Chrome",
            stream: FakeThemStream(failure: Denied())
        )

        try service.start { _ in }
        await service.waitForAttach()
        defer { service.stop() }

        #expect(service.status == .failed(reason: "Нет доступа к записи экрана"))
    }

    @Test("Остановка возвращает источник в исходное состояние и гасит поток")
    func stoppingResetsTheStatus() async throws {
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let service = SCKCaptureService(sourceApplicationID: "com.google.Chrome", stream: stream)

        try service.start { _ in }
        await service.waitForAttach()
        service.stop()

        #expect(service.status == .idle)
        #expect(!service.isRunning)
        #expect(stream.stops > 0, "поток обязан быть остановлен, иначе SCStream переживёт сессию")
    }
}

// MARK: - Оборвавшийся поток

/// Обрыв «прерванного подключения», ровно как его сообщил `SCStream` вживую.
private struct StreamBroke: LocalizedError {
    var errorDescription: String? { "Произошел сбой трансляции из‑за прерванного подключения к приложению" }
}

/// Ждёт того, что вот-вот случится на другой задаче, не засыпая вслепую.
private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + TestWait.budget
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@Suite("Канал Them возвращается после обрыва")
struct ThemRecoveryTests {

    /// Сервис, у которого паузы между попытками не стоят времени.
    private func service(
        stream: FakeThemStream,
        attempts: Int = 3
    ) -> SCKCaptureService {
        SCKCaptureService(
            sourceApplicationID: "com.google.Chrome",
            stream: stream,
            retryDelays: Array(repeating: 0, count: attempts),
            pause: { _ in }
        )
    }

    @Test("Поток оборвался — канал поднимается заново и снова слушает")
    func abrokenStreamComesBack() async throws {
        // 15 августа 2026: поток прожил 1.1 секунды, Chrome остался жив, список
        // процессов не двинулся — и канал молчал 37 минут, пока голос
        // собеседника писался в You через динамики.
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let service = service(stream: stream)

        try service.start { _ in }
        await service.waitForAttach()
        #expect(service.status == .capturing(application: "Google Chrome"))

        stream.breaks(with: StreamBroke())
        await service.waitForRecovery()
        defer { service.stop() }

        #expect(
            service.status == .capturing(application: "Google Chrome"),
            "обрыв обязан поднимать канал, а не хоронить его до конца звонка"
        )
    }

    @Test("Обрыв не сдаётся с первой попытки")
    func recoveryRetriesRatherThanGivingUpAtOnce() async throws {
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let service = service(stream: stream)

        try service.start { _ in }
        await service.waitForAttach()
        let attachesBefore = stream.starts

        // Первая попытка попадает в ту же секунду, в которую поток умер, — ради
        // этого случая задержки и заведены. Отказывает ровно одна попытка,
        // вторая обязана состояться.
        stream.refuseNextAttempts(1)
        stream.breaks(with: StreamBroke())
        await service.waitForRecovery()
        defer { service.stop() }

        #expect(service.status == .capturing(application: "Google Chrome"))
        #expect(
            stream.starts - attachesBefore == 2,
            "первая попытка отказала — вторая обязана быть, иначе канал хоронится с одного отказа"
        )
    }

    @Test("Источник закрыт в момент обрыва — канал ждёт его, а не объявляет поломку")
    func aClosedSourceIsWaitedForRatherThanDeclaredBroken() async throws {
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let service = service(stream: stream)

        try service.start { _ in }
        await service.waitForAttach()

        // Браузер закрылся вместе с потоком: дальше канал поднимет наблюдатель
        // списка процессов, и попытки на этом прекращаются.
        stream.applications = []
        stream.breaks(with: StreamBroke())
        await service.waitForRecovery()
        defer { service.stop() }

        #expect(service.status == .waitingForSource(application: "Google Chrome"))
    }

    @Test("Попытки исчерпаны — сказано, что случилось и что нажать")
    func anExhaustedRecoverySaysWhatIsWrong() async throws {
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let service = service(stream: stream)

        try service.start { _ in }
        await service.waitForAttach()
        let attachesBefore = stream.starts

        // Отказывают все три попытки, которые есть у этого стенда.
        stream.refuseNextAttempts(3)
        stream.breaks(with: StreamBroke())
        await service.waitForRecovery()
        defer { service.stop() }

        #expect(stream.starts - attachesBefore == 3, "бюджет попыток израсходован целиком")
        #expect(service.status == .failed(reason: SCKCaptureService.lostMessage))
        #expect(service.status.isFailure)
        #expect(
            SCKCaptureService.lostMessage.contains("«Слушать»"),
            "сказано, что нажать; следствие добавляет окно — см. «Молчащий Them назван следствием»"
        )
    }

    @Test("Остановка посреди восстановления не оставляет канал воскресать в одиночестве")
    func stoppingCancelsRecovery() async throws {
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let service = service(stream: stream)

        try service.start { _ in }
        await service.waitForAttach()

        stream.refuseNextAttempts(3)
        stream.breaks(with: StreamBroke())
        service.stop()
        await service.waitForRecovery()

        #expect(service.status == .idle, "пользователь ушёл со звонка — канал не поднимается сам")
        #expect(!service.isRunning)
    }

    @Test("Два обрыва подряд — одно восстановление, а не гонка двух")
    func aBurstOfFailuresStartsOneRecovery() async throws {
        // Ворота держат восстановление на паузе, пока второй обрыв не приехал:
        // без них два `breaks` подряд могли бы разойтись во времени и тест
        // проверял бы удачу, а не правило.
        let stream = FakeThemStream(applications: [Fixtures.chrome])
        let gate = Gate()
        let service = SCKCaptureService(
            sourceApplicationID: "com.google.Chrome",
            stream: stream,
            retryDelays: [0, 0, 0],
            pause: { _ in await gate.wait() }
        )

        try service.start { _ in }
        await service.waitForAttach()
        let attachesBefore = stream.starts

        stream.breaks(with: StreamBroke())
        #expect(
            await eventually { service.status == .restarting(attempt: 1) },
            "восстановление обязано начаться и ждать своей паузы"
        )
        stream.breaks(with: StreamBroke())

        await gate.open()
        await service.waitForRecovery()
        defer { service.stop() }

        #expect(service.status == .capturing(application: "Google Chrome"))
        #expect(
            stream.starts - attachesBefore == 1,
            "две ошибки об одном сломанном потоке — это один сломанный поток"
        )
    }

    @Test("Восстановление — это ожидание, а не отказ: пользователя никуда не зовут")
    func recoveryReadsAsWaiting() {
        let restarting = ThemCaptureStatus.restarting(attempt: 2)

        #expect(!restarting.isFailure)
        #expect(restarting.message.contains("2"), "видно, которая это попытка")
        #expect(ThemCaptureStatus.failed(reason: "…").isFailure)
    }
}

// MARK: - Как о мёртвом канале сказано в окне

@Suite("Молчащий Them назван следствием, а не кодом ошибки")
struct DeafThemNoticeTests {

    private func indicators(isListening: Bool, them: ThemCaptureStatus) -> SessionIndicators {
        SessionIndicators.make(
            isListening: isListening,
            failure: nil,
            recognition: .ready,
            themStatus: them,
            isGenerating: false,
            suggestionFailure: nil
        )
    }

    @Test("Во время звонка сказано, что чужая речь пишется как ваша")
    func aDeadChannelDuringACallNamesWhatItCosts() {
        // Системная формулировка в тот вечер на экране была — и была прочитана
        // мимо: из «сбоя трансляции» не следует, что транскрипт врёт.
        let them = indicators(
            isListening: true,
            them: .failed(reason: "Произошел сбой трансляции из‑за прерванного подключения к приложению")
        ).them

        #expect(them.state == .failed)
        #expect(them.detail.hasPrefix(SessionIndicators.deafConsequence), "следствие идёт первым")
        #expect(them.detail.contains("сбой трансляции"), "причина остаётся — по ней разбираются потом")
    }

    @Test("До звонка следствия нет: писать в транскрипт ещё нечего")
    func beforeTheCallOnlyTheReasonIsShown() {
        let them = indicators(
            isListening: false,
            them: .failed(reason: ThemCaptureBackend.screenRecordingHelp)
        ).them

        #expect(them.detail == ThemCaptureBackend.screenRecordingHelp)
        #expect(!them.detail.contains(SessionIndicators.deafConsequence))
    }

    @Test("Канал восстанавливается — это объясняют, но не пугают отказом")
    func aRecoveringChannelIsExplainedWithoutAlarm() {
        let them = indicators(isListening: true, them: .restarting(attempt: 1)).them

        #expect(them.state == .waiting, "канал поднимает себя сам — звать пользователя не за чем")
        #expect(them.state.deservesAnExplanation, "но молчание объяснено")
        #expect(!them.detail.contains(SessionIndicators.deafConsequence))
    }

    @Test("Канал вернулся — от предупреждения не остаётся следа")
    func arecoveredChannelLeavesNoWarningBehind() {
        let them = indicators(isListening: true, them: .capturing(application: "Google Chrome")).them

        #expect(them.state == .listening)
        #expect(!them.state.deservesAnExplanation)
        #expect(!them.detail.contains(SessionIndicators.deafConsequence))
    }
}

// MARK: - Выбор бэкенда

@MainActor
@Suite("Бэкенд канала Them в настройках")
struct ThemCaptureBackendSettingsTests {

    private func withTemporaryDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "GhostMeetSCKTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        return try body(defaults)
    }

    @Test("По умолчанию канал Them берётся ScreenCaptureKit — он даёт сигнал громче")
    func screenCaptureKitIsTheDefault() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            // На одной и той же записи SCK громче тапа в 1.5–2.5 раза
            // (пик_rms 0.095–0.127 против 0.051–0.081): эхоподавление микрофона
            // пригибает громкость системы, и по тапу это бьёт сильнее. Громкость
            // — главное ограничение качества распознавания, поэтому дефолт тут.
            #expect(store.themCaptureBackend == .screenCaptureKit)
            #expect(ThemCaptureBackend.default == .screenCaptureKit)
        }
    }

    @Test("Выбранный бэкенд переживает перезапуск приложения")
    func theChosenBackendSurvivesRestart() {
        withTemporaryDefaults { defaults in
            let first = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            // Тап — не дефолт, поэтому только он и доказывает, что выбор
            // действительно сохранён, а не совпал со значением по умолчанию.
            first.themCaptureBackend = .processTap

            let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(second.themCaptureBackend == .processTap)
        }
    }

    @Test("Незнакомое значение в настройках не оставляет канал без бэкенда")
    func anUnknownStoredBackendFallsBackToTheDefault() {
        withTemporaryDefaults { defaults in
            defaults.set("quantumTelepathy", forKey: "settings.themCaptureBackend")
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(store.themCaptureBackend == .screenCaptureKit)
        }
    }

    @Test("У каждого варианта на экране есть честное описание отличий")
    func everyBackendExplainsItself() {
        // Экран настроек показывает эти строки дословно. Пустое описание
        // означало бы выбор вслепую: бэкенды ломаются на разных машинах,
        // и пользователь — единственный, кто знает, что на этой доступно.
        for backend in ThemCaptureBackend.allCases {
            #expect(!backend.summary.isEmpty, "\(backend.displayName) без описания")
            #expect(!backend.displayName.isEmpty)
        }
        #expect(ThemCaptureBackend.screenCaptureKit.requiresScreenRecording)
        #expect(!ThemCaptureBackend.processTap.requiresScreenRecording)
        #expect(ThemCaptureBackend.screenRecordingHelp.contains("Запись экрана"))
        #expect(
            ThemCaptureBackend.screenRecordingHelp.contains("Core Audio Process Tap"),
            "у пользователя два выхода из ситуации, и второй нельзя умолчать"
        )
    }

    // Тест «эхоподавление не выключается ни под одним бэкендом» жил здесь и
    // удалён вместе со свойством, которое он сторожил: с ADR-0009 системное
    // эхоподавление не включается вообще, ни под каким бэкендом. Сторожит это
    // теперь `VoiceProcessingOffTests`.
}
