//
//  SettingsView.swift
//  GhostMeet
//

import SwiftUI

/// Settings screen: profile, provider key, turn-segmentation thresholds.
///
/// Every control writes straight through to the observable `SettingsStore`, so
/// a change takes effect at once — there is no Apply button and no restart.
struct SettingsView: View {

    @Bindable var store: SettingsStore

    /// Model selection and download progress. Kept apart from `store` because
    /// only the choice is a setting; how far the download has got is live state
    /// of the recogniser.
    ///
    /// Passed in rather than defaulted: it has to be the status built over the
    /// same store this screen edits, and a default would hide a mismatch.
    let recognition: SpeechModelStatus

    /// Which section the screen has been asked to show — see `SettingsNavigation`.
    ///
    /// Also passed in rather than defaulted, and for the same kind of reason: a
    /// default here would be an object nobody else holds, so every request would
    /// be made to one instance and read from another, and the form would sit
    /// where it was without a word.
    let navigation: SettingsNavigation

    /// Asks the feed now, because somebody pressed the button below.
    ///
    /// A closure and not the updater itself: this screen has no business showing
    /// the answer. Updating says what it has to say on one line of the overlay
    /// and nowhere else — the overlay floats above this window, so the result is
    /// visible the moment it arrives, and there is exactly one place to look for
    /// it (ADR-0012). Defaulted to nothing so the preview and the screen tests
    /// need no updater.
    var checkForUpdates: () -> Void = {}

    /// Holds the key only while the user is typing it. Cleared as soon as it
    /// reaches the keychain so the secret does not linger in view state.
    @State private var providerKeyDraft: String = ""

    /// Which applications the selected backend can capture right now. Owned by
    /// the screen rather than passed in: it is a live reading of the system, not
    /// a setting, and what capture actually shares with it is only the stored id.
    @State private var catalog = SourceApplicationCatalog()

    /// The last request already scrolled to. Without it, every redraw of the
    /// form would drag the user back to the section they arrived at.
    @State private var revealed: Int = 0

    var body: some View {
        // Each section is tagged with its own anchor so that a press on the
        // readiness strip lands on the control it named rather than at the top
        // of a form eight sections long. `Form` on macOS lays every section out
        // — none of this is lazy — so all eight anchors exist to be scrolled to.
        ScrollViewReader { proxy in
            Form {
                profileSection.id(SettingsSection.profile)
                interviewContextSection.id(SettingsSection.interviewContext)
                captureBackendSection.id(SettingsSection.captureBackend)
                sourceApplicationSection.id(SettingsSection.sourceApplication)
                recognitionSection.id(SettingsSection.recognition)
                providerSection.id(SettingsSection.provider)
                providerKeySection.id(SettingsSection.providerKey)
                segmentationSection.id(SettingsSection.segmentation)
                updatesSection.id(SettingsSection.updates)
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 620)
            .onAppear {
                catalog.backend = store.themCaptureBackend
                catalog.startTracking()
                // The window is built the moment it is first asked for, so the
                // very first request arrives before this view exists and no
                // change ever fires for it.
                reveal(with: proxy)
            }
            .onChange(of: navigation.request) { reveal(with: proxy) }
            // The two lists are not the same list, so the picker below has to be
            // rebuilt for the backend the user just chose — otherwise it keeps
            // offering applications this backend cannot see, and the channel goes
            // silent with nothing on screen to explain it.
            .onChange(of: store.themCaptureBackend) { catalog.backend = store.themCaptureBackend }
        }
    }

    /// Scrolls to the section asked for, once per request.
    ///
    /// A hop through the main queue on purpose: at `onAppear` the form has not
    /// been laid out yet, and scrolling to an anchor that has no place yet does
    /// nothing at all.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let request = navigation.request, request.token != revealed else { return }
        revealed = request.token
        Task { @MainActor in
            withAnimation { proxy.scrollTo(request.section, anchor: .top) }
        }
    }

    // MARK: - Capture backend

    /// How the `Them` channel is captured — the choice that decides how well it
    /// is recognised.
    ///
    /// Both options are described by what they do and what they cost, in
    /// measurements rather than in adjectives: neither is better everywhere, the
    /// difference is a permission on one side and signal level on the other, and
    /// the user is the only one who knows what this machine allows.
    private var captureBackendSection: some View {
        Section("Захват канала Them") {
            Picker("Бэкенд", selection: $store.themCaptureBackend) {
                ForEach(ThemCaptureBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }

            ForEach(ThemCaptureBackend.allCases, id: \.self) { backend in
                Label(backend.summary, systemImage: iconName(for: backend))
                    .font(.footnote)
                    .foregroundStyle(backend == store.themCaptureBackend ? .primary : .secondary)
            }

            screenRecordingNotice

            Text("Смена бэкенда применяется сразу — перезапуск не нужен. Список приложений ниже перестраивается вместе с ней: ScreenCaptureKit видит только приложения с окнами, тап — любой процесс со звуком.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func iconName(for backend: ThemCaptureBackend) -> String {
        switch backend {
        case .screenCaptureKit: "rectangle.on.rectangle"
        case .processTap: "waveform"
        }
    }

    /// Why the picker below is empty, when it is.
    ///
    /// ScreenCaptureKit is the default backend, so a machine that has never
    /// granted Screen Recording runs into exactly this on the very first launch:
    /// capture starts, nothing arrives, and without this line there is nothing
    /// anywhere saying what to do. It is shown here and inside the overlay
    /// window, and never as a system notification — a banner would be drawn on
    /// top of the screen the user is sharing (ADR-0004).
    @ViewBuilder
    private var screenRecordingNotice: some View {
        if let reason = catalog.unavailableReason {
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Profile

    /// Profiles, their contents and the resume import — a section of its own
    /// because it is now four controls and a sheet rather than three fields.
    private var profileSection: some View {
        ProfileSectionView(store: store)
    }

    // MARK: - Interview context

    /// What the user prepared for *this* interview — directly under the profile,
    /// because that is the thing it has to be told apart from.
    private var interviewContextSection: some View {
        InterviewContextSectionView(store: store)
    }

    // MARK: - Source application

    /// Which application's sound becomes the `Them` channel.
    ///
    /// The list is applications, never windows or tabs, because that is the
    /// finest granularity any capture API on macOS offers. The footnotes say so
    /// outright: promising a single tab here would be a promise the tap cannot
    /// keep.
    ///
    /// The list itself belongs to the selected backend and is rebuilt with it.
    /// Core Audio knows every process that opened an output device;
    /// ScreenCaptureKit knows every application that owns a window. Neither list
    /// contains the other, and showing the wrong one would let the user pick
    /// something the running backend cannot see.
    private var sourceApplicationSection: some View {
        Section("Приложение-источник") {
            Picker("Слушать", selection: sourceSelection) {
                Text("Не выбрано").tag(String?.none)
                ForEach(catalog.applications) { application in
                    Text(application.isPlayingAudio ? "\(application.name) · звучит" : application.name)
                        .tag(String?.some(application.id))
                }
                // A source picked earlier keeps its place in the list even while
                // its application is closed — otherwise reopening the settings
                // before the browser is up would silently drop the choice.
                if let missing = missingSelection {
                    Text("\(missing) · \(missingSelectionNote)").tag(String?.some(missing))
                }
            }

            HStack {
                Text(selectionSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Обновить список") { catalog.refresh() }
            }

            Text(listSourceNote)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Звук берётся с приложения целиком: отделить вкладку со звонком от остальных вкладок браузера нельзя, поэтому всё, что играет в том же приложении, попадёт в канал Them.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Выбирайте сам браузер, а не вспомогательный процесс: звук звонка отдаёт один из его помощников, и после перезапуска браузера это уже другой процесс. GhostMeet слушает все процессы приложения сразу и находит их заново.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Если реплики собеседника не появляются, проверьте «Системные настройки» → «Конфиденциальность и безопасность» → «Запись экрана и звука системы»: без этого разрешения захват идёт, но приходит тишина.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Where the list above comes from — the one sentence that keeps «моего
    /// приложения здесь нет» from looking like a bug.
    private var listSourceNote: String {
        switch store.themCaptureBackend {
        case .screenCaptureKit:
            "Список показывает то, что видит ScreenCaptureKit: приложения с окнами. Процесса без окна — плеера из терминала, например — здесь не будет; для него переключитесь на Core Audio Process Tap."
        case .processTap:
            "Список показывает то, что видит Core Audio: любой процесс, открывший звуковое устройство, даже без окна."
        }
    }

    /// Why the stored choice is not among the entries offered right now. Under
    /// ScreenCaptureKit that is one reason more than «не запущено».
    private var missingSelectionNote: String {
        store.themCaptureBackend == .screenCaptureKit
            ? "нет в списке ScreenCaptureKit"
            : "не запущено"
    }

    private var sourceSelection: Binding<String?> {
        Binding(
            get: { store.themSourceApplicationID },
            set: { store.themSourceApplicationID = $0 }
        )
    }

    /// The stored choice when its application is not in the list right now.
    private var missingSelection: String? {
        guard let id = store.themSourceApplicationID,
              catalog.application(withID: id) == nil else { return nil }
        return id
    }

    private var selectionSummary: String {
        // A missing permission outranks everything else this line could say: the
        // list is empty for a reason that has nothing to do with the choice.
        if catalog.unavailableReason != nil {
            return "Список пуст — см. предупреждение выше."
        }
        guard let id = store.themSourceApplicationID else {
            return "Канал Them молчит, пока источник не выбран."
        }
        guard let application = catalog.application(withID: id) else {
            return store.themCaptureBackend == .screenCaptureKit
                ? "ScreenCaptureKit сейчас не показывает это приложение — захват включится сам, когда оно откроет окно."
                : "Приложение не запущено — захват включится сам, когда оно вернётся."
        }
        return application.isPlayingAudio
            ? "Приложение сейчас выдаёт звук."
            : "Приложение запущено, но пока молчит."
    }

    // MARK: - Recognition

    /// Model choice plus an honest account of what is happening with it.
    ///
    /// The download is minutes long on first use, so it gets a determinate
    /// progress bar and its own button: the user can pull the model before the
    /// call instead of discovering it mid-interview. Nothing here blocks —
    /// downloading happens in the recogniser, and the form stays usable.
    private var recognitionSection: some View {
        Section("Распознавание речи") {
            Picker("Модель", selection: modelSelection) {
                ForEach(WhisperModel.allCases) { model in
                    Text("\(model.title) · \(model.approximateDownloadSize)").tag(model)
                }
            }

            Text(recognition.model.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)

            modelPhaseRow

            Text("Все модели в списке многоязычные: русский и английский распознаются без переключения настроек — язык определяется по каждой реплике.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSelection: Binding<WhisperModel> {
        Binding(
            get: { recognition.model },
            set: { recognition.model = $0 }
        )
    }

    @ViewBuilder
    private var modelPhaseRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                phaseLabel
                Spacer()
                Button(recognition.phase.isBusy ? "Загружается…" : "Загрузить модель") {
                    recognition.prepare()
                }
                .disabled(recognition.phase.isBusy || recognition.phase.isReady)
            }

            if case .downloading(let fraction) = recognition.phase {
                ProgressView(value: fraction)
            }
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch recognition.phase {
        case .ready:
            Label(recognition.phase.summary, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed:
            // Surfaced here, inside the app window, and nowhere else: a system
            // banner would show up on top of a shared screen (ADR-0004).
            Label(recognition.phase.summary, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .idle, .downloading, .loading:
            Label(recognition.phase.summary, systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Provider

    /// Which model answers, and everything about it the user may need to change.
    ///
    /// The presets are a convenience, not a fence: base URL, model and — for a
    /// CLI tool — the command stay editable, so a provider nobody put on the
    /// list is reached by pointing an OpenAI-compatible preset at it. An empty
    /// field means "as in the preset", which is why each one shows the preset's
    /// own value as its placeholder rather than pre-filling it.
    private var providerSection: some View {
        Section("Провайдер") {
            Picker("Провайдер", selection: $store.providerSelection.presetID) {
                ForEach(ProviderFactory.presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }

            if store.providerPreset.transport == .cli {
                LabeledContent("Команда") {
                    TextField(
                        store.providerPreset.command.joined(separator: " "),
                        text: $store.providerSelection.commandOverride
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Text("Приложение, запущенное из Finder, видит короткий системный PATH и может не найти инструмент. Если ответов нет — впишите полный путь, например «/opt/homebrew/bin/claude -p».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Базовый адрес") {
                    TextField(
                        store.providerPreset.defaultBaseURL,
                        text: $store.providerSelection.baseURL
                    )
                    .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Модель") {
                    TextField(
                        store.providerPreset.defaultModel,
                        text: $store.providerSelection.model
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Text("Пустое поле означает «как в предустановке». Свой адрес и своя модель — это способ подключить провайдера, которого нет в списке.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            capabilityNotice

            if let error = store.providerConfigurationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("Смена провайдера применяется сразу: следующая подсказка уйдёт уже новому — перезапуск не нужен.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// What the chosen provider can actually accept.
    ///
    /// Shown as a warning and not as a footnote when images are out: `Solve on
    /// screen` is the primary mode of this scenario, and a user who picked a
    /// text-only model has to learn it here rather than from a weaker answer
    /// during the interview.
    @ViewBuilder
    private var capabilityNotice: some View {
        if store.providerAcceptsImages {
            Label(store.providerCapabilityNote, systemImage: "photo")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Label(store.providerCapabilityNote, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Provider key

    /// The key of the selected provider — and only of it.
    ///
    /// Absent altogether where the preset does not need one: a local server and
    /// a CLI tool authenticate nobody, and an empty field there would read as
    /// something the user forgot to fill in.
    @ViewBuilder
    private var providerKeySection: some View {
        Section("Ключ · \(store.providerPreset.name)") {
            if store.providerRequiresKey {
                SecureField("API-ключ", text: $providerKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveProviderKey)

                HStack {
                    Button("Сохранить", action: saveProviderKey)
                        .disabled(providerKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Удалить", role: .destructive) {
                        providerKeyDraft = ""
                        store.removeProviderKey()
                    }
                    .disabled(!store.hasProviderKey)
                    Spacer()
                    Text(store.hasProviderKey ? "Ключ сохранён в Keychain" : "Ключ не задан")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let error = store.lastSecretError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("Ключ хранится только в системном Keychain — не в настройках приложения, не в файлах и не в логах. У каждого провайдера свой ключ: переключение на другого не стирает предыдущий.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label(keylessNote, systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        // A key half-typed for one provider must never be saved to another.
        .onChange(of: store.providerSelection.presetID) { providerKeyDraft = "" }
    }

    private var keylessNote: String {
        store.providerPreset.transport == .cli
            ? "Ключ не нужен: инструмент отвечает по той подписке, под которой он уже залогинен."
            : "Ключ не нужен: локальный сервер работает без авторизации."
    }

    private func saveProviderKey() {
        guard store.setProviderKey(providerKeyDraft) else { return }
        providerKeyDraft = ""
    }

    // MARK: - Turn segmentation

    private var segmentationSection: some View {
        Section("Нарезка реплик") {
            threshold(
                title: "Порог паузы",
                value: $store.turnSegmentation.pauseThreshold,
                range: TurnSegmentationConfig.pauseThresholdRange,
                step: 0.05,
                format: { "\(Int(($0 * 1000).rounded())) мс" },
                hint: "Тишина такой длины закрывает реплику. На скорость подсказки не влияет: запрос уходит по нажатию, а нажатие дозакрывает реплику само."
            )
            threshold(
                title: "Минимальная длина реплики",
                value: $store.turnSegmentation.minimumTurnDuration,
                range: TurnSegmentationConfig.minimumTurnDurationRange,
                step: 0.05,
                format: { String(format: "%.2f с", $0) },
                hint: "Более короткие отрезки не попадают в распознавание."
            )
            threshold(
                title: "Страховочный флаш",
                value: $store.turnSegmentation.safetyFlushInterval,
                range: TurnSegmentationConfig.safetyFlushIntervalRange,
                step: 1,
                format: { String(format: "%.0f с", $0) },
                hint: "Монолог без пауз всё равно попадёт в транскрипт по этому таймеру."
            )
            threshold(
                title: "Порог RMS-гейта",
                value: Binding(
                    get: { TimeInterval(store.turnSegmentation.silenceGateRMS) },
                    set: { store.turnSegmentation.silenceGateRMS = Float($0) }
                ),
                range: Self.rmsGateRange,
                step: 0.001,
                format: { String(format: "%.3f", $0) },
                hint: "Звук тише этого уровня считается тишиной."
            )

            Button("Вернуть значения по умолчанию") {
                store.resetTurnSegmentationToDefaults()
            }
        }
    }

    // MARK: - Обновления

    /// The one switch that decides whether the app talks to anything but the
    /// provider the user chose.
    ///
    /// It says what leaves the machine rather than promising that nothing does.
    /// The app is delivered as a disk image, so this is the only way a machine
    /// ever learns it is out of date — the check is on by default, and a default
    /// that reaches out deserves to be stated in plain words next to the switch
    /// that turns it off, not buried in a privacy section nobody opens.
    ///
    /// **The wording changed with the mechanism** (ADR-0012). It used to promise
    /// a check, and a check was all it did: the app looked, said a version
    /// existed, and left the rest — image, «Программы», `xattr` in a terminal —
    /// to the user. Now the same switch also permits the install, and a switch
    /// whose label understates what it allows is worse than no label.
    private var updatesSection: some View {
        Section("Обновления") {
            Toggle("Проверять и ставить обновления", isOn: $store.checksForUpdates)
            Text("""
                Один запрос при старте — за номером последней версии. \
                Уходит IP и версия приложения; разговор, профиль и заготовки не уходят никуда. \
                Выключенный переключатель не делает запроса вовсе.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("""
                Найденная версия предлагается строкой в окне и ставится только по нажатию — \
                во время звонка не ставится никогда. Подпись обновления проверяется до установки.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Установлена версия \(installedVersion)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // Без этой кнопки только что включённый переключатель не значит
            // ничего до следующего запуска, а выглядит так, будто значит.
            Button("Проверить сейчас", action: checkForUpdates)
                .disabled(!store.checksForUpdates)
            Text("Ответ появится строкой в окне GhostMeet — оно поверх этого.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// What this build calls itself. Shown because the notice in the overlay
    /// names the *new* version, and «новее чего» is a fair question to be able
    /// to answer without opening the bundle.
    private var installedVersion: String {
        AppVersion.running().map(String.init(describing:)) ?? "неизвестна"
    }

    /// The RMS gate is a `Float` in the model but a `TimeInterval` in the
    /// shared slider helper, so its range is bridged once here.
    private static let rmsGateRange: ClosedRange<TimeInterval> = {
        let bounds = TurnSegmentationConfig.silenceGateRMSRange
        return TimeInterval(bounds.lowerBound)...TimeInterval(bounds.upperBound)
    }()

    private func threshold(
        title: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<TimeInterval>,
        step: TimeInterval,
        format: @escaping (TimeInterval) -> String,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Text(format(range.lowerBound))
            } maximumValueLabel: {
                Text(format(range.upperBound))
            }
            HStack {
                Text(hint)
                Spacer()
                Text(format(value.wrappedValue))
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    // Nothing is downloaded here: preparation only starts when the button is
    // pressed or when a call produces its first turn.
    let store = SettingsStore(
        defaults: UserDefaults(suiteName: "GhostMeetSettingsPreview") ?? .standard,
        secrets: InMemorySecretStore()
    )
    return SettingsView(
        store: store,
        recognition: SpeechModelStatus(store: store),
        navigation: SettingsNavigation()
    )
}
