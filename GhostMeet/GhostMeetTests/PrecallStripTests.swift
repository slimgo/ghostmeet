//
//  PrecallStripTests.swift
//  GhostMeetTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import GhostMeet

// MARK: - Helpers

/// Runs `body` against a throwaway defaults suite and an in-memory keychain, so
/// no test touches the user's own profiles or their provider keys.
@MainActor
private func withScratchSettings<T>(_ body: (SettingsStore) throws -> T) rethrows -> T {
    let name = "GhostMeetPrecallStripTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()))
}

/// A readiness built without asking the system what is running, so the source
/// field is decided by the stored id alone and the test stays hermetic.
@MainActor
private func readiness(of settings: SettingsStore) -> PrecallReadiness {
    PrecallReadiness.make(settings: settings, applicationName: { _ in nil })
}

// MARK: - Что показывает строка

@MainActor
@Suite("Строка готовности показывает фактические значения")
struct PrecallReadinessValuesTests {

    @Test("Профиль в строке — выбранный, а не первый и не любой")
    func theStripNamesTheSelectedProfile() {
        withScratchSettings { settings in
            settings.profile = UserProfile(
                id: settings.selectedProfileID,
                name: "Тимлид",
                role: "team lead",
                experience: "9 лет",
                stack: "Go, k8s"
            )
            let second = settings.addProfile(named: "Синьор фулстек")
            settings.updateProfile(
                UserProfile(id: second, name: "Синьор фулстек", role: "fullstack", stack: "TS, Postgres")
            )

            settings.selectProfile(second)
            #expect(readiness(of: settings).profile.value == "Синьор фулстек")

            settings.selectProfile(settings.profiles[0].id)
            #expect(readiness(of: settings).profile.value == "Тимлид")
        }
    }

    @Test("Провайдер и модель — те, что уйдут в запрос")
    func theStripNamesTheProviderAndTheModel() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(presetID: "gemini")
            let item = readiness(of: settings).provider
            #expect(item.value.contains("Gemini"), "провайдер обязан быть назван: «\(item.value)»")
            #expect(
                item.value.contains(ProviderFactory.preset(id: "gemini")!.defaultModel),
                "модель обязана быть названа: «\(item.value)»"
            )
        }
    }

    @Test("Своя модель поверх предустановки побеждает — иначе строка врёт")
    func anOverriddenModelIsWhatTheStripShows() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(
                presetID: "openai",
                model: "gpt-5.6-terra-mini"
            )
            let item = readiness(of: settings).provider
            #expect(item.value.contains("gpt-5.6-terra-mini"))
            #expect(!item.value.contains(ProviderFactory.preset(id: "openai")!.defaultModel + " "))
        }
    }

    @Test("У CLI показывается команда: модели у него нет, а отвечает именно она")
    func aCLIToolIsNamedByItsCommand() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(presetID: "claude-cli")
            #expect(readiness(of: settings).provider.value.contains("claude -p"))

            settings.providerSelection = ProviderSelection(
                presetID: "claude-cli",
                commandOverride: "/opt/homebrew/bin/claude -p"
            )
            #expect(readiness(of: settings).provider.value.contains("/opt/homebrew/bin/claude -p"))
        }
    }

    @Test("Источник назван по-человечески, а не идентификатором бандла")
    func theSourceIsNamedInWords() {
        withScratchSettings { settings in
            settings.themSourceApplicationID = "com.google.Chrome"
            let item = readiness(of: settings).source
            #expect(item.value == "Chrome")
            #expect(item.isMissing == false)
            #expect(
                item.detail.contains(ThemCaptureBackend.screenCaptureKit.displayName),
                "пользователю важно, каким бэкендом слушают: «\(item.detail)»"
            )
        }
    }

    @Test("Имя приложения берётся из системы, когда оно запущено")
    func aRunningApplicationLendsItsOwnName() {
        withScratchSettings { settings in
            settings.themSourceApplicationID = "com.google.Chrome"
            let item = PrecallReadiness.make(
                settings: settings,
                applicationName: { $0 == "com.google.Chrome" ? "Google Chrome" : nil }
            ).source
            #expect(item.value == "Google Chrome")
        }
    }

    @Test("Процесс без бандла помнится путём — и всё равно называется словом")
    func aPathIdentityStillReadsAsAName() {
        #expect(PrecallReadiness.derivedName(fromID: "/Applications/Telegram.app") == "Telegram")
        #expect(PrecallReadiness.derivedName(fromID: "com.brave.Browser") == "Browser")
        #expect(PrecallReadiness.derivedName(fromID: "Zoom") == "Zoom")
    }

    @Test("Строка — ровно три поля и ни одной заглушки в них")
    func theStripHasThreeFieldsAndNoPlaceholders() {
        withScratchSettings { settings in
            settings.profile = UserProfile(
                id: settings.selectedProfileID,
                name: "Тимлид",
                role: "team lead"
            )
            settings.themSourceApplicationID = "com.google.Chrome"
            let strip = readiness(of: settings)

            #expect(strip.all.map(\.id) == ["profile", "provider", "source"])
            for item in strip.all {
                #expect(!item.value.isEmpty, "поле «\(item.id)» пустое")
                #expect(item.detail.count > 20, "поле «\(item.id)» объясняет себя одним словом: «\(item.detail)»")
                #expect(!item.value.contains("—"), "прочерк вместо значения — это заглушка")
                #expect(!item.value.contains("nil"))
            }
        }
    }

    @Test("Строка не повторяет индикаторы: в ней нет состояний каналов")
    func theStripSaysNothingAboutWhatIsHappeningNow() {
        withScratchSettings { settings in
            settings.themSourceApplicationID = "com.google.Chrome"
            let said = readiness(of: settings).all
                .flatMap { [$0.value, $0.detail] }
                .joined(separator: " ")
                .lowercased()
            // Слова индикаторов из тикета 10. Строка готовности отвечает на
            // другой вопрос — «чем я вооружён», — и, повторив их, стала бы
            // четвёртым индикатором в окне, где место занимает лента.
            for word in ["слушает", "думает", "прослушивание выключено", "модель пишет"] {
                #expect(!said.contains(word), "строка готовности повторяет индикатор: «\(word)»")
            }
        }
    }
}

// MARK: - Чего не хватает

@MainActor
@Suite("Строка готовности показывает пробелы заранее")
struct PrecallReadinessGapsTests {

    @Test("Источник не выбран — сказано словами, а не пустым местом")
    func anUnpickedSourceIsStated() {
        withScratchSettings { settings in
            let item = readiness(of: settings).source
            #expect(item.isMissing)
            #expect(item.value.contains("не выбран"))
            #expect(item.detail.contains("Them"))
        }
    }

    @Test("Пустой профиль — это пробел, даже когда у него есть имя")
    func anEmptyProfileIsAGap() {
        withScratchSettings { settings in
            let empty = readiness(of: settings).profile
            #expect(empty.isMissing, "профиль без роли, опыта и стека ничего не добавляет в промпт")

            settings.profile = UserProfile(
                id: settings.selectedProfileID,
                name: "Тимлид",
                role: "team lead"
            )
            let filled = readiness(of: settings).profile
            #expect(filled.isMissing == false)
            #expect(filled.detail.contains("team lead"))
        }
    }

    @Test("Ключ не задан — видно до звонка, а не по первой ошибке")
    func aMissingKeyIsAGap() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(presetID: "anthropic")
            let without = readiness(of: settings).provider
            #expect(without.isMissing)
            #expect(without.detail.lowercased().contains("ключ"))

            settings.setProviderKey("sk-ant-test")
            let with = readiness(of: settings).provider
            #expect(with.isMissing == false)
            #expect(with.detail.lowercased().contains("ключ") == false)
        }
    }

    @Test("Локальному провайдеру ключ не нужен — и пробелом это не считается")
    func aKeylessProviderIsNotAGap() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(presetID: "ollama")
            let item = readiness(of: settings).provider
            #expect(item.isMissing == false)
            #expect(settings.hasProviderKey == false)
        }
    }

    @Test("Неверный адрес — пробел, и причина названа")
    func abrokenSelectionIsAGapWithItsReason() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(
                presetID: "ollama",
                baseURL: "не адрес вовсе"
            )
            let item = readiness(of: settings).provider
            #expect(item.isMissing)
            #expect(settings.providerConfigurationError != nil)
        }
    }
}

// MARK: - Куда ведёт клик

@MainActor
@Suite("Клик из строки открывает тот раздел настроек, о котором она говорит")
struct PrecallStripTargetsTests {

    @Test("Каждое поле ведёт в свой раздел")
    func everyFieldPointsAtItsOwnSection() {
        withScratchSettings { settings in
            settings.themSourceApplicationID = "com.google.Chrome"
            let strip = readiness(of: settings)
            #expect(strip.profile.target == .profile)
            #expect(strip.source.target == .sourceApplication)
        }
    }

    @Test("Ключа нет — ведёт к ключу, а не к списку провайдеров")
    func aMissingKeySendsTheUserToTheKey() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(presetID: "anthropic")
            // Подсказка обещает «вписать ключ»; раздел провайдера ключа не
            // содержит, и клик, остановившийся на нём, сделал бы обещание ложным.
            #expect(readiness(of: settings).provider.target == .providerKey)

            settings.setProviderKey("sk-ant-test")
            #expect(readiness(of: settings).provider.target == .provider)
        }
    }

    @Test("Неверная конфигурация ведёт к провайдеру: чинить надо адрес, а не ключ")
    func abrokenConfigurationSendsTheUserToTheProvider() {
        withScratchSettings { settings in
            settings.providerSelection = ProviderSelection(presetID: "ollama", baseURL: "не адрес вовсе")
            #expect(readiness(of: settings).provider.target == .provider)
        }
    }

    @Test("Тот же раздел, запрошенный дважды, — это два запроса, а не один")
    func askingTwiceForTheSameSectionScrollsTwice() {
        let navigation = SettingsNavigation()
        #expect(navigation.request == nil)

        navigation.reveal(.providerKey)
        let first = navigation.request
        #expect(first?.section == .providerKey)

        navigation.reveal(.providerKey)
        // Пользователь отлистал форму и нажал снова — экран обязан вернуть его
        // на место. Без счётчика второй запрос неотличим от первого.
        #expect(navigation.request?.section == .providerKey)
        #expect(navigation.request != first)
    }

    /// Строка готовности предлагает поправить факт нажатием, и предложение
    /// обязано вести туда, где это можно сделать. С тех пор как окно настроек
    /// разложено по вкладкам, «туда» — это вкладка: секция без вкладки была бы
    /// контролом, который строка предлагает, а окно показать не может.
    @Test("У каждой секции настроек есть своя вкладка")
    func everySectionHasATab() {
        for section in SettingsSection.allCases {
            // Отношение тотальное по устройству типа; тест ловит не nil, а
            // забытую секцию: новая, дописанная в enum, обязана получить место.
            #expect(SettingsTab.allCases.contains(section.tab), "\(section) некуда открыть")
        }
    }

    /// Обратная сторона того же: вкладка, на которую ничто не ведёт, — это
    /// страница, до которой пользователь доберётся только случайно.
    @Test("На каждой вкладке есть хотя бы одна секция")
    func everyTabHoldsASection() {
        for tab in SettingsTab.allCases {
            #expect(
                SettingsSection.allCases.contains { $0.tab == tab },
                "вкладка \(tab) пуста"
            )
        }
    }

    @Test("Секции, которые трогают вместе, лежат вместе")
    func sectionsReachedTogetherShareAPage() {
        // Пороги нарезки трогают тогда же, когда бэкенд захвата, — по одной и
        // той же жалобе «собеседника не слышно».
        #expect(SettingsSection.segmentation.tab == SettingsSection.captureBackend.tab)
        #expect(SettingsSection.sourceApplication.tab == SettingsSection.captureBackend.tab)
        // Ключ — это про провайдера, а не про безопасность вообще.
        #expect(SettingsSection.providerKey.tab == SettingsSection.provider.tab)
        // «Кто я» и «куда иду» — один вопрос, заданный дважды.
        #expect(SettingsSection.interviewContext.tab == SettingsSection.profile.tab)
    }
}

// MARK: - Переключение профиля

@MainActor
@Suite("Переключение профиля доезжает до промпта")
struct ProfileSwitchReachesThePromptTests {

    /// The composer the session actually runs, built the way the composition
    /// root builds it: reading `SettingsStore.profile` at request time.
    private func composer(_ settings: SettingsStore) -> PromptComposer {
        PromptComposer(profile: { settings.profile })
    }

    private var transcript: [Turn] {
        [Turn(channel: .them, text: "Расскажите про свой опыт.", timestamp: 0, duration: 1.2)]
    }

    @Test("Сменили профиль — сменился и опыт, который уходит в system-промпт")
    func switchingTheProfileSwitchesWhatTheModelIsTold() {
        withScratchSettings { settings in
            settings.profile = UserProfile(
                id: settings.selectedProfileID,
                name: "Тимлид",
                role: "team lead",
                experience: "9 лет, из них 4 — управление",
                // Слова взяты редкие намеренно: «Kubernetes» и «PostgreSQL»
                // встречаются в самих правилах промпта — там, где он учит
                // произносить термины вслух, — и тест на них проверял бы не
                // профиль, а формулировку правил.
                stack: "Go, Kafka"
            )
            let fullstack = settings.addProfile(named: "Синьор фулстек")
            settings.updateProfile(
                UserProfile(
                    id: fullstack,
                    name: "Синьор фулстек",
                    role: "fullstack-разработчик",
                    experience: "7 лет продуктовой разработки",
                    stack: "TypeScript, Postgres"
                )
            )

            settings.selectProfile(fullstack)
            let asFullstack = composer(settings).compose(
                .brief,
                transcript: transcript,
                screen: .none,
                accepting: .multimodal
            )
            #expect(asFullstack.systemPrompt.contains("fullstack-разработчик"))
            #expect(asFullstack.systemPrompt.contains("TypeScript, Postgres"))
            #expect(!asFullstack.systemPrompt.contains("Kafka"), "опыт другого профиля в промпт попасть не может")

            settings.selectProfile(settings.profiles[0].id)
            let asLead = composer(settings).compose(
                .brief,
                transcript: transcript,
                screen: .none,
                accepting: .multimodal
            )
            #expect(asLead.systemPrompt.contains("team lead"))
            #expect(asLead.systemPrompt.contains("Kafka"))
            #expect(!asLead.systemPrompt.contains("TypeScript"))
        }
    }

    @Test("Строка и промпт говорят об одном профиле")
    func theStripAndThePromptAgree() {
        withScratchSettings { settings in
            settings.profile = UserProfile(
                id: settings.selectedProfileID,
                name: "Тимлид",
                role: "team lead",
                stack: "Go"
            )
            let second = settings.addProfile(named: "Синьор фулстек")
            settings.updateProfile(
                UserProfile(id: second, name: "Синьор фулстек", role: "fullstack", stack: "TypeScript")
            )
            settings.selectProfile(second)

            let shown = readiness(of: settings).profile.value
            let sent = composer(settings).compose(
                .brief,
                transcript: transcript,
                screen: .none,
                accepting: .multimodal
            ).systemPrompt

            #expect(shown == "Синьор фулстек")
            #expect(sent.contains("fullstack"), "строка показывает один профиль, а в промпт уходит другой")
            #expect(!sent.contains("Синьор фулстек"), "имя профиля — ярлык для списка, в промпт оно не идёт")
        }
    }

    @Test("Профиль переживает очистку контекста — он про пользователя, а не про звонок")
    func theProfileOutlivesTheConversation() {
        withScratchSettings { settings in
            settings.profile = UserProfile(
                id: settings.selectedProfileID,
                name: "Тимлид",
                role: "team lead",
                stack: "Go"
            )
            let controller = SessionController(
                engine: SessionEngine(),
                requestMicrophoneAccess: { false }
            )
            controller.clearContext()

            #expect(readiness(of: settings).profile.value == "Тимлид")
            #expect(
                composer(settings)
                    .compose(.brief, transcript: [], screen: .none, accepting: .multimodal)
                    .systemPrompt
                    .contains("team lead")
            )
        }
    }
}

// MARK: - Инварианты окна

@MainActor
@Suite("Строка готовности не трогает инварианты окна")
struct OverlayKeepsItsPromisesTests {

    @Test("Панель осталась неактивирующей: клик по переключателю профиля не уводит фокус из звонка")
    func theOverlayStaysNonActivating() {
        let configuration = OverlayWindowConfiguration.overlay
        #expect(configuration.styleMask.contains(.nonactivatingPanel))
        #expect(configuration.sharingType == .none)
        #expect(configuration.level.rawValue > NSWindow.Level.normal.rawValue, "оверлей обязан быть поверх остальных")

        let panel = OverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: configuration.styleMask,
            backing: .buffered,
            defer: true
        )
        configuration.apply(to: panel)

        // Меню профиля клавиатуры не просит, а панель отдаёт её только полю,
        // которое об этом попросило, — этим и держится фокус в окне звонка.
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(panel.canBecomeMain == false)
        #expect(panel.sharingType == .none, "строка готовности называет профиль вслух — в шаринг это попасть не может")
    }

    @Test("Показ окна со строкой не делает GhostMeet активным приложением")
    func showingTheOverlayDoesNotActivateTheApp() {
        let name = "GhostMeetPrecallStripWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        let session = SessionController(engine: SessionEngine(), requestMicrophoneAccess: { false })
        let overlay = OverlayWindowController(
            session: session,
            recognition: SpeechModelStatus(store: settings, provider: FakeSpeechModelProvider()),
            hotkeys: HotkeyCenter(store: settings, registry: InertHotkeyRegistry()),
            openSettings: { _ in },
            settings: settings,
            stateStore: WindowStateStore(defaults: defaults)
        )

        let wasActive = NSApp.isActive
        overlay.show()

        #expect(overlay.isVisible)
        if !wasActive {
            #expect(NSApp.isActive == false, "оверлей не имеет права активировать приложение — на той стороне это видно")
        }

        overlay.hide()
    }
}
