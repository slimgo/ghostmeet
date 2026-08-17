//
//  ContentView.swift
//  GhostMeet
//

import AppKit
import SwiftUI

/// Content of the overlay panel: the live transcript, the controls the user has
/// to be able to reach mid-call (listen, settings, opacity), and an honest note
/// about what the invisibility promise covers.
///
/// Everything this view can go wrong about — a denied microphone, a capture that
/// would not start — is shown here and only here. A system notification would be
/// drawn over the shared screen and give the app away (ADR-0004).
struct ContentView: View {

    @ObservedObject var controller: OverlayWindowController

    /// The session: where the turns come from and what the listen button drives.
    let session: SessionController

    /// How far the recognition model has got. Read here — and not only in
    /// settings — because it decides whether the listen button works at all, and
    /// a disabled button with no visible reason reads as a broken app.
    let recognition: SpeechModelStatus

    /// What the user is armed with: the `Активный профиль`, the provider, the
    /// `Приложение-источник`. Read live rather than copied, so switching a
    /// profile here is in force for the next suggestion.
    ///
    /// Optional because the window can be built without a user's settings —
    /// the window-plumbing tests do exactly that — and a readiness strip with
    /// nothing true to say is better absent than filled with placeholders.
    let settings: SettingsStore?

    /// Whether a newer build has been published, and how far installing it has
    /// got. Optional for the same reason as the store above: the window-plumbing
    /// tests build this view without one.
    var updates: AppUpdater?

    /// The global chords and their bindings. Shown here so that the one thing a
    /// user needs after pressing the panic key — the chord that brings the window
    /// back — is written down in the window itself.
    let hotkeys: HotkeyCenter

    /// Opens the settings window, at a named section when the caller has one in
    /// mind. In accessory mode there is no menu bar, so this button is the only
    /// way in.
    let openSettings: OpenSettings

    /// Why the last save did not happen, or `nil`. Local to the view on purpose:
    /// it is about an action the user just took, not about the state of the
    /// session, and the session has no business remembering it.
    @State private var saveFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            captureVisibilityNotice
            updateNotice
            recognitionNotice
            failureNotice
            routeNotice
            themNotice
            preparationNotice
            suggestions
            Divider().opacity(0.4)
            askBar
            Divider().opacity(0.4)
            transcript
            saveRow
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: controller.cornerRadius, style: .continuous))
        // Содержимое занимает окно целиком, включая полосу заголовка.
        //
        // `.fullSizeContentView` растягивает туда contentView, но SwiftUI сам
        // отступает от заголовка — и карточка начиналась НИЖЕ красной кнопки,
        // из-за чего та выглядела висящей над окном отдельной полоской.
        //
        // Именно так, а не `NSHostingView.safeAreaRegions = []`: тот путь роняет
        // приложение на старте. AppKit бросает исключение прямо в цикле
        // отрисовки, и под тестами это выглядит особенно подло — host-приложение
        // умирает раньше первого теста, а прогон рапортует «0 tests passed».
        .ignoresSafeArea()
    }

    // MARK: - Header

    /// Two rows that answer two different questions, in the order they are
    /// asked: «чем я вооружён» before the call, «что происходит сейчас» during
    /// it — and the controls that switch between the two states.
    ///
    /// They share one header rather than sitting apart because they are read in
    /// one glance and because the window has no room for a second block of
    /// chrome. The strip costs about eighteen points; everything below it is
    /// untouched, and the suggestion feed — which takes whatever is left — pays
    /// for those eighteen.
    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ChannelIndicatorsView(indicators: indicators)

                Spacer(minLength: 12)

                visibilityButton
                listenButton
                settingsButton
            }

            precallStrip
        }
        // Слева отступ больше: там живёт красная кнопка закрытия, и индикаторы
        // каналов не должны стоять под ней. Кнопка одна, а не три — свернуть и
        // развернуть у оверлея скрыты, — поэтому 44, а не привычные для полного
        // светофора семьдесят.
        .padding(.leading, 44)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        // Кнопка гаснет и зажигается вслед за прослушиванием. Правило живёт в
        // `SessionController.canQuit`, окно только показывает его.
        .onChange(of: session.canQuit) { _, canQuit in controller.setCloseEnabled(canQuit) }
        .onAppear { controller.setCloseEnabled(session.canQuit) }
    }

    /// The readiness strip — see `PrecallStripView` for why it is one line and
    /// how it stays out of the indicators' way.
    @ViewBuilder
    private var precallStrip: some View {
        if let settings {
            PrecallStripView(settings: settings, openSettings: openSettings)
        }
    }

    // MARK: - Окно видно при захвате

    /// Says out loud that the app's own promise is switched off right now.
    ///
    /// **Stays up during the call, and that is the whole point.** The dangerous
    /// sequence is not «включил и забыл» in the abstract — it is: turned the
    /// window visible last night to record a demo, opened the app this morning,
    /// pressed «Слушать». The switch is locked by then and cannot be fixed, so
    /// the only thing left is to state it where it cannot be missed. The
    /// certain-leak branch of `routeNotice` earns its permanent line the same way.
    ///
    /// It is not shown in the safe state at all: an overlay that reassures you
    /// every second about the thing that is working is an overlay you stop
    /// reading.
    @ViewBuilder
    private var captureVisibilityNotice: some View {
        if !controller.isHiddenFromCapture {
            Label {
                Text(session.isListening
                     ? "Окно ВИДНО при шаринге и записи экрана. Прослушивание идёт — переключить уже нельзя."
                     : "Окно видно при шаринге и записи экрана, и попадает в собственные скриншоты приложения.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye")
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.18))
        }
    }

    // MARK: - A newer build

    /// One line saying a newer GhostMeet exists — see `UpdateNoticeView` for why
    /// it is a line of its own rather than a fourth field in the strip above.
    ///
    /// **Hidden while listening.** The app is delivered as a disk image, so this
    /// is the only way a machine ever learns it is out of date; it is also the
    /// least urgent thing on this window, and the call is what the window is
    /// for. Before the call it is read, during the call it would be one line of
    /// the suggestion feed spent on news.
    ///
    /// Hiding it is safe in a way it would not be if the line ever drove itself:
    /// nothing about updating happens without a press, so a line taken off screen
    /// mid-call cannot leave something running unseen.
    @ViewBuilder
    private var updateNotice: some View {
        if let updates, updates.status.phase != .idle, !session.isListening {
            UpdateNoticeView(
                phase: updates.status.phase,
                install: { updates.status.install() },
                dismiss: { updates.status.dismiss() }
            )
        }
    }

    /// The state of both channels and of the model, recomputed from the session
    /// on every redraw. Nothing about it is stored: an indicator that can go
    /// stale is worse than no indicator.
    private var indicators: SessionIndicators {
        SessionIndicators.make(
            isListening: session.isListening,
            failure: session.failure,
            recognition: recognition.phase,
            themStatus: session.themStatus,
            isPreparingAnswer: session.isPreparingAnswer,
            isGenerating: session.isGenerating,
            suggestionFailure: session.lastSuggestionFailure
        )
    }

    private var isModelReady: Bool { recognition.phase.isReady }

    /// Whether pressing the button would do anything.
    ///
    /// Stopping is always allowed — only starting waits for the model.
    private var canPressListen: Bool {
        if session.isStarting { return false }
        return session.isListening || session.canStartListening
    }

    private var listenButton: some View {
        Button { session.toggle() } label: {
            Label(listenTitle, systemImage: session.isListening ? "stop.fill" : "mic.fill")
                .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .disabled(!canPressListen)
        .help(listenHelp)
    }

    private var listenTitle: String {
        if session.isStarting { return "Доступ…" }
        if session.isListening { return "Стоп" }
        // The word on a disabled button has to say why it is disabled — the
        // reason below the header explains it, but the button is what the eye
        // goes to first.
        return isModelReady ? "Слушать" : "Подготовка…"
    }

    private var listenHelp: String {
        if let reason = recognition.phase.listeningBlockedReason, !session.isListening {
            return reason
        }
        return "Начать и остановить прослушивание микрофона — канал You. Кнопка ничего не отправляет в звонок."
    }

    private var settingsButton: some View {
        // No section: the gear is a way into settings, not a way to a control.
        Button { openSettings(nil) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
        }
        .controlSize(.small)
        .help("Настройки: профиль, ключ провайдера, пороги нарезки реплик.")
    }

    // MARK: - Невидимость

    /// The one control that can defeat the product's main promise, which is why
    /// it is here and not in settings: it is flipped to record a demo and has to
    /// be flipped back, and a switch you have to go looking for is a switch you
    /// forget you left on.
    ///
    /// **Locked while listening.** Not «reset», not «forced» — locked. Whatever
    /// state the user chose before pressing «Слушать» is the state the call runs
    /// in, because changing it mid-call is either useless (already sharing) or a
    /// panic move that the panic hotkey does better. What starting a session
    /// takes away is the ability to change one's mind halfway.
    private var visibilityButton: some View {
        Button {
            controller.setHiddenFromCapture(!controller.isHiddenFromCapture)
        } label: {
            Image(systemName: controller.isHiddenFromCapture ? "eye.slash" : "eye")
                .font(.system(size: 12))
        }
        .controlSize(.small)
        .foregroundStyle(controller.isHiddenFromCapture ? Color.secondary : Color.orange)
        .disabled(session.isListening)
        .help(visibilityHelp)
        .accessibilityLabel(controller.isHiddenFromCapture
            ? "Окно скрыто от захвата экрана"
            : "Окно видно при захвате экрана")
    }

    /// Says what the button does *and* what it costs — the second part is the
    /// one that matters. Making the window visible also puts it back into the
    /// screenshots GhostMeet takes for itself, so the model starts seeing its own
    /// previous answer.
    private var visibilityHelp: String {
        if session.isListening {
            return controller.isHiddenFromCapture
                ? "Прослушивание идёт — переключатель заблокирован. Окно скрыто от захвата и останется скрытым до конца."
                : "Прослушивание идёт — переключатель заблокирован. Окно ВИДНО при захвате и останется видимым до конца."
        }
        return controller.isHiddenFromCapture
            ? "Окно скрыто от захвата экрана. Нажмите, чтобы сделать его видимым — для записи ролика или скриншота."
            : "Окно видно при захвате экрана: попадёт в шаринг и в собственные скриншоты приложения. Нажмите, чтобы снова скрыть."
    }

    // MARK: - Recognition readiness

    /// Where the recognition model has got to, stated in the overlay itself.
    ///
    /// Until this was here the window said nothing while the model loaded, the
    /// button was pressable, and the user started talking into a session that
    /// could not transcribe: the opening turn came back empty or half — measured
    /// once at 75 characters out of 144. In an interview that is the first
    /// question, gone.
    ///
    /// It disappears in exactly one case — model ready *and* the session already
    /// listening — because from then on the green dot and the «Стоп» button say
    /// the same thing, and the overlay has to stay small mid-call.
    ///
    /// This is the only place readiness is ever reported. GhostMeet posts no
    /// system notifications at all, not even the cheerful "ready now" kind: a
    /// banner is drawn on top of everything the user is sharing and hands the
    /// app over (ADR-0004). Good news is no exception to that rule.
    @ViewBuilder
    private var recognitionNotice: some View {
        if let reason = recognition.phase.listeningBlockedReason {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(reason)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: recognitionIcon)
                }
                .font(.system(size: 11))

                if case .downloading(let fraction) = recognition.phase {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else if case .loading = recognition.phase {
                    // Loading reports no progress, so an indeterminate bar is
                    // the honest shape: it says "working", not "almost there".
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(recognitionBackground)
        } else if !session.isListening {
            Label("Модель готова — можно слушать", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var recognitionIcon: String {
        if case .failed = recognition.phase { return "exclamationmark.triangle.fill" }
        return "arrow.down.circle"
    }

    private var recognitionBackground: Color {
        if case .failed = recognition.phase { return Color.orange.opacity(0.15) }
        return Color.yellow.opacity(0.12)
    }

    // MARK: - Failure notice

    /// The one place capture failures are ever reported.
    @ViewBuilder
    private var failureNotice: some View {
        if let failure = session.failure {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(failure.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 11))

                if failure.isPermissionDenied {
                    Button("Открыть настройки приватности") { openMicrophonePrivacySettings() }
                        .controlSize(.small)
                        .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.15))
        }
    }

    /// Sends the user to the microphone switch itself, rather than describing
    /// where it is and hoping.
    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Маршрут звука

    /// Which way the sound goes, said only when it is worth saying.
    ///
    /// This is the visible half of ADR-0009. With voice processing gone, the
    /// configuration «встроенный микрофон + динамики» writes the interviewer's
    /// voice into the `You` channel — 17.8 seconds of a 19-second question,
    /// measured — and the two cleaning layers below take out most of it but not
    /// all. Headphones fix it completely, and that is a sentence the user can act
    /// on in five seconds. Saying nothing would be the same silent corruption of
    /// the transcript the project has already been bitten by twice.
    ///
    /// **A line of its own, not a fourth field in the readiness strip.** That
    /// strip carries three fields across 420 points and truncates already; a
    /// fourth would push the profile off the line to state something that is
    /// usually not worth stating at all. This appears only when there is
    /// something to say and takes no room the rest of the time.
    ///
    /// The two uncertain-versus-certain cases are said differently on purpose. A
    /// certain leak stays up during the call, because headphones can be put on
    /// mid-call and because the transcript is being corrupted right now. An
    /// unclassifiable route — a Bluetooth headset, an aggregate, a virtual
    /// device: three of the four output devices on the bench — is stated **only
    /// before the call**. It is a question, not a diagnosis, and a question
    /// hanging over the suggestion feed for an hour would be the nagging kind of
    /// honesty that gets ignored.
    ///
    /// Suppressed while a capture failure is on screen: a warning about speakers
    /// above «нет доступа к микрофону» is noise on top of the thing that has to
    /// be read.
    @ViewBuilder
    private var routeNotice: some View {
        if session.failure == nil, let route = session.audioRoute, let notice = route.notice {
            if route.isCertainlyLeaky {
                Label {
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.12))
            } else if !session.isListening {
                Label {
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - The Them channel

    /// What the `Them` channel is doing, whenever that is not simply "слушаю".
    ///
    /// This is the one failure of the app the user cannot hear: the microphone
    /// works, the transcript fills with their own turns, and the other side is
    /// silent for a reason nobody stated. Until now the reason went to the
    /// unified log and nowhere else.
    ///
    /// Inside the window and nowhere else, like every other report here: a
    /// notification banner would be drawn over the shared screen (ADR-0004).
    /// «Нажатие принято» — said in words, right above the feed the answer will
    /// land in.
    ///
    /// Placed here and not in the header on purpose: after pressing, the user
    /// looks where the answer appears. The header dot changes colour too, but a
    /// 7×7 point dot and a tooltip are not something anyone catches out of the
    /// corner of an eye while looking at an interviewer — see
    /// `SessionIndicators.preparationNotice` for what that costs.
    @ViewBuilder
    private var preparationNotice: some View {
        if let notice = indicators.preparationNotice {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(notice)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var themNotice: some View {
        let them = indicators.them
        if them.state.deservesAnExplanation {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(them.detail)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: them.state == .failed
                        ? "exclamationmark.triangle.fill"
                        : "speaker.slash")
                }
                .font(.system(size: 11))

                if isThemBlockedByScreenRecording {
                    Button("Открыть настройки записи экрана") { openScreenRecordingPrivacySettings() }
                        .controlSize(.small)
                        .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                them.state == .failed ? Color.orange.opacity(0.15) : Color.yellow.opacity(0.12)
            )
        }
    }

    /// Whether the channel is silent because Screen Recording was never granted.
    ///
    /// Compared against the very constant the capture layer publishes, so this
    /// cannot drift into offering the button for an unrelated failure.
    private var isThemBlockedByScreenRecording: Bool {
        session.themStatus == .failed(reason: ThemCaptureBackend.screenRecordingHelp)
    }

    private func openScreenRecordingPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Suggestions

    /// The main content of the window: what the model is answering right now.
    ///
    /// It takes the space that is left over, because this is what the user reads
    /// mid-call; the transcript below is there to check that both channels are
    /// being heard.
    private var suggestions: some View {
        SuggestionFeedView(suggestions: session.suggestions)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Ask and Solve

    /// The manual way to the model: a question typed by the user, and the demand
    /// for the task on screen to be solved.
    ///
    /// Directly under the feed, because that is where its answer lands. It stays
    /// visible mid-call rather than hiding behind a disclosure: the whole point
    /// of the two modes is being reachable in one motion at the moment a chord
    /// has answered the wrong thing.
    private var askBar: some View {
        AskBarView(session: session)
    }

    // MARK: - Transcript

    /// The transcript keeps the lower strip of the window: enough to see the
    /// last turns of both channels without competing with the suggestion.
    private var transcript: some View {
        TranscriptView(turns: session.transcript)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 132, alignment: .topLeading)
    }

    // MARK: - Сохранение диалога

    /// Saving the call to a file, under the transcript it saves.
    ///
    /// **Under the dialogue and not in the header.** The header already carries
    /// the indicators, the visibility switch, «Слушать» and the gear; a fifth
    /// control there would squeeze the readiness strip. This one belongs next to
    /// what it acts on anyway.
    ///
    /// Available while listening as well as after it. Forbidding it mid-call
    /// would protect nothing — the file is a copy of what is already on screen —
    /// and would need explaining, which is worse than the button being there.
    @ViewBuilder
    private var saveRow: some View {
        HStack(spacing: 8) {
            Button {
                saveTranscript()
            } label: {
                Label("Сохранить диалог", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .disabled(session.transcript.isEmpty)
            .help(session.transcript.isEmpty
                  ? "Пока нечего сохранять: в разговоре ни одной реплики."
                  : "Сохранить весь разговор в файл: обе стороны, ответы модели, без реплик, признанных протечкой.")

            if let saveFailure {
                Text(saveFailure)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Builds the file and hands it to the save panel.
    ///
    /// The anchor is taken **here**, at the moment of saving, because that is the
    /// only place where both clocks can be read at once — see
    /// `TranscriptExport.Anchor` for why one of them is uptime and the other a
    /// date, and what happens to the ordering without the pair.
    private func saveTranscript() {
        let now = Date()
        let readiness = settings.map { PrecallReadiness.make(settings: $0) }

        let markdown = TranscriptExport.markdown(
            turns: session.transcript,
            suggestions: session.suggestions,
            metadata: TranscriptExport.Metadata(
                savedAt: now,
                profile: stated(readiness?.profile),
                provider: stated(readiness?.provider),
                source: stated(readiness?.source)
            ),
            anchor: TranscriptExport.Anchor(uptime: ProcessInfo.processInfo.systemUptime, date: now)
        )

        saveFailure = TranscriptSaving.save(
            markdown,
            suggestedName: TranscriptSaving.suggestedName(for: now)
        )
    }

    /// A readiness field worth writing down, or nil.
    ///
    /// A gap — no source picked, no key stored — reads in the strip as «не
    /// выбрано», and that is right on screen and wrong in a file: a caption with
    /// a placeholder under it looks like a fact about the call.
    private func stated(_ item: ReadinessItem?) -> String? {
        guard let item, !item.isMissing else { return nil }
        return item.value
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            opacityControl
            HotkeysSectionView(hotkeys: hotkeys)
            sharingScopeNote
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var opacityControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Slider(value: $controller.opacity, in: controller.opacityRange)
                .controlSize(.mini)
                .frame(maxWidth: 140)

            Text("\(Int((controller.opacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            Spacer(minLength: 0)
        }
        .help("Прозрачность окна. Размер меняется перетаскиванием краёв, положение — перетаскиванием окна; и то и другое запоминается между запусками.")
    }

    /// The scope of the invisibility guarantee, spelled out in the interface and
    /// not only in `docs/adr/0004-invisibility-scope.md`, as that ADR requires.
    private var sharingScopeNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: 9))

            Text("Скрыто при шаринге окна или вкладки. При шаринге всего экрана невидимость не гарантируется.")
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .help("Окно исключено из захвата экрана, поэтому не попадает в шаринг отдельного окна или вкладки браузера. Шаринг всего экрана сознательно не поддерживается — выбирайте окно или вкладку.")
    }
}

#Preview {
    // A session with no sources: the preview shows the empty transcript and the
    // controls, without asking the previewing machine for its microphone.
    let session = SessionController(engine: SessionEngine(), requestMicrophoneAccess: { false })
    // A throwaway settings suite, so previewing never rewrites the user's own
    // model choice or hotkeys. Nothing calls `prepare()`, so no gigabytes move
    // either.
    let settings = SettingsStore(
        defaults: UserDefaults(suiteName: "GhostMeetOverlayPreview") ?? .standard,
        secrets: InMemorySecretStore()
    )
    let recognition = SpeechModelStatus(store: settings)
    // A registry that registers nothing: previewing must not take four chords
    // away from the machine running Xcode.
    let hotkeys = HotkeyCenter(store: settings, registry: InertHotkeyRegistry())
    ContentView(
        controller: OverlayWindowController(
            session: session,
            recognition: recognition,
            hotkeys: hotkeys,
            openSettings: { _ in },
            settings: settings
        ),
        session: session,
        recognition: recognition,
        settings: settings,
        hotkeys: hotkeys,
        openSettings: { _ in }
    )
    .frame(width: 420, height: 520)
}
