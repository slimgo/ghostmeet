//
//  HotkeyTests.swift
//  GhostMeetTests
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// A registry that registers nothing with the system and remembers everything it
/// was asked to.
///
/// Registering a real chord from a test would take that chord away from the
/// machine running the suite for as long as the test host lives — and a test that
/// depends on a global key combination being free is a test that fails on
/// somebody else's laptop.
@MainActor
private final class FakeHotkeyRegistry: HotkeyRegistry {

    var onPress: ((HotkeyAction) -> Void)?

    /// What is registered right now.
    private(set) var registered: [HotkeyAction: Hotkey] = [:]
    /// How many times the whole set was replaced — a rebind that forgets to
    /// re-register is invisible any other way.
    private(set) var replacements = 0
    /// Actions the "system" refuses, as if another application owned the chord.
    var refuses: Set<HotkeyAction> = []

    @discardableResult
    func replaceAll(with bindings: [HotkeyAction: Hotkey]) -> Set<HotkeyAction> {
        replacements += 1
        let refused = refuses.intersection(Set(bindings.keys))
        registered = bindings.filter { !refused.contains($0.key) }
        return refused
    }

    /// The user pressed the chord bound to `action`.
    func press(_ action: HotkeyAction) {
        onPress?(action)
    }
}

/// A source that starts and stays silent — enough to reach `isListening` without
/// any audio hardware.
private final class SilentSource: AudioSource, @unchecked Sendable {
    let channel: Channel
    private(set) var isRunning = false

    init(channel: Channel = .you) {
        self.channel = channel
    }

    func start(onFrame: @escaping AudioFrameHandler) throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

/// A composer that only records what it was handed.
@MainActor
private final class RecordingComposer: SuggestionComposer {
    private(set) var seen: [[Turn]] = []

    func compose(
        _ ask: SuggestionAsk,
        transcript: [Turn],
        screen: ScreenContext,
        accepting capabilities: ProviderCapabilities
    ) -> SuggestionRequest {
        seen.append(transcript)
        return SuggestionRequest(
            systemPrompt: "",
            userPrompt: transcript.map(\.text).joined(separator: " | "),
            screenshot: nil,
            maxTokens: 256
        )
    }
}

// MARK: - Helpers

/// Runs `body` against a throwaway defaults suite, so no test touches the user's
/// own settings — hotkeys included.
@MainActor
private func withScratchSettings<T>(_ body: (SettingsStore, UserDefaults) throws -> T) rethrows -> T {
    let name = "GhostMeetHotkeyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()), defaults)
}

/// Waits for something that lands on a later turn of the main actor.
@MainActor
private func eventually(_ condition: () -> Bool, attempts: Int = 2_000) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 200_000)
    }
    return condition()
}

/// A session that listens for real (on a silent source) and whose turns the test
/// feeds by hand.
@MainActor
private struct ListeningCall {
    let controller: SessionController
    let engine: SessionEngine
    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(recognisesAs text: String = "реплика") {
        let clock = ManualClock()
        let engine = SessionEngine(
            sources: [SilentSource(), SilentSource(channel: .them)],
            recognizer: RecognizerSpy(reply: text),
            clock: clock
        )
        self.clock = clock
        self.engine = engine
        self.controller = SessionController(
            engine: engine,
            requestMicrophoneAccess: { true }
        )
    }

    func someoneSpeaks(for seconds: TimeInterval, on channel: Channel) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
    }

    func silenceLasts(_ seconds: TimeInterval, on channel: Channel) {
        feed(seconds: seconds) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    private func feed(seconds: TimeInterval, frame: () -> AudioFrame) {
        let frames = Int((seconds / frameLength).rounded())
        for _ in 0..<frames {
            clock.advance(by: frameLength)
            engine.ingest(frame())
        }
    }
}

// MARK: - The chords themselves

@MainActor
@Suite("Комбинации клавиш")
struct HotkeyValueTests {

    @Test("У каждого действия своя комбинация, и все они пригодны для глобальной регистрации")
    func defaultsAreUsableAndDistinct() {
        let defaults = HotkeyBindings.default
        var seen: Set<Hotkey> = []
        for action in HotkeyAction.allCases {
            let hotkey = try! #require(defaults[action])
            #expect(hotkey.isValid, "\(action.rawValue): комбинация без ⌘/⌥/⌃ отберёт обычный ввод у всей системы")
            #expect(seen.insert(hotkey).inserted, "\(hotkey.displayString) назначена дважды — сработает только одно действие")
        }
    }

    @Test("Комбинация без сильного модификатора не считается годной")
    func aChordWithoutAStrongModifierIsRejected() {
        // Глобальный хоткей перебивает активное приложение: ⇧K, зарегистрированный
        // системно, перестал бы давать заглавную K в браузере со звонком.
        #expect(Hotkey(kVK_ANSI_K, []).isValid == false)
        #expect(Hotkey(kVK_ANSI_K, [.shift]).isValid == false)
        #expect(Hotkey(kVK_ANSI_K, [.command]).isValid)
        #expect(Hotkey(kVK_ANSI_K, [.control]).isValid)
        #expect(Hotkey(kVK_ANSI_K, [.option]).isValid)
    }

    @Test("Комбинация читается так, как её печатает macOS")
    func aChordReadsTheWayMacOSPrintsIt() {
        #expect(Hotkey(kVK_ANSI_L, [.command, .option]).displayString == "⌥⌘L")
        #expect(Hotkey(kVK_ANSI_Backslash, [.command]).displayString == "⌘\\")
        #expect(Hotkey(kVK_ANSI_Period, [.command, .option]).displayString == "⌥⌘.")
        // Порядок символов у Apple фиксированный: ⌃⌥⇧⌘.
        #expect(Hotkey(kVK_F13, [.command, .control, .option, .shift]).displayString == "⌃⌥⇧⌘F13")
    }

    @Test("Модификаторы переводятся в биты, которых ждёт Carbon")
    func modifiersTranslateToCarbon() {
        #expect(HotkeyModifiers.command.carbonValue == UInt32(cmdKey))
        #expect(HotkeyModifiers.shift.carbonValue == UInt32(shiftKey))
        #expect(HotkeyModifiers.option.carbonValue == UInt32(optionKey))
        #expect(HotkeyModifiers.control.carbonValue == UInt32(controlKey))
        #expect(
            HotkeyModifiers([.command, .option]).carbonValue == UInt32(cmdKey) | UInt32(optionKey)
        )
    }

    /// Три аккорда, которые жмут во время звонка, — один куст под одной рукой:
    /// `A`, `Z` и `X` стоят друг под другом в левом нижнем углу, так что большой
    /// палец держит ⌥⌘, а остальные достают до всех трёх, не двигая кисть.
    /// ⌥⌘E требовал второй руки — это и была жалоба.
    @Test("Аккорды звонка лежат одним кустом под левой рукой")
    func theCallChordsAreOneCluster() {
        #expect(HotkeyAction.suggestBriefly.defaultHotkey == Hotkey(kVK_ANSI_A, [.command, .option]))
        #expect(HotkeyAction.suggestInDetail.defaultHotkey == Hotkey(kVK_ANSI_Z, [.command, .option]))
        #expect(HotkeyAction.solveOnScreen.defaultHotkey == Hotkey(kVK_ANSI_X, [.command, .option]))

        // Соседи заняты системой и редакторами, и глобальный аккорд отнял бы их
        // у всей машины: ⌥⌘D прячет Dock, ⌥⌘S — «Save All» в VS Code,
        // ⌥⌘W закрывает окна, ⌥⌘V — «Переместить» в Finder.
        let forbidden = [kVK_ANSI_D, kVK_ANSI_S, kVK_ANSI_W, kVK_ANSI_V]
        for action in HotkeyAction.allCases {
            #expect(
                !(forbidden.contains(Int(action.defaultHotkey.keyCode)) && action.defaultHotkey.modifiers == [.command, .option]),
                "\(action.rawValue) занял чужой системный аккорд"
            )
        }
    }

    @Test("Старый аккорд, которого никто не менял, переезжает на новый")
    func anUntouchedChordMovesOn() throws {
        var stored = HotkeyBindings.default
        stored[.suggestInDetail] = Hotkey(kVK_ANSI_E, [.command, .option])
        stored[.solveOnScreen] = Hotkey(kVK_ANSI_G, [.command, .option])

        let revived = try JSONDecoder().decode(
            HotkeyBindings.self,
            from: try JSONEncoder().encode(stored)
        )

        #expect(revived[.suggestInDetail] == Hotkey(kVK_ANSI_Z, [.command, .option]))
        #expect(revived[.solveOnScreen] == Hotkey(kVK_ANSI_X, [.command, .option]))
    }

    /// Граница между решением и наследством: аккорд, равный снятому умолчанию,
    /// никто не выбирал. Всё остальное — выбор пользователя, и трогать его нельзя.
    @Test("Аккорд, выбранный пользователем, миграция не трогает")
    func aChosenChordSurvives() throws {
        var stored = HotkeyBindings.default
        stored[.suggestInDetail] = Hotkey(kVK_ANSI_J, [.command, .option])

        let revived = try JSONDecoder().decode(
            HotkeyBindings.self,
            from: try JSONEncoder().encode(stored)
        )

        #expect(revived[.suggestInDetail] == Hotkey(kVK_ANSI_J, [.command, .option]))
    }

    @Test("Новый аккорд уже занят — миграция не отбирает его, а оставляет старый")
    func aTakenChordIsNotStolen() throws {
        var stored = HotkeyBindings.default
        stored[.suggestInDetail] = Hotkey(kVK_ANSI_E, [.command, .option])
        stored[.clearContext] = Hotkey(kVK_ANSI_Z, [.command, .option])

        let revived = try JSONDecoder().decode(
            HotkeyBindings.self,
            from: try JSONEncoder().encode(stored)
        )

        #expect(revived[.clearContext] == Hotkey(kVK_ANSI_Z, [.command, .option]))
        #expect(revived[.suggestInDetail] == Hotkey(kVK_ANSI_E, [.command, .option]))
    }

    @Test("Комбинация переживает кодирование и раскодирование")
    func aChordSurvivesEncoding() throws {
        let bindings = HotkeyBindings.default
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode(HotkeyBindings.self, from: data) == bindings)
    }
}

// MARK: - Rebinding and persistence

@MainActor
@Suite("Переназначение и сохранение хоткеев")
struct HotkeyBindingTests {

    @Test("Хоткей переназначается, и окно показывает новую комбинацию")
    func rebindingChangesTheChord() {
        withScratchSettings { settings, _ in
            let registry = FakeHotkeyRegistry()
            let center = HotkeyCenter(store: settings, registry: registry)
            center.activate()

            let replacement = Hotkey(kVK_ANSI_G, [.command, .option])
            center.rebind(.toggleVisibility, to: replacement)

            #expect(center.bindings[.toggleVisibility] == replacement)
            #expect(center.displayString(for: .toggleVisibility) == "⌥⌘G")
            #expect(registry.registered[.toggleVisibility] == replacement, "переназначение обязано перерегистрировать комбинацию в системе")
        }
    }

    @Test("Комбинация, занятая другим действием, отбирается у него, а не дублируется")
    func aChordIsTakenFromWhoeverHadIt() {
        withScratchSettings { settings, _ in
            let center = HotkeyCenter(store: settings, registry: FakeHotkeyRegistry())
            let panic = try! #require(center.bindings[.toggleVisibility])

            center.rebind(.clearContext, to: panic)

            #expect(center.bindings[.clearContext] == panic)
            #expect(center.bindings[.toggleVisibility] == nil, "две команды на одной комбинации — состояние, которого система не отдаст")
        }
    }

    @Test("Хоткей можно выключить совсем")
    func aChordCanBeCleared() {
        withScratchSettings { settings, _ in
            let registry = FakeHotkeyRegistry()
            let center = HotkeyCenter(store: settings, registry: registry)

            center.rebind(.clearContext, to: nil)

            #expect(center.bindings[.clearContext] == nil)
            #expect(center.displayString(for: .clearContext) == "—")
            #expect(registry.registered[.clearContext] == nil)
        }
    }

    @Test("Переназначенный хоткей переживает перезапуск приложения")
    func aRebindingSurvivesARelaunch() {
        let name = "GhostMeetHotkeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }

        let replacement = Hotkey(kVK_F14, [.control, .option])
        let before = HotkeyCenter(
            store: SettingsStore(defaults: defaults, secrets: InMemorySecretStore()),
            registry: FakeHotkeyRegistry()
        )
        before.rebind(.startListening, to: replacement)

        // Следующий запуск: новый store поверх тех же defaults.
        let after = HotkeyCenter(
            store: SettingsStore(defaults: defaults, secrets: InMemorySecretStore()),
            registry: FakeHotkeyRegistry()
        )

        #expect(after.bindings[.startListening] == replacement)
    }

    @Test("Выключенный хоткей не воскресает после перезапуска")
    func aClearedChordStaysCleared() {
        let name = "GhostMeetHotkeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }

        let before = HotkeyCenter(
            store: SettingsStore(defaults: defaults, secrets: InMemorySecretStore()),
            registry: FakeHotkeyRegistry()
        )
        before.rebind(.stopListening, to: nil)

        let after = HotkeyCenter(
            store: SettingsStore(defaults: defaults, secrets: InMemorySecretStore()),
            registry: FakeHotkeyRegistry()
        )

        #expect(after.bindings[.stopListening] == nil, "возвращённая по умолчанию комбинация отменила бы решение пользователя")
    }

    @Test("Сброс возвращает то, что поставлялось")
    func resetRestoresTheShippedChords() {
        withScratchSettings { settings, _ in
            let center = HotkeyCenter(store: settings, registry: FakeHotkeyRegistry())
            center.rebind(.startListening, to: Hotkey(kVK_F15, [.control, .option]))
            center.rebind(.stopListening, to: nil)

            center.resetToDefaults()

            #expect(center.bindings == HotkeyBindings.default)
        }
    }

    @Test("Занятую другим приложением комбинацию объясняют словами, а не молчанием")
    func aRefusedChordIsExplained() {
        withScratchSettings { settings, _ in
            let registry = FakeHotkeyRegistry()
            registry.refuses = [.toggleVisibility]
            let center = HotkeyCenter(store: settings, registry: registry)

            center.activate()

            #expect(center.unavailable == [.toggleVisibility])
            let problem = try! #require(center.problem(with: .toggleVisibility))
            #expect(problem.contains(center.displayString(for: .toggleVisibility)))
            #expect(problem.count > 20, "«\(problem)» — это не объяснение")
            #expect(center.problem(with: .startListening) == nil)
        }
    }

    @Test("Регистрируется ровно то, что назначено пользователем")
    func onlyAssignedChordsAreRegistered() {
        withScratchSettings { settings, _ in
            let registry = FakeHotkeyRegistry()
            let center = HotkeyCenter(store: settings, registry: registry)
            center.rebind(.clearContext, to: nil)

            #expect(
                Set(registry.registered.keys) == Set(HotkeyAction.allCases).subtracting([.clearContext])
            )
        }
    }
}

// MARK: - Carbon, and the permission it does not ask for

@MainActor
@Suite("Регистрация без разрешения Accessibility")
struct CarbonRegistrationTests {

    @Test("Carbon отдаёт глобальную комбинацию без единого запроса разрешений")
    func carbonRegistersWithoutAskingForAnything() {
        // Смысл теста — в том, чего в нём нет: ни запроса Accessibility, ни
        // AXIsProcessTrusted. RegisterEventHotKey работает у непривилегированного
        // процесса, и именно поэтому выбран он, а не NSEvent-монитор.
        let registry = CarbonHotkeyRegistry()
        defer { registry.replaceAll(with: [:]) }

        // Заведомо экзотическая комбинация: занятая кем-то ещё сделала бы тест
        // зависимым от того, что установлено на машине.
        let chord = Hotkey(kVK_ANSI_Grave, [.control, .option, .command])
        let refused = registry.replaceAll(with: [.toggleVisibility: chord])

        #expect(refused.isEmpty, "система отказала в регистрации — проверьте, не занята ли \(chord.displayString)")
    }

    @Test("Негодная комбинация до системы не доходит")
    func anInvalidChordNeverReachesTheSystem() {
        let registry = CarbonHotkeyRegistry()
        defer { registry.replaceAll(with: [:]) }

        let refused = registry.replaceAll(with: [.clearContext: Hotkey(kVK_ANSI_K, [.shift])])

        #expect(refused == [.clearContext])
    }
}

// MARK: - What a press does

@MainActor
@Suite("Нажатие хоткея")
struct HotkeyDispatchTests {

    @Test("Нажатие запускает ровно то действие, которое к нему привязано")
    func aPressRunsItsOwnAction() {
        withScratchSettings { settings, _ in
            let registry = FakeHotkeyRegistry()
            let center = HotkeyCenter(store: settings, registry: registry)

            var ran: [HotkeyAction] = []
            center.actions = HotkeyActions(
                toggleVisibility: { ran.append(.toggleVisibility) },
                startListening: { ran.append(.startListening) },
                stopListening: { ran.append(.stopListening) },
                clearContext: { ran.append(.clearContext) }
            )
            center.activate()

            registry.press(.clearContext)
            registry.press(.toggleVisibility)

            #expect(ran == [.clearContext, .toggleVisibility])
        }
    }

    @Test("Действия можно переназначить после регистрации — подписка не устаревает")
    func actionsSetAfterRegistrationStillFire() {
        withScratchSettings { settings, _ in
            let registry = FakeHotkeyRegistry()
            let center = HotkeyCenter(store: settings, registry: registry)
            center.activate()

            var fired = false
            center.actions = HotkeyActions(stopListening: { fired = true })
            registry.press(.stopListening)

            #expect(fired)
        }
    }
}

// MARK: - Panic

@MainActor
@Suite("Паника прячет окно, но не сессию")
struct PanicHotkeyTests {

    @Test("Паника убирает окно с глаз, захват при этом продолжается")
    func hidingTheWindowDoesNotStopCapture() async {
        let session = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true }
        )
        session.start()
        await session.waitForStart()
        #expect(session.isListening)

        let overlay = withScratchSettings { settings, defaults in
            OverlayWindowController(
                session: session,
                recognition: SpeechModelStatus(store: settings, provider: FakeSpeechModelProvider()),
                hotkeys: HotkeyCenter(store: settings, registry: FakeHotkeyRegistry()),
                openSettings: { _ in },
                stateStore: WindowStateStore(defaults: defaults)
            )
        }
        overlay.show()
        #expect(overlay.isVisible)

        overlay.toggleVisibility()

        #expect(overlay.isVisible == false, "паник-хоткей обязан убрать окно немедленно")
        #expect(session.isListening, "спрятанное окно — не остановленный звонок: захват должен продолжаться")

        overlay.toggleVisibility()
        #expect(overlay.isVisible, "тот же хоткей обязан вернуть окно")
        #expect(session.isListening)

        session.stop()
        overlay.hide()
    }

    @Test("Паник-хоткей, привязанный к окну, ходит через тот же путь, что и клавиша")
    func theBoundPanicActionHidesTheWindow() async {
        let session = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true }
        )
        session.start()
        await session.waitForStart()

        let registry = FakeHotkeyRegistry()
        let (overlay, center) = withScratchSettings { settings, defaults -> (OverlayWindowController, HotkeyCenter) in
            let center = HotkeyCenter(store: settings, registry: registry)
            let overlay = OverlayWindowController(
                session: session,
                recognition: SpeechModelStatus(store: settings, provider: FakeSpeechModelProvider()),
                hotkeys: center,
                openSettings: { _ in },
                stateStore: WindowStateStore(defaults: defaults)
            )
            return (overlay, center)
        }
        center.actions = HotkeyActions(
            toggleVisibility: { overlay.toggleVisibility() },
            stopListening: { session.stop() }
        )
        center.activate()
        overlay.show()

        registry.press(.toggleVisibility)

        #expect(overlay.isVisible == false)
        #expect(session.isListening, "паника не имеет права трогать захват")

        session.stop()
        overlay.hide()
    }
}

// MARK: - Starting by hotkey

@MainActor
@Suite("Старт по хоткею ждёт готовности модели")
struct StartByHotkeyTests {

    @Test("Хоткей нажат, пока модель качается — сессия стартует сама, когда та готова")
    func aHotkeyPressedTooEarlyWaitsForTheModel() async {
        let door = Gate()
        let (status, center, registry) = withScratchSettings { settings, _ -> (SpeechModelStatus, HotkeyCenter, FakeHotkeyRegistry) in
            let registry = FakeHotkeyRegistry()
            return (
                SpeechModelStatus(store: settings, provider: FakeSpeechModelProvider(download: .held(door))),
                HotkeyCenter(store: settings, registry: registry),
                registry
            )
        }
        let session = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true },
            isRecognitionReady: { status.phase.isReady }
        )
        center.actions = HotkeyActions(
            startListening: { session.startWhenRecognitionIsReady() },
            stopListening: { session.stop() }
        )
        center.activate()

        status.prepare()
        #expect(await eventually { status.phase.isBusy }, "подготовка модели должна была начаться")

        registry.press(.startListening)
        #expect(session.isListening == false, "слушать нечем: реплика, закрытая до готовности модели, отвергается")

        await door.open()

        #expect(
            await eventually { session.isListening },
            "хоткей обязан ходить через startWhenRecognitionIsReady(): start() здесь молча ничего бы не сделал, и первая фраза интервью потерялась бы"
        )

        registry.press(.stopListening)
        #expect(session.isListening == false)
    }

    @Test("Модель уже готова — хоткей включает прослушивание сразу")
    func aReadyModelStartsOnThePress() async {
        let status = withScratchSettings { settings, _ in
            SpeechModelStatus(store: settings, provider: FakeSpeechModelProvider())
        }
        let session = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true },
            isRecognitionReady: { status.phase.isReady }
        )
        status.prepare()
        #expect(await eventually { status.phase.isReady })

        session.startWhenRecognitionIsReady()
        await session.waitForStart()

        #expect(session.isListening)
        session.stop()
    }
}

// MARK: - Clearing the conversation

@MainActor
@Suite("Очистка контекста")
struct ClearContextTests {

    @Test("Очистка стирает разговор, но не останавливает прослушивание")
    func clearingEmptiesTheConversationAndKeepsListening() async {
        let call = ListeningCall(recognisesAs: "расскажите про GC")
        call.controller.start()
        await call.controller.waitForStart()

        call.someoneSpeaks(for: 1.2, on: .them)
        call.silenceLasts(1.6, on: .them)
        await call.engine.waitForRecognition()
        #expect(call.controller.transcript.count == 1)

        call.controller.clearContext()

        #expect(call.controller.transcript.isEmpty, "окно обязано забыть разговор")
        #expect(call.controller.isListening, "очистка контекста — это «начать разговор заново», а не «стоп»")

        call.controller.stop()
    }

    @Test("После очистки новые реплики снова копятся")
    func theConversationStartsOverRatherThanStopping() async {
        let call = ListeningCall(recognisesAs: "второй вопрос")
        call.controller.start()
        await call.controller.waitForStart()

        call.someoneSpeaks(for: 1.2, on: .them)
        call.silenceLasts(1.6, on: .them)
        await call.engine.waitForRecognition()
        call.controller.clearContext()

        call.someoneSpeaks(for: 1.2, on: .you)
        call.silenceLasts(1.6, on: .you)
        await call.engine.waitForRecognition()

        #expect(call.controller.transcript.count == 1)
        #expect(call.controller.transcript.first?.channel == .you)

        call.controller.stop()
    }

    @Test("Забытые реплики не доезжают до модели, а не только до окна")
    func aClearedTurnNeverReachesThePrompt() {
        let context = ConversationContext()
        let inner = RecordingComposer()
        let composer = ContextLimitedComposer(context: context, wrapped: inner)

        let forgotten = Turn(channel: .them, text: "старый вопрос", timestamp: 0, duration: 1)
        let kept = Turn(channel: .them, text: "новый вопрос", timestamp: 10, duration: 1)

        context.forget(turns: [forgotten], suggestions: [])
        let request = composer.compose(
            .brief,
            transcript: [forgotten, kept],
            screen: .none,
            accepting: .multimodal
        )

        #expect(inner.seen.last?.map(\.text) == ["новый вопрос"])
        #expect(request.userPrompt.contains("новый вопрос"))
        #expect(
            !request.userPrompt.contains("старый вопрос"),
            "очистка, которая опустошает только окно, — обман: модель продолжила бы отвечать по стёртому контексту"
        )
    }

    @Test("Очистка забывает и подсказки")
    func clearingForgetsSuggestionsToo() {
        let context = ConversationContext()
        let old = Suggestion(text: "прошлый ответ", state: .complete, startedAt: Date())
        let new = Suggestion(text: "новый ответ", state: .complete, startedAt: Date())

        context.forget(turns: [], suggestions: [old])

        #expect(context.remembered([old, new]).map(\.text) == ["новый ответ"])
    }

    @Test("Профиль переживает очистку контекста")
    func theProfileOutlivesTheConversation() async {
        withScratchSettings { settings, _ in
            settings.profile = UserProfile(
                role: "iOS-разработчик",
                experience: "8 лет",
                stack: "Swift, SwiftUI"
            )
            let call = ListeningCall()

            call.controller.clearContext()

            #expect(settings.profile.role == "iOS-разработчик", "профиль относится к пользователю, а не к звонку")
        }
    }
}

// MARK: - Indicators

@MainActor
@Suite("Индикаторы состояния по каналам")
struct SessionIndicatorTests {

    private func indicators(
        isListening: Bool = false,
        failure: SessionController.Failure? = nil,
        recognition: SpeechModelPhase = .ready,
        themStatus: ThemCaptureStatus = .idle,
        isPreparingAnswer: Bool = false,
        isGenerating: Bool = false,
        suggestionFailure: String? = nil
    ) -> SessionIndicators {
        SessionIndicators.make(
            isListening: isListening,
            failure: failure,
            recognition: recognition,
            themStatus: themStatus,
            isPreparingAnswer: isPreparingAnswer,
            isGenerating: isGenerating,
            suggestionFailure: suggestionFailure
        )
    }

    @Test("Каналы показываются раздельно и могут быть в разных состояниях одновременно")
    func theTwoChannelsAreReportedApart() {
        let state = indicators(
            isListening: true,
            themStatus: .idle
        )

        #expect(state.you.state == .listening)
        #expect(state.them.state == .waiting, "микрофон слушает, а источник для Them не выбран — это два разных состояния")
        #expect(state.you.name == "You")
        #expect(state.them.name == "Them")
    }

    @Test("Слушает: оба канала зелёные, когда звук идёт с обоих")
    func bothChannelsListen() {
        let state = indicators(isListening: true, themStatus: .capturing(application: "Google Chrome"))

        #expect(state.you.state == .listening)
        #expect(state.them.state == .listening)
        #expect(state.them.detail.contains("Google Chrome"))
    }

    @Test("Думает: пока модель пишет, это состояние модели, а не канала")
    func thinkingBelongsToTheModel() {
        let state = indicators(
            isListening: true,
            themStatus: .capturing(application: "Google Chrome"),
            isGenerating: true
        )

        #expect(state.model.state == .thinking)
        #expect(state.them.state == .listening, "генерация не имеет права выглядеть как остановленный захват")
        #expect(state.you.state == .listening)
    }

    @Test("Ошибка: отказ микрофона перебивает всё остальное и объясняется словами")
    func aDeniedMicrophoneOutranksEverything() {
        let state = indicators(isListening: false, failure: .microphoneDenied, recognition: .loading)

        #expect(state.you.state == .failed)
        #expect(state.you.detail.contains("Системных настройках"), "текст обязан говорить, что именно открыть")
        #expect(state.you.detail == SessionController.Failure.microphoneDenied.message)
    }

    @Test("Ошибка канала Them: причина берётся из самого захвата")
    func aBrokenThemChannelSaysWhy() {
        let state = indicators(
            isListening: true,
            themStatus: .failed(reason: ThemCaptureBackend.screenRecordingHelp)
        )

        #expect(state.them.state == .failed)
        #expect(state.them.detail.contains("Запись экрана"), "отсутствующее разрешение обязано называть, что открыть")
        #expect(state.them.state.deservesAnExplanation, "это не место для всплывающей подсказки — текст должен быть в окне")
    }

    @Test("Все состояния канала Them доезжают до пользователя своими словами")
    func everyThemStatusIsSpelledOut() {
        let cases: [(ThemCaptureStatus, IndicatorState)] = [
            (.idle, .waiting),
            (.waitingForSource(application: "Google Chrome"), .waiting),
            (.restarting(attempt: 2), .waiting),
            (.failed(reason: "аудиоустройство исчезло"), .failed)
        ]
        for (status, expected) in cases {
            let state = indicators(isListening: true, themStatus: status)
            #expect(state.them.state == expected)
            // Причина сохраняется дословно; у отказа посреди звонка перед ней
            // встаёт то, чего в причине нет, — чем это состояние обходится.
            #expect(state.them.detail.contains(status.message))
            #expect(state.them.detail.count > 15, "«\(state.them.detail)» — это не объяснение")
        }
    }

    @Test("Сломанный захват Them виден и до старта прослушивания")
    func aBrokenThemChannelIsVisibleBeforeTheCall() {
        let state = indicators(isListening: false, themStatus: .failed(reason: "нет разрешения"))

        #expect(state.them.state == .failed, "узнать про сломанный канал лучше до звонка, а не посреди него")
    }

    @Test("Модель ещё качается — это ожидание, а не ошибка")
    func aDownloadingModelIsNotAnError() {
        let state = indicators(recognition: .downloading(fraction: 0.42))

        #expect(state.you.state == .waiting)
        #expect(state.you.detail.contains("42"))
        #expect(state.you.state != .failed)
    }

    @Test("Ничего не запущено — все индикаторы спокойны и ничего не объясняют")
    func anIdleSessionExplainsNothing() {
        let state = indicators()

        #expect(state.all.allSatisfy { $0.state == .idle })
        #expect(state.all.allSatisfy { !$0.state.deservesAnExplanation })
        #expect(state.all.allSatisfy { !$0.detail.isEmpty }, "подсказка нужна даже для спокойного состояния")
    }

    @Test("Провалившийся запрос к модели виден на индикаторе модели")
    func aFailedRequestShowsOnTheModel() {
        let state = indicators(isListening: true, suggestionFailure: "Провайдер отклонил ключ.")

        #expect(state.model.state == .failed)
        #expect(state.model.detail == "Провайдер отклонил ключ.")
        #expect(state.them.state != .failed, "провайдер и захват — разные вещи")
    }

    @Test("У каждого индикатора свой устойчивый id — строка в шапке не перетасовывается")
    func indicatorsHaveStableIdentity() {
        let state = indicators()
        #expect(state.all.map(\.id) == ["you", "them", "model"])
    }
}

// MARK: - Nothing leaves the window

@MainActor
@Suite("Ничего не уходит в систему")
struct NoSystemNoiseTests {

    @Test("Приложение остаётся accessory и не вешает бейдж в Dock")
    func theAppStaysInvisibleToTheSystem() {
        // Баннер, звук или бейдж рисуются поверх расшаренного экрана и выдают
        // приложение собеседнику (ADR-0004). Тест-хост — это само приложение,
        // поэтому здесь проверяется реальное состояние процесса.
        #expect(NSApp.activationPolicy() == .accessory)
        #expect(NSApp.dockTile.badgeLabel == nil)
    }

    @Test("Отказ системы по хоткею остаётся внутри окна")
    func aRefusedChordStaysInsideTheWindow() {
        withScratchSettings { settings, _ in
            let registry = FakeHotkeyRegistry()
            registry.refuses = Set(HotkeyAction.allCases)
            let center = HotkeyCenter(store: settings, registry: registry)

            center.activate()

            #expect(center.unavailable == Set(HotkeyAction.allCases))
            #expect(NSApp.dockTile.badgeLabel == nil)
            for action in HotkeyAction.allCases {
                #expect(center.problem(with: action) != nil, "причина обязана быть в окне, а не в баннере")
            }
        }
    }
}
