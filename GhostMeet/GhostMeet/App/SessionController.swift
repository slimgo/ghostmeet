//
//  SessionController.swift
//  GhostMeet
//

import Foundation
import Observation
import os

/// Everything that stands between the button in the overlay and `SessionEngine`.
///
/// The engine sees its sources through `AudioSource` and must not learn what
/// they are; asking the operating system for permission, on the other hand, is
/// source-specific — the microphone has its own gate, `Them` will bring another
/// one (screen recording). So the gate lives here, one level above the engine.
///
/// A refusal is kept as state and shown inside the overlay window. It must never
/// become a system notification: the banner would be drawn on top of whatever
/// the user is sharing and hand the app over (ADR-0004).
@Observable
final class SessionController {

    /// Why listening is not running, in words meant for the user. `nil` while
    /// nothing has gone wrong.
    private(set) var failure: Failure?

    /// A start is in flight — the system permission dialog may be up.
    private(set) var isStarting = false

    /// Whether quitting the app is allowed right now.
    ///
    /// **The app has no other way out.** `LSUIElement` buys the invisibility the
    /// product is built on — no Dock icon, no menu bar, nothing in ⌘-Tab — and
    /// takes «закрыть» with it: before the overlay grew a button, quitting meant
    /// Activity Monitor. A user who cannot close a program that listens to their
    /// microphone is right to distrust it, whatever the app promises.
    ///
    /// Refused while listening on purpose, and the rule lives here rather than in
    /// the view so it can be stated once and tested: mid-interview the window is
    /// a hand's width from the chords pressed without looking, and a stray click
    /// would end the call with no undo. Stopping first is one extra press and
    /// turns quitting into a decision rather than a slip.
    var canQuit: Bool { !isListening && !isStarting }

    /// What microphone capture is doing, in the capture layer's own words.
    ///
    /// Here for the same reason `themStatus` is: capture publishes it from an
    /// arbitrary thread and the overlay reads it on the main actor.
    var micStatus: MicCaptureStatus = .idle

    /// Which way the sound goes, or `nil` when nobody has classified it.
    ///
    /// `nil` is not «неизвестно» — that is a verdict of its own, and it has
    /// wording. `nil` means no classifier is attached at all: a session built for
    /// a test or a preview, which must not put a warning about speakers into a
    /// window that has no sound hardware behind it.
    var audioRoute: AudioRoute?

    /// The classifier itself, held for the life of the session so its
    /// subscription outlives `dualChannel(...)`.
    @ObservationIgnored private var routeMonitor: AudioRouteMonitor?

    /// What the `Them` channel is doing, in the channel's own words.
    ///
    /// Kept here rather than read off the source, because the source publishes it
    /// from an arbitrary thread and the overlay reads it on the main actor. Until
    /// ticket 10 this travelled to the unified log and nowhere else, which meant
    /// the one failure the user cannot hear — a channel that never started — was
    /// visible to us and invisible to them.
    var themStatus: ThemCaptureStatus = .idle

    /// The engine itself, exposed so that later screens (suggestion feed,
    /// context clearing) can reach it without going through this type.
    let engine: SessionEngine

    /// The microphone gate, injected so the seam is testable and so this type
    /// keeps no direct knowledge of `AVFoundation`.
    @ObservationIgnored private let requestMicrophoneAccess: () async -> Bool

    /// Whether the recognition model can transcribe right now.
    ///
    /// A closure rather than the model status itself: everything below this type
    /// sees `SpeechRecognizer` and must not learn that Whisper — or any
    /// particular download — is behind it (ADR-0001). The closure reads an
    /// `@Observable` phase in the app, which is what makes
    /// `startWhenRecognitionIsReady()` and the button's enabled state follow it
    /// without a notification of any kind.
    @ObservationIgnored private let isRecognitionReady: () -> Bool

    /// Where the line between "the conversation" and "what the user asked to
    /// forget" is kept. Shared with the composer, so clearing the context reaches
    /// the model and not only the window.
    let context: ConversationContext

    /// The start currently in flight, kept so that it can be waited for.
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(
        engine: SessionEngine,
        requestMicrophoneAccess: @escaping () async -> Bool = { await MicCaptureService.requestAccess() },
        isRecognitionReady: @escaping () -> Bool = { true },
        // Defaulted in the body rather than here: `ConversationContext` is
        // main-actor isolated, and a default argument is evaluated outside any
        // actor — the same reason `SessionEngine` defaults its composer this way.
        context: ConversationContext? = nil
    ) {
        self.engine = engine
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.isRecognitionReady = isRecognitionReady
        self.context = context ?? ConversationContext()
    }

    // MARK: - What the overlay reads

    var isListening: Bool { engine.isListening }

    /// Whether pressing "Слушать" would do anything.
    ///
    /// The overlay disables the button on this and prints the reason next to it.
    /// The point is not tidiness: a turn closed before the model is loaded is
    /// refused outright rather than queued (`WhisperSpeechRecognizer`), so
    /// listening that starts a few seconds early does not merely lag — it drops
    /// the opening question of the call, in full or in half.
    var canStartListening: Bool { isRecognitionReady() }

    /// The transcript as it stands: turns of both channels in the order they
    /// were closed, minus whatever the user cleared.
    var transcript: [Turn] { context.remembered(engine.transcript) }

    /// The suggestion feed, oldest first. The last one is the answer to the
    /// question just asked and is the one the overlay highlights.
    var suggestions: [Suggestion] { context.remembered(engine.suggestions) }

    /// Whether the model is writing an answer right now — the "думает" state of
    /// the indicators.
    var isGenerating: Bool {
        suggestions.last?.state == .streaming
    }

    /// Whether a press has been taken and the request is still being put
    /// together — the tail of the question recognised, the screen grabbed.
    ///
    /// Shown for the length of the gap ADR-0008 accepts as the price of pressing:
    /// a second, sometimes two, in which the window would otherwise look as if
    /// the chord had not registered.
    var isPreparingAnswer: Bool { engine.isPreparingAnswer }

    /// The reason the last suggestion did not arrive, or `nil`.
    var lastSuggestionFailure: String? {
        guard case .failed(let reason) = suggestions.last?.state else { return nil }
        return reason
    }

    // MARK: - What the user asks for

    /// Жанр «коротко» — the default press (ADR-0008).
    func suggestBriefly() {
        engine.suggestBriefly()
    }

    /// The «подробно» genre.
    func suggestInDetail() {
        engine.suggestInDetail()
    }

    /// Answers a question the user typed — mode `Ask`.
    ///
    /// A passthrough on purpose: whether a question is worth asking is a decision
    /// of the engine (it is the one that knows what is already being answered),
    /// and the overlay must not have to know that. What this type adds is the
    /// same thing it adds everywhere else — the window has one object to talk to.
    func ask(_ question: String) {
        engine.ask(question)
    }

    /// Asks for the task on screen to be solved — mode `Solve on screen`.
    ///
    /// Works whether or not the session is listening: the screen is the whole
    /// input.
    func solveOnScreen() {
        engine.solveOnScreen()
    }

    // MARK: - Clearing the context

    /// Forgets the conversation so far: the transcript, the suggestions, and what
    /// the next prompt is built from.
    ///
    /// The `Профиль` is untouched by construction — it lives in `SettingsStore`,
    /// not here, and belongs to the user rather than to the call. Listening is
    /// untouched too: this is "start the conversation over", not "stop".
    func clearContext() {
        context.forget(turns: engine.transcript, suggestions: engine.suggestions)
    }

    // MARK: - Checking that sound is arriving

    /// Starts counting what reaches the channels. See `CaptureProbe`.
    func beginCaptureProbe() {
        engine.beginProbe()
    }

    func endCaptureProbe() -> CaptureProbe {
        engine.endProbe()
    }

    // MARK: - Start and stop

    func toggle() {
        isListening ? stop() : start()
    }

    /// Asks for microphone access and starts capture once it is granted.
    ///
    /// Access is requested every time rather than once at launch: a user who
    /// declined can grant it in System Settings and press the button again
    /// without restarting the app.
    ///
    /// A model that is not ready stops the start before the microphone is even
    /// asked for — there is nothing to transcribe with, and the permission
    /// dialog would be pure noise. Nothing is recorded in `failure` for it: the
    /// reason is already on screen next to the disabled button, it is temporary
    /// by nature, and a `failure` set here would still be sitting in the window
    /// seconds later when the model has long been ready.
    func start() {
        guard !isListening, !isStarting else { return }
        guard isRecognitionReady() else { return }
        failure = nil
        isStarting = true
        startTask = Task { [weak self] in
            guard let self else { return }
            let granted = await requestMicrophoneAccess()
            isStarting = false
            guard granted else {
                failure = .microphoneDenied
                return
            }
            do {
                try engine.start()
            } catch {
                failure = .captureFailed(error.localizedDescription)
            }
        }
    }

    /// Waits for a start that has already been asked for.
    ///
    /// Permission is an asynchronous round trip through the system, so whoever
    /// needs to know how it ended — a test, later the hotkey path — has to be
    /// able to wait for it instead of sleeping. Mirrors
    /// `SessionEngine.waitForRecognition()`.
    func waitForStart() async {
        await startTask?.value
    }

    /// Starts listening the moment the recognition model becomes usable, and not
    /// a moment earlier.
    ///
    /// For callers that mean "listen to this call" rather than "listen now" —
    /// the hotkey pressed while the model is still loading (ticket 10). Calling
    /// `start()` there would silently do nothing; this waits instead, using the
    /// same observation trick as `followThresholds(of:)`.
    func startWhenRecognitionIsReady() {
        guard !isListening, !isStarting else { return }
        let ready = withObservationTracking {
            isRecognitionReady()
        } onChange: { [weak self] in
            // `onChange` fires *before* the new value is stored, so re-reading
            // has to wait for the next turn of the main actor.
            Task { @MainActor [weak self] in
                self?.startWhenRecognitionIsReady()
            }
        }
        if ready { start() }
    }

    /// Stops capture and closes the turn that was in progress.
    func stop() {
        engine.stop()
    }

    /// Takes one report from microphone capture.
    ///
    /// Three of the four cases do something, and each is a different promise the
    /// ticket makes. A restart closes the `Реплика` that was open, so a device
    /// switch never swallows half a sentence without saying so. A capture that
    /// came back clears the failure it left in the window — a sentence about a
    /// microphone that is working again would be worse than none. And a device
    /// that never came back becomes the same `failure` a refused microphone
    /// does: inside the window, next to the `You` indicator, never a system
    /// banner (ADR-0004).
    @MainActor
    func apply(micStatus status: MicCaptureStatus) {
        micStatus = status
        switch status {
        case .restarting:
            engine.sourceInterrupted(.you)
        case .capturing:
            if case .captureFailed = failure { failure = nil }
        case .lost(let reason):
            failure = .captureFailed(reason)
        case .idle:
            break
        }
    }

    // MARK: - Audio route

    /// Attaches a route classifier: the window starts saying which way the sound
    /// goes, and strict mode starts believing it.
    ///
    /// Two consumers, one source. The window gets a wording; the audio layer gets
    /// a `Bool` through `SessionEngine.isLeakyRoute`, read on every `You` frame —
    /// which is why the closure asks the monitor for its cached verdict rather
    /// than classifying anything itself.
    ///
    /// The fallback in that closure is `true`, and it is the same safe side the
    /// seam shipped with: a monitor that has gone away is not evidence of
    /// headphones.
    @MainActor
    func follow(route monitor: AudioRouteMonitor) {
        routeMonitor = monitor
        engine.isLeakyRoute = { [weak monitor] in monitor?.mayLeak ?? true }
        monitor.onChange { [weak self] route in
            Logger(subsystem: "Mixxy.GhostMeet", category: "capture")
                .info("МАРШРУТ ЗВУКА: \(route.summary, privacy: .public)")  // не переводится: журнал
            // Core Audio posts from its own queue; the overlay reads this on the
            // main actor. The same hop the two capture channels make.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.audioRoute = route }
            }
        }
        monitor.start()
        // `start()` publishes only a *change*, and the first reading is not one
        // when it happens to equal the unread value. Taking it directly is what
        // makes the window right from the first redraw.
        audioRoute = monitor.route
    }

    // MARK: - Thresholds

    /// Keeps the engine's thresholds equal to what the settings screen shows.
    ///
    /// The store is observable, so re-reading it after every change is the whole
    /// mechanism: no notification, no restart of the session, no Apply button.
    /// Only turns that start afterwards are affected, which is what the engine
    /// documents.
    func followThresholds(of settings: SettingsStore) {
        withObservationTracking {
            engine.config = settings.turnSegmentation
        } onChange: { [weak self] in
            // `onChange` fires *before* the new value is stored, so re-reading
            // has to wait for the next turn of the main actor.
            Task { @MainActor [weak self] in
                self?.followThresholds(of: settings)
            }
        }
    }

    // MARK: - Provider

    /// Keeps the model equal to what the settings screen shows.
    ///
    /// The same mechanism as `followThresholds(of:)`: the store is observable,
    /// so re-reading it after every change is the whole thing. Switching from
    /// Claude to a local server — or fixing a base URL — takes effect on the
    /// next suggestion, with no restart of the app and no restart of the call.
    func followProviderSelection(of settings: SettingsStore) {
        withObservationTracking {
            applyProvider(from: settings)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.followProviderSelection(of: settings)
            }
        }
    }

    /// Builds the selected provider and hands it to the engine.
    ///
    /// A selection that cannot be built — a mistyped base URL, an emptied model
    /// — leaves the previous provider in place on purpose: the user is editing a
    /// text field mid-call, and going silent after every keystroke that does not
    /// yet parse would be worse than answering with the provider that worked.
    /// The reason is not swallowed, it is shown by the settings screen through
    /// `SettingsStore.providerConfigurationError`, next to the field that caused
    /// it — never as a system banner, which would be drawn over the shared
    /// screen (ADR-0004).
    private func applyProvider(from settings: SettingsStore) {
        guard let provider = try? settings.makeProvider() else { return }
        engine.provider = provider
    }
}

/// The line between the conversation and what the user asked to forget.
///
/// Clearing the context is a decision of the session, not of the recorder:
/// `SessionEngine` keeps the raw record of the call, and this type says which
/// part of it still counts. Everything that reads the conversation goes through
/// it — the overlay, and, through `ContextLimitedComposer`, the prompt. Clearing
/// that only emptied the window would be a lie: the model would go on answering
/// with the very context the user just asked it to forget.
///
/// Turns are remembered by identity rather than by a cut-off time. Their
/// timestamps come from the session clock and their text arrives later, when
/// recognition finishes — a turn that was closed before the clear and
/// transcribed after it still belongs to the part that was forgotten.
@MainActor
@Observable
final class ConversationContext {

    private(set) var forgottenTurns: Set<Turn.ID> = []
    private(set) var forgottenSuggestions: Set<Suggestion.ID> = []

    init() {}

    /// Marks everything currently on the record as forgotten.
    func forget(turns: [Turn], suggestions: [Suggestion]) {
        forgottenTurns.formUnion(turns.map(\.id))
        forgottenSuggestions.formUnion(suggestions.map(\.id))
    }

    func remembered(_ turns: [Turn]) -> [Turn] {
        guard !forgottenTurns.isEmpty else { return turns }
        return turns.filter { !forgottenTurns.contains($0.id) }
    }

    func remembered(_ suggestions: [Suggestion]) -> [Suggestion] {
        guard !forgottenSuggestions.isEmpty else { return suggestions }
        return suggestions.filter { !forgottenSuggestions.contains($0.id) }
    }
}

/// A composer that only ever sees the part of the transcript the user still
/// wants the model to know about.
///
/// It wraps the real composer instead of being one: how many turns a mode reads
/// and what it says to the model stays in the prompt layer, and "which turns
/// exist at all" is a question of the session.
///
/// One wrapper for every ask, `Ask` included — otherwise the one place a
/// forgotten turn could still surface would be the very question the user typed
/// to change the subject. (`Solve on screen` reads no transcript at all, so for
/// that ask this is a no-op — the right kind: the rule is stated once rather than
/// per mode.)
@MainActor
struct ContextLimitedComposer: SuggestionComposer {

    let context: ConversationContext
    let wrapped: any SuggestionComposer

    func compose(
        _ ask: SuggestionAsk,
        transcript: [Turn],
        screen: ScreenContext,
        accepting capabilities: ProviderCapabilities
    ) -> SuggestionRequest {
        wrapped.compose(
            ask,
            transcript: context.remembered(transcript),
            // The screen is deliberately *not* filtered: it shows what is in
            // front of the user at this instant, and clearing the conversation
            // says nothing about it.
            screen: screen,
            accepting: capabilities
        )
    }
}

extension SessionController {

    /// Why the session is not listening.
    ///
    /// Two cases, because the user's next step differs: a denied microphone is
    /// fixed in System Settings, a capture failure is not.
    enum Failure: Equatable {
        /// The system refused microphone access, or the user did.
        case microphoneDenied
        /// Capture itself failed to start, or stopped and would not come back —
        /// no input format, or an input device that went away for good.
        case captureFailed(String)

        var message: String {
            switch self {
            case .microphoneDenied:
                String(localized: "Нет доступа к микрофону. Разрешите его в «Системных настройках» → «Конфиденциальность и безопасность» → «Микрофон», затем нажмите «Слушать» ещё раз.")
            case .captureFailed(let reason):
                reason
            }
        }

        /// Whether the user can be sent straight to the switch that fixes it.
        var isPermissionDenied: Bool { self == .microphoneDenied }
    }

    /// The session the app actually runs: both channels in, thresholds as the
    /// user set them, recognition as the settings screen selected it.
    ///
    /// This is the one place where the concrete captures, the concrete
    /// recogniser and the concrete model meet. Everything below it sees
    /// `AudioSource`, `SpeechRecognizer` and `LLMProvider` only, so a second
    /// capture backend, a different recogniser or a local model arrives without
    /// this signature or the engine changing. `provider` is a parameter so that
    /// a test can put a stub in the same slot.
    ///
    /// `Them` follows the settings screen on its own, in both of the ways it
    /// can be re-pointed: at another application, and at the other capture
    /// backend. Neither needs the session restarted, let alone the app.
    ///
    /// The model is whichever one the settings screen selected, built through
    /// `ProviderFactory` — never a hard-wired Claude. `provider` overrides it so
    /// that a test can put a stub in the same slot; when it does, nothing should
    /// call `followProviderSelection(of:)` on the result, or the stub would be
    /// replaced by the user's choice.
    ///
    /// `isRecognitionReady` is the same kind of seam: the app passes the
    /// observable phase of the model it just built, a test passes a constant.
    /// It defaults to "ready" so that a test about providers or thresholds does
    /// not have to know that recognition has a warm-up at all.
    static func dualChannel(
        settings: SettingsStore,
        recognizer: SpeechRecognizer,
        isRecognitionReady: @escaping () -> Bool = { true },
        provider: (any LLMProvider)? = nil
    ) -> SessionController {
        // The microphone takes no argument about echo cancellation any more:
        // system voice processing is never switched on, whichever backend feeds
        // `Them` (ADR-0009). The leak from the speakers is cleaned on our side
        // instead.

        // One source for the whole life of the engine, with the real backend
        // swapped inside it. Which of the two it is stays a setting the user can
        // change mid-call: they fail on different machines, and a choice that
        // needed a relaunch would be made blind, once, and never revisited.
        let mic = MicCaptureService()

        let them = SwitchableThemSource(backend: settings.themCaptureBackend)
        them.followSourceSelection(of: settings)
        them.followCaptureBackend(of: settings)

        // One context object for the whole session, shared by the two things
        // that have to agree about what was cleared: the window, which shows the
        // conversation, and the composer, which turns it into a prompt.
        let context = ConversationContext()

        let controller = SessionController(
            engine: SessionEngine(
                sources: [mic, them],
                recognizer: recognizer,
                provider: provider ?? (try? settings.makeProvider()),
                // The profile and the заготовки to this interview are read at
                // request time rather than captured, so editing either mid-call
                // takes effect on the next suggestion. Both live in user-scoped
                // storage and survive clearing the conversation. All four asks —
                // both genres, `Ask` and `Solve on screen` — go through this one
                // composer and obey the same clearing.
                composer: ContextLimitedComposer(
                    context: context,
                    wrapped: PromptComposer(
                        profile: { settings.profile },
                        interviewLanguage: { settings.interviewLanguage },
                        interviewContext: { settings.interviewContext }
                    )
                ),
                config: settings.turnSegmentation
            ),
            isRecognitionReady: isRecognitionReady,
            context: context
        )

        // Which way the sound goes. Attached here rather than inside the engine
        // because it feeds two different consumers — the window and strict mode —
        // and this is the one place that knows about both.
        controller.follow(route: AudioRouteMonitor())

        // The microphone says the same kind of thing the `Them` side does, and
        // it became worth saying with ADR-0009: we no longer switch the input
        // device's mode ourselves, so the next process that does it can stop our
        // capture dead. What used to be impossible is now somebody else's
        // ordinary behaviour, and it has to be visible.
        mic.onStatusChange = { [weak controller] status in
            Logger(subsystem: "Mixxy.GhostMeet", category: "capture")
                .info("КАНАЛ YOU: \(status.message, privacy: .public)")  // не переводится: журнал
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller?.apply(micStatus: status) }
            }
        }

        // The `Them` side says why it is quiet here and only here. It goes two
        // ways, both of them inside the app: into the overlay, which is where the
        // user finds out that the channel never started, and into the unified
        // log, which is the only trace left once the call is over. Never into a
        // system banner — that would be drawn over the shared screen (ADR-0004).
        controller.themStatus = them.status
        them.onStatusChange = { [weak them, weak controller] status in
            let backend = them?.backend.displayName ?? "—"
            Logger(subsystem: "Mixxy.GhostMeet", category: "capture")
                .info("КАНАЛ THEM (\(backend, privacy: .public)): \(status.message, privacy: .public)")  // не переводится: журнал
            // Statuses arrive from capture threads; the overlay reads this on the
            // main actor. The same hop `SessionEngine` makes for audio frames.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller?.themStatus = status }
            }
        }

        return controller
    }
}
