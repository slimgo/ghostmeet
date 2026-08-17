//
//  SelfUpdateTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

// MARK: - Стенд

/// An updater that reaches nothing, so that the rules around reaching can be
/// exercised: off means no request, tests mean no request, and the profile is
/// never sent.
@MainActor
private final class FakeUpdateInstaller: UpdateInstaller {
    var sendsSystemProfile = true
    private(set) var startCount = 0
    private(set) var checkCount = 0

    func start() { startCount += 1 }
    func check() { checkCount += 1 }
}

/// Counts how many installers were ever built. The distinction matters: an
/// updater that was constructed and told not to ask is a different thing from
/// one that never existed, and the switch promises the second.
@MainActor
private final class InstallerFactory {
    private(set) var built: [FakeUpdateInstaller] = []

    func make(_ status: UpdateStatus) -> any UpdateInstaller {
        let installer = FakeUpdateInstaller()
        built.append(installer)
        return installer
    }

    var last: FakeUpdateInstaller? { built.last }
}

private let anUpdate = OfferedUpdate(version: "0.4.0", notes: "### Fixed\n- всё")

// MARK: - Выключенный переключатель означает «запроса нет вовсе»

@MainActor
@Suite("Переключатель — это вся мера согласия")
struct UpdaterConsentTests {

    @Test("Выключенный переключатель не строит механизм и не делает запроса")
    func offMeansNoMechanismAtAll() {
        let factory = InstallerFactory()
        let updater = AppUpdater(
            isRunningTests: false,
            makeInstaller: factory.make,
            isEnabled: { false }
        )

        updater.startAtLaunch()

        #expect(factory.built.isEmpty, "выключенный — значит updater не должен появиться вовсе")
        #expect(updater.status.phase == .idle)
    }

    @Test("Включённый — один механизм и ровно один запрос при старте")
    func onAsksExactlyOnce() {
        let factory = InstallerFactory()
        let updater = AppUpdater(
            isRunningTests: false,
            makeInstaller: factory.make,
            isEnabled: { true }
        )

        updater.startAtLaunch()

        #expect(factory.built.count == 1)
        #expect(factory.last?.startCount == 1)
        #expect(factory.last?.checkCount == 1)
    }

    @Test("Повторные обращения не заводят второй механизм")
    func buildsTheMechanismOnce() {
        let factory = InstallerFactory()
        let updater = AppUpdater(
            isRunningTests: false,
            makeInstaller: factory.make,
            isEnabled: { true }
        )

        updater.startAtLaunch()
        updater.checkNow()
        updater.checkNow()

        #expect(factory.built.count == 1, "механизм остаётся один")
        #expect(factory.last?.startCount == 1)
        #expect(factory.last?.checkCount == 3)
    }

    @Test("Переключатель читается в момент обращения, а не при сборке")
    func readsTheSwitchWhenAsked() {
        let factory = InstallerFactory()
        var enabled = false
        let updater = AppUpdater(
            isRunningTests: false,
            makeInstaller: factory.make,
            isEnabled: { enabled }
        )

        updater.startAtLaunch()
        #expect(factory.built.isEmpty)

        enabled = true
        updater.checkNow()
        #expect(factory.built.count == 1)
    }

    /// Стоило проекту двух вечеров в другом месте: набор хостится внутри
    /// приложения, поэтому всё тяжёлое и всё сетевое в пути запуска обязано
    /// пропускаться под тестами. Здесь цена выше, чем у загрузки модели: этот
    /// механизм умеет заменить приложение, внутри которого идёт прогон.
    @Test("Под тестами не строится и не спрашивает вообще ничего")
    func doesNothingUnderTests() {
        let factory = InstallerFactory()
        let updater = AppUpdater(
            isRunningTests: true,
            makeInstaller: factory.make,
            isEnabled: { true }
        )

        updater.startAtLaunch()
        updater.checkNow()

        #expect(factory.built.isEmpty)
    }

    @Test("Профиль системы выключается до первого запроса")
    func turnsTheSystemProfileOffBeforeAsking() {
        let factory = InstallerFactory()
        let updater = AppUpdater(
            isRunningTests: false,
            makeInstaller: factory.make,
            isEnabled: { true }
        )

        updater.startAtLaunch()

        #expect(factory.last?.sendsSystemProfile == false)
    }
}

// MARK: - Обещание, проверенное по собранному бандлу

@MainActor
@Suite("Ключи Sparkle читаются из бандла, а не из нашей же константы")
struct UpdateBundleKeysTests {

    /// `INFOPLIST_KEY_*` для незнакомых Xcode ключей молча выбрасывается —
    /// записанная грабля проекта. Сверять здесь свою же константу значило бы
    /// проверять, что мы не опечатались, тогда как вопрос в другом: доехал ли
    /// ключ до бандла. Поэтому читается `Bundle.main`.
    private func bundleValue(_ key: String) -> Any? {
        Bundle.main.object(forInfoDictionaryKey: key)
    }

    @Test("Адрес ленты вшит в бандл и указывает на постоянный адрес релизов")
    func feedURLReachesTheBundle() throws {
        let feed = try #require(bundleValue("SUFeedURL") as? String)
        #expect(feed == "https://github.com/slimgo/ghostmeet/releases/latest/download/appcast.xml")
    }

    @Test("Открытый ключ на месте — без него проверять подпись обновления нечем")
    func publicKeyReachesTheBundle() throws {
        let key = try #require(bundleValue("SUPublicEDKey") as? String)
        #expect(key.isEmpty == false)
        // База64 от 32 байт ed25519 — 44 символа. Проверяется длина, а не
        // значение: значение поменяется, если ключ когда-нибудь сменят, а
        // «строка не той формы» останется ошибкой при любом ключе.
        #expect(key.count == 44)
        #expect(Data(base64Encoded: key)?.count == 32)
    }

    /// Приложение обещает «наружу уходит IP и версия и больше ничего».
    /// Отправку профиля гейтит `SUSendProfileInfo`; `SUEnableSystemProfiling`
    /// заведён рядом, чтобы задокументированный ключ не обещал обратного.
    @Test("Отправка сведений о системе выключена обоими ключами")
    func systemProfilingIsOffInTheBundle() throws {
        #expect(bundleValue("SUSendProfileInfo") as? Bool == false)
        #expect(bundleValue("SUEnableSystemProfiling") as? Bool == false)
    }

    @Test("Расписания у Sparkle нет — спрашиваем сами и один раз")
    func sparkleHasNoScheduleOfItsOwn() throws {
        #expect(bundleValue("SUEnableAutomaticChecks") as? Bool == false)
    }
}

// MARK: - Что видно в окне

@MainActor
@Suite("Строка обновления говорит то, что случилось")
struct UpdateStatusTests {

    @Test("Ничего не найдено фоновой проверкой — тишина")
    func silentWhenTheLaunchCheckFindsNothing() {
        let status = UpdateStatus()
        status.checkBegan(userInitiated: false)
        status.foundNothing()

        #expect(status.phase == .idle)
    }

    @Test("Фоновая проверка сорвалась — тоже тишина, как велит ADR-0010")
    func silentWhenTheLaunchCheckFails() {
        let status = UpdateStatus()
        status.checkBegan(userInitiated: false)
        status.failed("сеть недоступна")

        #expect(status.phase == .idle)
    }

    @Test("Нажали «проверить» и ничего нет — это говорится вслух")
    func saysSoWhenAskedAndUpToDate() {
        let status = UpdateStatus()
        status.checkBegan(userInitiated: true)
        status.foundNothing()

        #expect(status.phase == .upToDate)
    }

    /// Граница правила тишины. Молчащая сорвавшаяся установка означает
    /// человека, который уверен, что обновился, и идёт на собеседование со
    /// старой версией.
    @Test("Нажали «обновить» и не вышло — молчать нельзя")
    func neverSilentAboutAPressedInstall() {
        let status = UpdateStatus()
        status.checkBegan(userInitiated: false)
        status.offer(anUpdate) { _ in }
        status.install()
        status.failed("не удалось записать в /Applications")

        #expect(status.phase == .failed("не удалось записать в /Applications"))
    }

    /// Sparkle заканчивает так каждое обновление, включая неудавшиеся. Если
    /// `finished()` чистит фазу без разбора, сообщение об ошибке живёт
    /// миллисекунды и пользователь его не видит.
    @Test("Конец сессии не стирает уже сказанное «не вышло»")
    func theVerdictOutlivesTheSession() {
        let status = UpdateStatus()
        status.checkBegan(userInitiated: true)
        status.failed("подпись не сошлась")
        status.finished()

        #expect(status.phase == .failed("подпись не сошлась"))
    }

    @Test("Конец сессии не стирает и «у вас последняя версия»")
    func theUpToDateVerdictOutlivesTheSessionToo() {
        let status = UpdateStatus()
        status.checkBegan(userInitiated: true)
        status.foundNothing()
        status.finished()

        #expect(status.phase == .upToDate)
    }

    @Test("Прогресс после конца сессии не остаётся висеть")
    func progressDoesNotOutliveTheSession() {
        let status = UpdateStatus()
        status.downloadBegan()
        status.installingBegan()
        status.finished()

        #expect(status.phase == .idle)
    }

    @Test("Процент считается от объявленного размера")
    func reportsDownloadProgress() {
        let status = UpdateStatus()
        status.downloadBegan()
        #expect(status.phase == .downloading(fraction: nil))

        status.downloadExpects(1000)
        status.downloadReceived(250)
        #expect(status.phase == .downloading(fraction: 0.25))

        status.downloadReceived(750)
        #expect(status.phase == .downloading(fraction: 1))
    }

    @Test("Размер, которого сервер не назвал, не превращается в деление на ноль")
    func survivesAnUnknownContentLength() {
        let status = UpdateStatus()
        status.downloadBegan()
        status.downloadExpects(0)
        status.downloadReceived(100)

        #expect(status.phase == .downloading(fraction: nil))
    }

    @Test("Пришло больше объявленного — процент не уходит за сотню")
    func clampsProgressAtOne() {
        let status = UpdateStatus()
        status.downloadBegan()
        status.downloadExpects(100)
        status.downloadReceived(250)

        #expect(status.phase == .downloading(fraction: 1))
    }
}

// MARK: - Когда ставить нельзя

@MainActor
@Suite("Установка не начинается, когда начинать нельзя")
struct InstallBlockTests {

    /// `SessionController.canQuit` уже отказывается выйти при включённом
    /// прослушивании. Установка — тот же перезапуск, только не человеком.
    @Test("Во время звонка не ставится")
    func refusesDuringACall() throws {
        let reason = try #require(InstallBlock.reason(isBusy: true))
        #expect(reason.contains("прослушивание"))
    }

    @Test("Вне звонка и с правами на запись — ничто не мешает")
    func allowsWhenIdleAndWritable() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-block-\(UUID().uuidString)")
        let bundle = sandbox.appendingPathComponent("GhostMeet.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        #expect(InstallBlock.reason(isBusy: false, bundle: bundle) == nil)
    }

    /// Иначе за нас откажет Sparkle — системным диалогом с запросом пароля
    /// («… wants permission to update»), то есть чужим окном поверх
    /// демонстрируемого экрана, что запрещает ADR-0004.
    @Test("Каталог без права записи останавливает нас раньше, чем Sparkle спросит пароль")
    func refusesWhenTheContainerIsNotWritable() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-block-\(UUID().uuidString)")
        let container = sandbox.appendingPathComponent("Applications")
        let bundle = container.appendingPathComponent("GhostMeet.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
            try? FileManager.default.removeItem(at: sandbox)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: container.path)

        let reason = try #require(InstallBlock.reason(isBusy: false, bundle: bundle))
        #expect(reason.contains("нет прав на запись"))
        #expect(reason.contains(container.path), "в строке должно быть видно, куда именно не пишется")
    }

    @Test("Звонок называется первым: он пройдёт сам, а права — нет")
    func namesTheCallFirst() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/GhostMeet.app")
        let reason = try #require(InstallBlock.reason(isBusy: true, bundle: missing))
        #expect(reason.contains("прослушивание"))
    }
}

// MARK: - Видимость строки

@MainActor
@Suite("Во время звонка обновления не видно вовсе")
struct UpdateNoticeVisibilityTests {

    @Test("Пока звонок идёт — не показывается ничего, ни новость, ни прогресс")
    func hiddenWhileListening() {
        let phases: [UpdatePhase] = [
            .checking,
            .available(anUpdate),
            .downloading(fraction: 0.5),
            .preparing,
            .installing,
            .upToDate,
            .failed("что угодно")
        ]
        for phase in phases {
            #expect(phase.isVisible(whileListening: true) == false, "\(phase) не должно быть видно во время звонка")
        }
    }

    @Test("До звонка показывается всё, кроме «сказать нечего»")
    func visibleBeforeTheCall() {
        #expect(UpdatePhase.idle.isVisible(whileListening: false) == false)
        #expect(UpdatePhase.available(anUpdate).isVisible(whileListening: false))
        #expect(UpdatePhase.downloading(fraction: nil).isVisible(whileListening: false))
        #expect(UpdatePhase.failed("не вышло").isVisible(whileListening: false))
    }

    /// Спрятать строку во время звонка можно только потому, что вердикт её
    /// переживает: иначе «поставить не вышло, шёл звонок» никто бы не прочёл.
    @Test("Скрытый во время звонка отказ читается после него")
    func theRefusalIsReadableAfterTheCall() {
        let status = UpdateStatus()
        status.offer(anUpdate) { _ in }
        status.install()
        status.failed("идёт прослушивание. Обновление не установлено")
        status.finished()

        #expect(status.phase.isVisible(whileListening: true) == false)
        #expect(status.phase.isVisible(whileListening: false))
    }
}

// MARK: - Ответ на предложение

@MainActor
@Suite("Предложенное обновление ждёт нажатия и получает ровно один ответ")
struct UpdateChoiceTests {

    @Test("Пока не нажали — ответа нет, и ничего не качается")
    func waitsForThePress() {
        let status = UpdateStatus()
        var answers: [UpdateChoice] = []
        status.offer(anUpdate) { answers.append($0) }

        #expect(answers.isEmpty)
        #expect(status.phase == .available(anUpdate))
    }

    @Test("«Обновить» отвечает install")
    func installAnswersInstall() {
        let status = UpdateStatus()
        var answers: [UpdateChoice] = []
        status.offer(anUpdate) { answers.append($0) }

        status.install()

        #expect(answers == [.install])
    }

    @Test("Крестик отвечает dismiss и убирает строку")
    func dismissAnswersDismiss() {
        let status = UpdateStatus()
        var answers: [UpdateChoice] = []
        status.offer(anUpdate) { answers.append($0) }

        status.dismiss()

        #expect(answers == [.dismiss])
        #expect(status.phase == .idle)
    }

    /// Sparkle приостанавливается на этом вопросе. Ответить дважды — значит
    /// продолжить приостановленное продолжение второй раз, то есть уронить
    /// процесс.
    @Test("Ответ отдаётся ровно один раз, сколько бы раз ни нажали")
    func answersOnlyOnce() {
        let status = UpdateStatus()
        var answers: [UpdateChoice] = []
        status.offer(anUpdate) { answers.append($0) }

        status.install()
        status.install()
        status.dismiss()
        status.finished()

        #expect(answers == [.install])
    }

    /// А не ответить — значит оставить обновление, которое ни ставится, ни
    /// уходит: механизм так и стоит в ожидании до конца сеанса.
    @Test("Всякий конец обновления отвечает на неотвеченное")
    func everyEndingAnswersAPendingQuestion() {
        let status = UpdateStatus()
        var answers: [UpdateChoice] = []
        status.offer(anUpdate) { answers.append($0) }

        status.finished()

        #expect(answers == [.dismiss])
    }

    @Test("Сбой при неотвеченном предложении тоже отвечает")
    func failureAnswersAPendingQuestion() {
        let status = UpdateStatus()
        var answers: [UpdateChoice] = []
        status.offer(anUpdate) { answers.append($0) }

        status.failed("что-то пошло не так")

        #expect(answers == [.dismiss])
    }

    @Test("Второе предложение не бросает первое без ответа")
    func aSecondOfferReleasesTheFirst() {
        let status = UpdateStatus()
        var first: [UpdateChoice] = []
        var second: [UpdateChoice] = []
        status.offer(anUpdate) { first.append($0) }

        status.offer(OfferedUpdate(version: "0.5.0", notes: nil)) { second.append($0) }

        #expect(first == [.dismiss])
        #expect(second.isEmpty)
        #expect(status.phase == .available(OfferedUpdate(version: "0.5.0", notes: nil)))
    }
}
