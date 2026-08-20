//
//  ThemBackendSelectionTests.swift
//  GhostMeetTests
//

import CoreAudio
import Foundation
import Testing
@testable import GhostMeet

// MARK: - Дублёры

/// Бэкенд канала `Them`, который ничего не захватывает и всё про себя помнит.
private final class FakeThemBackend: ThemAudioSource, @unchecked Sendable {
    let channel: Channel = .them
    let backend: ThemCaptureBackend

    var onStatusChange: (@Sendable (ThemCaptureStatus) -> Void)?

    private let lock = NSLock()
    private var _isRunning = false
    private var _status: ThemCaptureStatus = .idle
    private var _sourceApplicationID: String?
    private var _starts = 0
    private var _stops = 0
    private var _failure: Error?

    init(backend: ThemCaptureBackend, failure: Error? = nil) {
        self.backend = backend
        self._failure = failure
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var status: ThemCaptureStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    var sourceApplicationID: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _sourceApplicationID
        }
        set {
            lock.lock()
            _sourceApplicationID = newValue
            lock.unlock()
        }
    }

    var starts: Int {
        lock.lock(); defer { lock.unlock() }
        return _starts
    }

    var stops: Int {
        lock.lock(); defer { lock.unlock() }
        return _stops
    }

    func start(onFrame: @escaping AudioFrameHandler) throws {
        lock.lock()
        let failure = _failure
        if failure == nil {
            _isRunning = true
            _starts += 1
        }
        lock.unlock()
        if let failure { throw failure }
        publish(.capturing(application: "Google Chrome"))
    }

    func stop() {
        lock.lock()
        _isRunning = false
        _stops += 1
        lock.unlock()
        publish(.idle)
    }

    /// Позволяет тесту сыграть смену состояния захвата.
    func publish(_ status: ThemCaptureStatus) {
        lock.lock()
        _status = status
        let handler = onStatusChange
        lock.unlock()
        handler?(status)
    }
}

/// Собирает всё, что построил `SwitchableThemSource`, чтобы тест мог заглянуть
/// внутрь подмены.
private final class BackendFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _built: [FakeThemBackend] = []
    private let failing: Set<ThemCaptureBackend>

    init(failing: Set<ThemCaptureBackend> = []) {
        self.failing = failing
    }

    var make: @Sendable (ThemCaptureBackend) -> any ThemAudioSource {
        { [self] backend in
            let source = FakeThemBackend(
                backend: backend,
                failure: failing.contains(backend) ? CaptureRefusal() : nil
            )
            lock.lock()
            _built.append(source)
            lock.unlock()
            return source
        }
    }

    var built: [FakeThemBackend] {
        lock.lock(); defer { lock.unlock() }
        return _built
    }

    func first(of backend: ThemCaptureBackend) -> FakeThemBackend? {
        built.first { $0.backend == backend }
    }
}

private struct CaptureRefusal: LocalizedError {
    var errorDescription: String? { "Бэкенд отказался стартовать" }
}

/// Список ScreenCaptureKit, каким его задал тест — включая отказ по разрешению.
private final class FakeShareableLister: ShareableApplicationLister, @unchecked Sendable {
    private let lock = NSLock()
    private var _applications: [ShareableApplication]
    private var _failure: Error?

    init(applications: [ShareableApplication] = [], failure: Error? = nil) {
        _applications = applications
        _failure = failure
    }

    func shareableApplications() async throws -> [ShareableApplication] {
        lock.lock(); defer { lock.unlock() }
        if let _failure { throw _failure }
        return _applications
    }
}

/// Стенд-ин для `coreaudiod` и оконного сервера.
private final class StubProcessLister: AudioProcessLister, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [AudioProcess]
    private var _applications: [RunningApplication]

    init(processes: [AudioProcess] = [], applications: [RunningApplication] = []) {
        _processes = processes
        _applications = applications
    }

    func audioProcesses() -> [AudioProcess] {
        lock.lock(); defer { lock.unlock() }
        return _processes
    }

    func runningApplications() -> [RunningApplication] {
        lock.lock(); defer { lock.unlock() }
        return _applications
    }
}

private struct ScreenRecordingDenied: LocalizedError {
    var errorDescription: String? { ThemCaptureBackend.screenRecordingHelp }
}

// MARK: - Фикстуры

private enum Browser {
    static let bundleID = "com.google.Chrome"
    static let bundleURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    static let executable = URL(
        fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    )
    static let helperExecutable = URL(
        fileURLWithPath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/150/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    )

    static func application(pid: pid_t = 14827) -> RunningApplication {
        RunningApplication(
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            bundleURL: bundleURL,
            localizedName: "Google Chrome",
            isUserFacing: true
        )
    }

    static func shareable(pid: pid_t = 14827) -> ShareableApplication {
        ShareableApplication(
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            name: "Google Chrome",
            executableURL: executable
        )
    }

    static func shareableHelper(pid: pid_t = 14881) -> ShareableApplication {
        ShareableApplication(
            processIdentifier: pid,
            bundleIdentifier: "com.google.Chrome.helper",
            name: "Google Chrome Helper (Renderer)",
            executableURL: helperExecutable
        )
    }

    /// Звук звонка отдаёт помощник, а не главный процесс, — так это и выглядит
    /// в системе.
    static func audibleHelper(objectID: AudioObjectID = 152, pid: pid_t = 14881) -> AudioProcess {
        AudioProcess(
            objectID: objectID,
            processIdentifier: pid,
            bundleIdentifier: "com.google.Chrome.helper",
            executableURL: helperExecutable,
            isPlayingAudio: true
        )
    }
}

/// Плеер из терминала: звук есть, окна нет. Core Audio его видит, а
/// ScreenCaptureKit — никогда.
private func afplayProcess(objectID: AudioObjectID = 165, pid: pid_t = 85885) -> AudioProcess {
    AudioProcess(
        objectID: objectID,
        processIdentifier: pid,
        bundleIdentifier: "",
        executableURL: URL(fileURLWithPath: "/usr/bin/afplay"),
        isPlayingAudio: true
    )
}

// MARK: - Вспомогательное

@MainActor
private func withScratchSettings<T>(_ body: (SettingsStore) throws -> T) rethrows -> T {
    let name = "GhostMeetBackendSelectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()))
}

/// Ждёт того, что случится на следующем витке главного актора: подписка
/// перечитывает хранилище из `Task`, поэтому изменение видно на хоп позже.
@MainActor
private func eventually(_ condition: () -> Bool, attempts: Int = 200) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

// MARK: - Подмена бэкенда на лету

@MainActor
@Suite("Смена бэкенда канала Them без перезапуска")
struct SwitchableThemSourceTests {

    @Test("Источник берёт бэкенд из настроек при подписке")
    func theBackendIsTakenOnSubscription() {
        withScratchSettings { settings in
            settings.themCaptureBackend = .processTap
            let factory = BackendFactory()
            let source = SwitchableThemSource(backend: .screenCaptureKit, make: factory.make)

            source.followCaptureBackend(of: settings)

            #expect(source.backend == .processTap)
        }
    }

    @Test("Пользователь переключил бэкенд во время звонка — источник это увидел сразу")
    func aBackendChangedMidCallReachesTheSource() async {
        let settings = withScratchSettings { $0 }
        let factory = BackendFactory()
        let source = SwitchableThemSource(backend: settings.themCaptureBackend, make: factory.make)
        source.followCaptureBackend(of: settings)
        #expect(source.backend == .screenCaptureKit)

        settings.themCaptureBackend = .processTap

        let arrived = await eventually { source.backend == .processTap }
        #expect(arrived, "смена бэкенда не доехала до источника — подписка развалилась")
    }

    @Test("Бэкенд переключали несколько раз подряд — источник следует за каждым разом")
    func theSourceKeepsFollowingAfterTheFirstChange() async {
        let settings = withScratchSettings { $0 }
        let factory = BackendFactory()
        let source = SwitchableThemSource(backend: settings.themCaptureBackend, make: factory.make)
        source.followCaptureBackend(of: settings)

        // Подписка пересоздаётся на каждом изменении, поэтому регрессия здесь
        // выглядит так: первое переключение проходит, второе молча теряется.
        for backend in [ThemCaptureBackend.processTap, .screenCaptureKit, .processTap] {
            settings.themCaptureBackend = backend
            let arrived = await eventually { source.backend == backend }
            #expect(arrived, "источник перестал следовать за настройками на \(backend.displayName)")
        }
    }

    @Test("Захват переезжает на новый бэкенд: старый остановлен, новый запущен")
    func captureMovesToTheNewBackend() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(backend: .screenCaptureKit, make: factory.make)
        try source.start { _ in }

        let first = try #require(factory.first(of: .screenCaptureKit))
        #expect(first.isRunning)

        source.backend = .processTap

        let second = try #require(factory.first(of: .processTap))
        #expect(!first.isRunning, "старый бэкенд обязан отпустить устройство")
        #expect(first.stops > 0)
        #expect(second.starts == 1, "новый бэкенд обязан подхватить тот же сеанс")
        #expect(source.isRunning, "для движка сессия не прерывалась")

        source.stop()
    }

    @Test("Новый бэкенд получает уже выбранное приложение-источник")
    func theChosenApplicationSurvivesTheSwap() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(
            backend: .screenCaptureKit,
            sourceApplicationID: Browser.bundleID,
            make: factory.make
        )
        try source.start { _ in }
        source.backend = .processTap

        let second = try #require(factory.first(of: .processTap))
        #expect(second.sourceApplicationID == Browser.bundleID)
        #expect(source.sourceApplicationID == Browser.bundleID)

        source.stop()
    }

    @Test("Пока сессия не запущена, подмена ничего не запускает")
    func swappingWhileStoppedStartsNothing() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(backend: .screenCaptureKit, make: factory.make)

        source.backend = .processTap

        let second = try #require(factory.first(of: .processTap))
        #expect(second.starts == 0)
        #expect(!source.isRunning)
    }

    @Test("Новый бэкенд не смог стартовать — причина ушла в статус, а не в исключение")
    func aFailingNewBackendSurfacesAsStatus() throws {
        let factory = BackendFactory(failing: [.processTap])
        let source = SwitchableThemSource(backend: .screenCaptureKit, make: factory.make)

        let statuses = StatusSink()
        source.onStatusChange = statuses.handler
        try source.start { _ in }

        // Канал Them не имеет права уронить сессию: микрофон работает, а
        // причина обязана дойти до окна (ADR-0004 — только не баннером).
        source.backend = .processTap

        #expect(statuses.last == .failed(reason: "Бэкенд отказался стартовать"))

        source.stop()
    }

    @Test("Статусы нового бэкенда доходят наверх, старого — уже нет")
    func onlyTheCurrentBackendIsHeard() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(backend: .screenCaptureKit, make: factory.make)
        try source.start { _ in }

        let statuses = StatusSink()
        source.onStatusChange = statuses.handler
        source.backend = .processTap

        let old = try #require(factory.first(of: .screenCaptureKit))
        old.publish(.failed(reason: "привет из прошлого"))
        #expect(statuses.last != .failed(reason: "привет из прошлого"))

        let new = try #require(factory.first(of: .processTap))
        new.publish(.waitingForSource(application: "Google Chrome"))
        #expect(statuses.last == .waitingForSource(application: "Google Chrome"))

        source.stop()
    }
}

/// Копит статусы, которые источник отдал наверх.
private final class StatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [ThemCaptureStatus] = []

    var handler: @Sendable (ThemCaptureStatus) -> Void {
        { [self] status in
            lock.lock()
            _statuses.append(status)
            lock.unlock()
        }
    }

    var last: ThemCaptureStatus? {
        lock.lock(); defer { lock.unlock() }
        return _statuses.last
    }

    /// Всё, что было опубликовано: переход на второй бэкенд — событие в
    /// середине потока, и по последнему статусу его не увидеть.
    var all: [ThemCaptureStatus] {
        lock.lock(); defer { lock.unlock() }
        return _statuses
    }
}

// MARK: - Список приложений под выбранный бэкенд

@Suite("Список приложений строится по перечню ScreenCaptureKit")
struct ShareableSourceListingTests {

    @Test("Помощники браузера сворачиваются в один браузер")
    func helpersFoldIntoTheBrowser() throws {
        let offered = SourceApplication.offered(
            shareable: [Browser.shareable(), Browser.shareableHelper()],
            applications: [Browser.application()],
            excluding: -1
        )

        #expect(offered.count == 1, "два окна браузера — одна строка в списке")
        let chrome = try #require(offered.first)
        #expect(chrome.name == "Google Chrome")
        #expect(chrome.id == Browser.bundleID)
    }

    @Test("Идентификатор один и тот же под обоими бэкендами — выбор переживает переключение")
    func theIdentityIsTheSameUnderBothBackends() throws {
        let applications = [Browser.application()]
        let fromTap = SourceApplication.offered(
            processes: [Browser.audibleHelper()],
            applications: applications
        )
        let fromSCK = SourceApplication.offered(
            shareable: [Browser.shareable(), Browser.shareableHelper()],
            applications: applications,
            excluding: -1
        )

        // Иначе переключение бэкенда молча сбрасывало бы выбранный браузер.
        #expect(try #require(fromTap.first).id == #require(fromSCK.first).id)
    }

    @Test("«Звучит» берётся из Core Audio — это факт о машине, а не о бэкенде")
    func theAudibleMarkerComesFromCoreAudio() throws {
        let offered = SourceApplication.offered(
            shareable: [Browser.shareable()],
            applications: [Browser.application()],
            audioProcesses: [Browser.audibleHelper()],
            excluding: -1
        )

        let chrome = try #require(offered.first)
        #expect(chrome.isPlayingAudio, "звучит помощник — значит, звучит браузер")
    }

    @Test("Своё же приложение в списке не предлагается")
    func ourOwnProcessIsNeverOffered() {
        let offered = SourceApplication.offered(
            shareable: [Browser.shareable(pid: 4242)],
            applications: [Browser.application(pid: 4242)],
            excluding: 4242
        )
        // Захват через SCK исключает звук собственного процесса, так что выбор
        // GhostMeet означал бы гарантированную тишину.
        #expect(offered.isEmpty)
    }
}

@MainActor
@Suite("Каталог приложений следует за бэкендом")
struct BackendAwareCatalogTests {

    @Test("Под тапом каталог показывает перечень Core Audio")
    func theTapCatalogShowsCoreAudio() {
        let catalog = SourceApplicationCatalog(
            backend: .processTap,
            lister: StubProcessLister(
                processes: [afplayProcess()],
                applications: []
            ),
            shareable: FakeShareableLister(applications: [Browser.shareable()])
        )

        catalog.refresh()

        // Плеер без окна — ровно то, ради чего тап и остаётся в продукте.
        #expect(catalog.applications.map(\.name) == ["afplay"])
        #expect(catalog.unavailableReason == nil)
    }

    @Test("Под ScreenCaptureKit каталог показывает его собственный перечень")
    func theSCKCatalogShowsShareableApplications() async {
        let catalog = SourceApplicationCatalog(
            backend: .screenCaptureKit,
            lister: StubProcessLister(
                processes: [afplayProcess()],
                applications: [Browser.application()]
            ),
            shareable: FakeShareableLister(applications: [Browser.shareable()])
        )

        catalog.refresh()
        await catalog.refreshCompleted()

        // Главное в этом тесте — чего в списке НЕТ: afplay звучит прямо сейчас,
        // но окна у него нет, и SCK его не захватит. Оставить его в списке —
        // значит дать выбрать источник, который гарантированно промолчит.
        #expect(catalog.applications.map(\.name) == ["Google Chrome"])
        #expect(catalog.application(withID: Browser.bundleID) != nil)
    }

    @Test("Переключение бэкенда перестраивает список")
    func changingTheBackendRebuildsTheList() async {
        let catalog = SourceApplicationCatalog(
            backend: .processTap,
            lister: StubProcessLister(
                processes: [afplayProcess()],
                applications: [Browser.application()]
            ),
            shareable: FakeShareableLister(applications: [Browser.shareable()])
        )
        catalog.refresh()
        #expect(catalog.applications.map(\.name) == ["afplay"])

        catalog.backend = .screenCaptureKit
        await catalog.refreshCompleted()

        #expect(catalog.applications.map(\.name) == ["Google Chrome"])
    }

    @Test("Без разрешения на запись экрана каталог объясняет, что делать")
    func aMissingScreenRecordingGrantIsExplained() async {
        let catalog = SourceApplicationCatalog(
            backend: .screenCaptureKit,
            lister: StubProcessLister(applications: [Browser.application()]),
            shareable: FakeShareableLister(failure: ScreenRecordingDenied())
        )

        catalog.refresh()
        await catalog.refreshCompleted()

        #expect(catalog.applications.isEmpty)
        let reason = catalog.unavailableReason
        #expect(reason != nil, "пустой список без объяснения — тупик для пользователя")
        #expect(reason?.contains("Запись экрана") == true)
        #expect(
            reason?.contains("Core Audio Process Tap") == true,
            "второй выход — переключить бэкенд — нельзя умалчивать"
        )
    }

    @Test("Разрешение выдали — предупреждение уходит с экрана")
    func theWarningClearsOnceTheListIsBack() async {
        let denied = SourceApplicationCatalog(
            backend: .screenCaptureKit,
            lister: StubProcessLister(applications: [Browser.application()]),
            shareable: FakeShareableLister(failure: ScreenRecordingDenied())
        )
        denied.refresh()
        await denied.refreshCompleted()
        #expect(denied.unavailableReason != nil)

        // Тап разрешения не требует, поэтому переключение — это и есть выход,
        // который предлагает само предупреждение.
        denied.backend = .processTap
        await denied.refreshCompleted()

        #expect(denied.unavailableReason == nil)
    }
}

// MARK: - Откат на второй бэкенд

@Suite("Мёртвый бэкенд уступает место второму")
struct ThemBackendFallbackTests {

    /// Мёртвый `Them` — единственный отказ, который не отменяет подсказку, а
    /// тихо портит транскрипт: голос собеседника продолжает приходить в
    /// микрофон через динамики и пишется как речь пользователя. Обе защиты от
    /// протечки в этом состоянии бесполезны по устройству.
    @Test("Отказ во время захвата переводит канал на второй бэкенд")
    func failureSwitchesToTheOtherBackend() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(
            backend: .screenCaptureKit,
            sourceApplicationID: "com.google.Chrome",
            make: factory.make
        )
        let statuses = StatusSink()
        source.onStatusChange = statuses.handler
        try source.start(onFrame: { _ in })

        let first = try #require(factory.built.first)
        first.publish(.failed(reason: "ScreenCaptureKit не видит ни одного приложения"))

        #expect(source.backend == .processTap)
        #expect(factory.built.count == 2)
        // Сеанс переезжает целиком: то же приложение-источник и работающий захват.
        let second = try #require(factory.built.last)
        #expect(second.sourceApplicationID == "com.google.Chrome")
        #expect(second.starts == 1)
    }

    /// Молчаливый откат хуже отказа: у бэкендов разные слепые зоны — SCK видит
    /// только приложения с окнами, тап видит любой процесс, но звучит тише, —
    /// и пользователь, которого переключили молча, будет искать причину не там.
    @Test("Переход назван словами, вместе с причиной")
    func theSwitchIsSaidOutLoud() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(
            backend: .screenCaptureKit,
            sourceApplicationID: "com.google.Chrome",
            make: factory.make
        )
        let statuses = StatusSink()
        source.onStatusChange = statuses.handler
        try source.start(onFrame: { _ in })

        try #require(factory.built.first).publish(.failed(reason: "нет разрешения на запись экрана"))

        let announced = statuses.all.compactMap { status -> String? in
            if case .switchingBackend(_, let next, let reason) = status {
                return "\(reason) → \(next.displayName)"
            }
            return nil
        }
        let line = try #require(announced.first)
        #expect(line.contains("нет разрешения на запись экрана"))
        #expect(line.contains("Core Audio Process Tap"))
    }

    /// Второй `failed` подряд означает, что дело не в бэкенде: занят микрофон,
    /// не то приложение, разрешения нет нигде. Мигание между двумя мёртвыми
    /// захватами — шум вместо диагноза.
    @Test("Откат делается один раз, а не по кругу")
    func fallsBackOnlyOnce() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(
            backend: .screenCaptureKit,
            sourceApplicationID: "com.google.Chrome",
            make: factory.make
        )
        source.onStatusChange = StatusSink().handler
        try source.start(onFrame: { _ in })

        try #require(factory.built.first).publish(.failed(reason: "первый отказ"))
        #expect(source.backend == .processTap)

        try #require(factory.built.last).publish(.failed(reason: "второй отказ"))
        #expect(source.backend == .processTap, "второй отказ не должен возвращать канал обратно")
        #expect(factory.built.count == 2)
    }

    /// Выбор пользователя главнее аварийной меры: он только что нажал, и отказ
    /// по его выбору обязан быть виден. Молча вернуть прежний бэкенд — значит
    /// поспорить и не сказать об этом; человек решит, что переключатель сломан.
    ///
    /// Речь именно о бэкенде, который **не заработал ни разу**. Тот, что
    /// поработал и сломался, — уже поломка, а не спор с выбором, и его откат
    /// чинит.
    @Test("Выбранный руками бэкенд, не сумевший стартовать, не подменяется")
    func aManualChoiceIsNotUndone() throws {
        let factory = BackendFactory(failing: [.processTap])
        let source = SwitchableThemSource(
            backend: .screenCaptureKit,
            sourceApplicationID: "com.google.Chrome",
            make: factory.make
        )
        let statuses = StatusSink()
        source.onStatusChange = statuses.handler
        try source.start(onFrame: { _ in })

        source.backend = .processTap

        #expect(source.backend == .processTap, "выбор пользователя остаётся в силе")
        #expect(statuses.last?.isFailure == true, "отказ по его выбору обязан быть виден")
        #expect(factory.built.count == 2, "обратно на прежний бэкенд никто не возвращался")
    }

    /// А вот бэкенд, который поработал и сломался, откат чинит — даже если его
    /// выбрали руками: выбор состоялся, и дальше речь о поломке.
    @Test("Заработавший и сломавшийся бэкенд откатывается, даже выбранный руками")
    func aWorkingChoiceStillFallsBack() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(
            backend: .screenCaptureKit,
            sourceApplicationID: "com.google.Chrome",
            make: factory.make
        )
        source.onStatusChange = StatusSink().handler
        try source.start(onFrame: { _ in })

        source.backend = .processTap
        try #require(factory.built.last).publish(.failed(reason: "тап умер посреди звонка"))

        #expect(source.backend == .screenCaptureKit)
        #expect(factory.built.count == 3)
    }

    /// Пока прослушивание выключено, откатывать нечего: канал не работает, и
    /// смена бэкенда под ним ничего не чинит.
    @Test("Без прослушивания откат не срабатывает")
    func doesNotFallBackWhileIdle() throws {
        let factory = BackendFactory()
        let source = SwitchableThemSource(
            backend: .screenCaptureKit,
            sourceApplicationID: "com.google.Chrome",
            make: factory.make
        )
        source.onStatusChange = StatusSink().handler

        try #require(factory.built.first).publish(.failed(reason: "отказ до старта"))

        #expect(source.backend == .screenCaptureKit)
        #expect(factory.built.count == 1)
    }
}
