//
//  SessionEngine.swift
//  GhostMeet
//

import Foundation
import Observation
import os

/// The one orchestrator of a call.
///
/// It takes in frames of both channels, closes turns, keeps the transcript and
/// answers when the user asks. Everything outside of it is seen through protocols
/// only — `AudioSource`, `SpeechRecognizer` — so the engine never learns whether
/// audio comes from the microphone or from a process tap, nor which engine
/// recognises it (ADR-0001).
///
/// **A suggestion starts on a press and on nothing else** (ADR-0008). A closed
/// `Them` turn is recognised, lands in the transcript, and that is all it does:
/// the candidate knows most of the answers, and asking the model about every
/// question costs tokens, buries the feed and drowns the model in context.
///
/// Time comes from an injected clock, which makes the engine the single seam of
/// the app: a test feeds frames, moves the clock and checks which turns showed
/// up in the transcript and what reached the model, without waiting in real time.
@MainActor
@Observable
final class SessionEngine {
    /// Turns of both channels in the order they were closed — the only
    /// representation of the conversation.
    private(set) var transcript: [Turn] = []
    /// Suggestions in the order they were started, oldest first — the feed the
    /// overlay shows. A suggestion appears here the moment generation starts and
    /// grows fragment by fragment, so the user starts reading before the model
    /// has finished writing.
    private(set) var suggestions: [Suggestion] = []
    /// Whether capture is running.
    private(set) var isListening = false
    /// Last capture failure — of audio or of the screen — shown inside the
    /// window and nowhere else.
    private(set) var lastError: String?

    /// A press has been taken and the request is being put together: the tail of
    /// the question is being recognised and the screen is being grabbed.
    ///
    /// It exists because that gap is real and audible — a second, sometimes two,
    /// between the chord and the first token (ADR-0008). Without a sign that the
    /// press landed, the user presses again in the middle of it, and the second
    /// press throws away the answer the first one was about to produce.
    private(set) var isPreparingAnswer = false

    /// Segmentation thresholds. Changing them takes effect on the turns that
    /// start afterwards.
    var config: TurnSegmentationConfig {
        didSet {
            for segmenter in segmenters.values { segmenter.config = config }
        }
    }

    /// How long a press waits for the words that are still being recognised.
    ///
    /// A constant beside its use rather than a setting: there is nothing here for
    /// the user to decide, and the only thing they would notice is the failure
    /// mode. Generous on purpose — recognising the tail of a question takes a
    /// fraction of this — because the budget is not a target, it is the answer to
    /// "recognition wedged, and the request must still go out".
    static let recognitionBudget: TimeInterval = 4

    /// How long past the last loud `Them` frame the microphone is still assumed
    /// to be carrying the leak from the speakers.
    ///
    /// **0.4 s, and the number was measured rather than chosen.** The leak
    /// recordings of the ADR-0009 investigation were replayed against the app's
    /// own silence gate: for 34 phrase endings at full volume and at −12 dB, the
    /// microphone stayed above the gate for at most **170 ms** after the
    /// reference went quiet (p95 111 ms, median 10 ms). On top of that come two
    /// delays the recordings cannot show, because they belong to the app rather
    /// than to the room: a frame is 85 ms long, so the last loud `Them` frame is
    /// timestamped up to a frame late; and `Them` and the microphone arrive
    /// through different capture paths with buffers of their own. 170 + 85 + a
    /// comparable allowance for the second is 0.4 s.
    ///
    /// Being generous costs the opening of an answer the user starts inside that
    /// window; being stingy costs a whole `Реплика` of the interlocutor's voice
    /// filed under `You`, which is the failure that breaks the one guarantee the
    /// product has. Do not shrink it without measuring both capture paths.
    ///
    /// The same physical fact is read a second time by the layer below —
    /// `LeakDedup.neighbourhood`, which decides how far apart two `Реплики` may
    /// be and still be the same speech. A test keeps the two equal.
    static let echoTail: TimeInterval = 0.4

    /// Whether the current audio route lets `Them` out of the speakers and back
    /// into the microphone — the only configuration strict mode is right in.
    ///
    /// Answered by `AudioRouteMonitor`, which `SessionController.follow(route:)`
    /// plugs in here. The default stays «да, опасная» and is the value in force
    /// whenever nobody has plugged anything in — a session built for a test, or a
    /// monitor that has gone away. That is the safe side of the two: a user in
    /// headphones loses the first fraction of a second of an answer they started
    /// on top of the interlocutor, while a user on speakers who is wrongly
    /// trusted gets the interlocutor's voice written down as their own. The
    /// classifier obeys the same asymmetry — only a positively identified safe
    /// route answers `false`, «неизвестно» does not.
    ///
    /// A closure rather than a `Bool` because the route changes mid-call —
    /// headphones go in, the output device switches — and a value captured at
    /// composition time would be a lie by the second question.
    @ObservationIgnored var isLeakyRoute: () -> Bool = { true }

    private let clock: SessionClock

    /// Lifecycle of capture only — which sources came up, and what stopped them.
    ///
    /// Deliberate, not debugging: the overlay is excluded from screen capture and
    /// shows no log of its own, so when a user reports "it does not hear me" the
    /// unified log is the only way to tell a capture that never started from one
    /// that started and stayed quiet. Nothing per frame and nothing anybody said
    /// is ever written here.
    @ObservationIgnored private static let log = Logger(
        subsystem: "Mixxy.GhostMeet",
        category: "capture"
    )

    private let recognizer: SpeechRecognizer
    private let sources: [AudioSource]
    /// Where the screenshot and the text on it come from.
    ///
    /// Behind a protocol for the same reason capture and speech are (ADR-0001):
    /// the engine must be drivable without a display server or a Screen
    /// Recording grant, and a test has to be able to say what the screen showed.
    private let capturer: any ScreenCapturer
    /// The model behind the suggestions. Optional because the app has to be
    /// usable — capture, transcript, settings — before a provider is configured.
    ///
    /// Settable for the same reason `config` is: picking another provider in
    /// settings has to take effect on the next suggestion, not at the next
    /// launch. It is read when a generation starts, so a swap never disturbs the
    /// one already streaming. `SessionController.followProviderSelection(of:)`
    /// is what keeps it equal to the settings screen.
    @ObservationIgnored var provider: (any LLMProvider)?
    /// The prompt layer, behind its one seam: which prompt a press uses, how much
    /// of the conversation it reads and how many tokens it may spend are all
    /// decided there.
    private let composer: any SuggestionComposer
    private let segmenters: [Channel: TurnSegmenter]
    private var pauseWatchdog: Timer?
    /// Recognition running per closed turn. Each task removes its own entry when
    /// it is done, so what is left here is what is genuinely still being worked
    /// on — a press waits on exactly that before its request is composed.
    private var recognitionInFlight: [Turn.ID: Task<Void, Never>] = [:]
    /// The answer currently being prepared or generated. A newer press cancels
    /// it, which is what stops two answers streaming into one feed; it also lets
    /// whoever needs the finished suggestion wait for it.
    ///
    /// One slot for two phases in turn: first the task that waits for the words
    /// and the screen, then the task that reads the stream. Either way exactly
    /// one thing is cancellable at a time, which is what `supersedeAnswerInFlight()`
    /// relies on.
    private var suggestionTask: Task<Void, Never>?
    /// The screenshot being taken for that answer.
    ///
    /// Held apart from the generation because it starts earlier — the instant the
    /// user pressed, beside the wait for recognition — and has to be cancellable
    /// on its own. A superseded press otherwise pays for a frame and a few
    /// hundred milliseconds of text recognition nobody will read.
    ///
    /// Dropped as soon as its result has been handed on. A finished task holds on
    /// to its value, and that value is a JPEG of the whole screen — keeping the
    /// reference until the next press would leave a picture of whatever the user
    /// was looking at lying in memory for the rest of the call, in an app whose
    /// whole premise is that nothing about the screen is kept.
    private var screenTask: Task<ScreenContext, Never>?

    /// Whether a screenshot taken for a press is still being held.
    ///
    /// Nothing in the app reads this; it is here so that the release above is
    /// checkable, which for a leak of exactly one object is the only way to check
    /// it at all.
    var isHoldingScreenshot: Bool { screenTask != nil }

    init(
        sources: [AudioSource] = [],
        recognizer: SpeechRecognizer = StubSpeechRecognizer(),
        provider: (any LLMProvider)? = nil,
        // Defaulted in the body rather than here: the composer is main-actor
        // isolated, and a default argument is evaluated outside any actor.
        composer: (any SuggestionComposer)? = nil,
        capturer: (any ScreenCapturer)? = nil,
        clock: SessionClock = SystemClock(),
        config: TurnSegmentationConfig = .default
    ) {
        self.sources = sources
        self.recognizer = recognizer
        self.provider = provider
        self.composer = composer ?? PromptComposer()
        self.capturer = capturer ?? ScreenCaptureService()
        self.clock = clock
        self.config = config
        self.segmenters = Dictionary(
            uniqueKeysWithValues: Channel.allCases.map { channel in
                (channel, TurnSegmenter(channel: channel, config: config))
            }
        )
    }

    /// Starts listening on every configured source.
    func start() throws {
        guard !isListening else { return }
        lastError = nil
        do {
            for source in sources {
                try source.start { [weak self] frame in
                    // Frames arrive on a realtime audio thread; the transcript
                    // lives on the main actor, so the hop happens here, in the
                    // one place that knows about both.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.ingest(frame) }
                    }
                }
            }
        } catch {
            sources.forEach { $0.stop() }
            lastError = error.localizedDescription
            Self.log.error("ЗАХВАТ НЕ СТАРТОВАЛ причина=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        isListening = true
        let started = sources.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        Self.log.info("ЗАХВАТ СТАРТОВАЛ источники=\(started, privacy: .public)")
        startPauseWatchdog()
    }

    /// Stops listening and closes the turn that was in progress.
    ///
    /// Closing here only writes words into the transcript. It asks for nothing:
    /// stopping is not a request for a suggestion, and since ADR-0008 a closed
    /// turn starts nothing by itself anyway.
    func stop() {
        guard isListening else { return }
        sources.forEach { $0.stop() }
        pauseWatchdog?.invalidate()
        pauseWatchdog = nil
        isListening = false
        for channel in Channel.allCases {
            if let captured = segmenters[channel]?.flush() { append(captured) }
        }
    }

    /// Takes one captured frame.
    ///
    /// The channel comes from the frame, that is from the source that produced
    /// it, and never from what was said.
    func ingest(_ frame: AudioFrame) {
        guard let segmenter = segmenters[frame.channel] else { return }
        let now = clock.now
        guard !isLeakFromSpeakers(frame, at: now) else { return }
        if let captured = segmenter.accept(frame, at: now) {
            append(captured)
        }
    }

    /// Whether this microphone frame is the interlocutor coming back out of the
    /// speakers rather than the user talking — строгий режим.
    ///
    /// The cheapest of the three layers ADR-0009 lists, and the reasoning is one
    /// sentence: if the interlocutor is speaking *right now*, then whatever the
    /// microphone is picking up is them. Without a defence the measurement is
    /// brutal — 17.8 seconds of a 19-second question land in `You` as the user's
    /// own speech.
    ///
    /// Three conditions, and each one is a promise:
    ///
    /// *Only in a leaky route.* In headphones there is nothing to leak, and the
    /// mode would cost interruptions for nothing.
    ///
    /// *Only while no `Реплика` of `You` is open.* The user may have started
    /// before the interlocutor did; cutting their sentence in half mid-word
    /// would corrupt the transcript in the other direction. The price of that
    /// choice is stated plainly: a turn the user starts **on top of** the
    /// interlocutor is lost whole. Measured, that is the safe half of the
    /// trade — on speakers the leak is louder than the user's own voice — and it
    /// is the reason this cannot be the only layer.
    ///
    /// *Only within `echoTail` of the last loud `Them` frame*, decided by the
    /// very gate that cuts `Them` into turns rather than by a threshold of its
    /// own. Two gates would drift apart on the first edit, and the question
    /// «звучит ли Them» has exactly one right answer per session.
    private func isLeakFromSpeakers(_ frame: AudioFrame, at now: TimeInterval) -> Bool {
        guard frame.channel == .you, isLeakyRoute() else { return false }
        guard segmenters[.you]?.hasOpenTurn == false else { return false }
        guard let themVoiceAt = segmenters[.them]?.lastVoiceAt else { return false }
        return now - themVoiceAt <= Self.echoTail
    }

    /// Lets time pass without new audio: a turn still closes on its pause or on
    /// the forced flush even if the source went quiet altogether.
    func tick() {
        let now = clock.now
        for channel in Channel.allCases {
            if let captured = segmenters[channel]?.evaluate(at: now) { append(captured) }
        }
    }

    /// Says that a source stopped delivering audio for a moment — the input
    /// device changed under it and capture is being brought back.
    ///
    /// The open `Реплика` of that channel is closed here rather than left to the
    /// pause threshold, and the minimum length is deliberately skipped. A restart
    /// takes a device round trip, so what is open is a sentence with a hole
    /// punched in it; closing it now means the two halves reach the transcript as
    /// two `Реплики` — which `TranscriptFormatter` puts back together at prompt
    /// time — instead of one turn that silently straddles the gap. Skipping the
    /// minimum is the same reason `closeIgnoringMinimum()` exists for a press:
    /// the words were cut short by us, not by the speaker, and a short fragment
    /// of real speech is not a cough.
    func sourceInterrupted(_ channel: Channel) {
        guard let captured = segmenters[channel]?.closeIgnoringMinimum() else { return }
        append(captured)
    }

    /// Waits for the recognition already started for closed turns.
    ///
    /// Recognition runs beside segmentation so that a slow pass never delays the
    /// next turn; whoever needs its result has to be able to wait for it without
    /// sleeping.
    func waitForRecognition() async {
        let running = recognitionInFlight
        recognitionInFlight.removeAll()
        for task in running.values { await task.value }
    }

    /// Waits for the suggestion a press started, preparation included.
    ///
    /// Same reason as `waitForRecognition()`: generation runs beside the call so
    /// that nothing waits on the model, and a test has to be able to reach the
    /// end of it without sleeping.
    func waitForSuggestion() async {
        await waitForRecognition()
        // Waiting once is not enough: a press waits for the words and the screen
        // in a task of its own and only then hands the slot to the task that
        // reads the stream. Following the slot until it stops changing covers
        // both phases with one rule.
        var awaited: Task<Void, Never>?
        while let task = suggestionTask, task != awaited {
            awaited = task
            await task.value
        }
    }

    private func append(_ captured: CapturedTurn) {
        let turn = Turn(
            channel: captured.channel,
            timestamp: captured.startedAt,
            duration: captured.duration
        )
        transcript.append(turn)
        recognize(
            turn: turn.id,
            audio: SpeechAudio(samples: captured.samples, sampleRate: captured.sampleRate)
        )
    }

    /// Starts recognising one closed turn, and nothing else.
    ///
    /// Recognition is **never cancelled** — not by a press, not by the next turn.
    /// The words belong in the transcript whatever happens to the answer, and the
    /// request the user is waiting for is composed from them.
    private func recognize(turn id: Turn.ID, audio: SpeechAudio) {
        let recognizer = recognizer
        let task = Task { [weak self] in
            defer { self?.recognitionInFlight[id] = nil }

            // A failed pass leaves the turn in place with no text: losing a turn
            // would be worse than showing one without words.
            let text = (try? await recognizer.transcribe(audio)) ?? ""
            self?.apply(text: text, to: id)
        }
        recognitionInFlight[id] = task
    }

    /// Stops everything the previous press set going.
    ///
    /// Three things at once, because all three are work on a question nobody is
    /// waiting for any more. The generation: cancellation reaches the socket in
    /// every provider, so a superseded request stops costing time and money
    /// instead of being counted to the end in the background. The screenshot
    /// being taken for it: a frame plus a few hundred milliseconds of text
    /// recognition that nothing will read. And the suggestion itself, which
    /// settles as `superseded`.
    ///
    /// What was already written stays on screen. The feed is history, and half an
    /// answer the user is in the middle of reading is not rubbish — it simply
    /// stops growing.
    private func supersedeAnswerInFlight() {
        suggestionTask?.cancel()
        suggestionTask = nil
        screenTask?.cancel()
        screenTask = nil
        isPreparingAnswer = false
        for index in suggestions.indices where !suggestions[index].isSettled {
            suggestions[index].state = .superseded
        }
    }

    private func apply(text: String, to id: Turn.ID) {
        guard !text.isEmpty, let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].text = text
        refreshLeakMarks(around: transcript[index])
    }

    /// Re-decides which turns of `You` are `Протечка канала` now that one more
    /// turn has words — дедупликация по тексту, the second layer of ADR-0009.
    ///
    /// Run on every recognised turn rather than once when the turn itself is
    /// recognised, because the two channels are recognised side by side and
    /// finish in whatever order they finish: the words of `Them` that convict a
    /// turn of `You` arrive after it as often as before it. `LeakDedup.isLeak` is
    /// pure and idempotent precisely so that this can be re-run instead of
    /// latched.
    ///
    /// Bounded to the turns the new words could possibly have changed — the turn
    /// itself when it is `You`, its neighbours when it is `Them` — so this stays
    /// a handful of comparisons per recognised turn however long the call gets.
    private func refreshLeakMarks(around changed: Turn) {
        let affected: [Turn.ID] = switch changed.channel {
        case .you:
            [changed.id]
        case .them:
            transcript
                .filter { $0.channel == .you && LeakDedup.overlap($0, changed) }
                .map(\.id)
        }

        for id in affected {
            guard let index = transcript.firstIndex(where: { $0.id == id }) else { continue }
            let verdict = LeakDedup.isLeak(transcript[index], among: transcript)
            guard transcript[index].isLeak != verdict else { continue }
            transcript[index].isLeak = verdict
        }
    }

    // MARK: - Что просит пользователь

    /// Жанр «коротко» — the default press.
    ///
    /// The user is already speaking and is missing one thing: a term, a number,
    /// three bullets, a distinction (ADR-0008).
    func suggestBriefly() {
        startAnswer(.brief)
    }

    /// Жанр «подробно» — the full answer, for a subject that is unfamiliar whole.
    func suggestInDetail() {
        startAnswer(.detailed)
    }

    /// Answers a question the user typed — mode `Ask`.
    ///
    /// Blank input does nothing at all rather than asking the model to answer
    /// nothing: an empty question would still supersede the suggestion on screen,
    /// and losing a half-read answer to a stray Return is a worse outcome than a
    /// button that seems not to have worked.
    func ask(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        startAnswer(.question(text))
    }

    /// Solves the task on the screen — mode `Solve on screen`.
    ///
    /// Needs no session: the screen is the whole input, so this works before
    /// listening has ever been started and keeps working after it is stopped.
    func solveOnScreen() {
        startAnswer(.screenTask)
    }

    /// Takes a press: closes the question, grabs the screen, waits for the words,
    /// then generates.
    ///
    /// The order is the design, and each step is there for a reason ADR-0008
    /// spells out.
    ///
    /// *Supersede first.* A second press replaces the answer of the first — two
    /// generations writing into one feed would leave the user reading whichever
    /// won the race.
    ///
    /// *Then close what is open on **both** channels, whatever its length.* The
    /// user presses the instant the interlocutor stops talking, which is before
    /// the pause threshold has run; without this the last phrase of the question
    /// does not exist yet. `You` is closed for the mirror-image reason: by the
    /// time anyone presses they are already answering out loud, and the жанр
    /// «коротко» is built on that — the prompt says «я уже отвечаю, дай
    /// недостающее», and a model that cannot see what was already said starts the
    /// answer from the beginning, which is the failure the genre exists to
    /// prevent.
    ///
    /// *Then start the screenshot, and wait for recognition beside it.* Both cost
    /// hundreds of milliseconds, and run in parallel they cost the larger of the
    /// two rather than the sum. The second recognition pass this now adds is part
    /// of that parallel wait and not after it: `recognize(turn:audio:)` starts a
    /// task per turn, so two closed turns are two passes running at once.
    private func startAnswer(_ ask: SuggestionAsk) {
        // Before the provider is even looked at: the press says the interlocutor
        // has finished, and that is a fact about the conversation. A `Реплика`
        // does not depend on there being a model to answer it — an unconfigured
        // provider must not cost the user the tail of a question.
        closeOpenTurns()

        guard provider != nil else {
            reportNothingToAnswerWith(ask)
            return
        }
        supersedeAnswerInFlight()

        let screen = Task { [capturer] in await capturer.capture() }
        screenTask = screen

        // Taken after the forced close, so the tail of the question is part of
        // what is waited for. `Solve on screen` waits for nothing: it reads no
        // conversation, and waiting would be latency spent on words its prompt
        // will never see.
        let pending = ask.readsTranscript ? Array(recognitionInFlight.values) : []
        isPreparingAnswer = true

        suggestionTask = Task { [weak self, clock] in
            var heardEverything = true
            if !pending.isEmpty {
                // Over budget the request goes out **without** the late words
                // rather than not at all. They are not lost: recognition is never
                // cancelled, so the text still lands in the transcript — one
                // suggestion late, and without asking for anything of its own.
                heardEverything = await clock.wait(upTo: Self.recognitionBudget) {
                    for task in pending { await task.value }
                }
            }
            let context = await screen.value
            guard !Task.isCancelled else { return }
            self?.releaseScreen(screen)
            self?.startSuggestion(ask, screen: context, heardEverything: heardEverything)
        }
    }

    /// Lets go of a screenshot that has been used, unless a newer press has
    /// already put its own there.
    ///
    /// Compared by identity rather than blindly cleared: a press superseded
    /// between `await screen.value` returning and this line running would
    /// otherwise drop the *next* press's capture and leave nothing to cancel.
    private func releaseScreen(_ used: Task<ScreenContext, Never>) {
        guard screenTask == used else { return }
        screenTask = nil
    }

    /// Closes whatever either channel left open, so that the end of the question
    /// and the beginning of the answer both exist before the request is composed.
    ///
    /// `Them` first, then `You`, and the order is the reading order of the
    /// prompt: the question, then the half-sentence the user is in the middle of.
    /// Both are `Реплики` of their own channel — nothing is merged here, and
    /// `TranscriptFormatter` is what puts the user's interrupted sentence back
    /// together at prompt time, as it does for a question broken by a pause.
    ///
    /// The words go into the transcript unconditionally — even if the answer they
    /// were closed for is superseded a moment later. A `Реплика` is the record of
    /// what was said; it does not depend on what became of the suggestion.
    private func closeOpenTurns() {
        defer {
            // Всё, что записано к этому моменту, уходит в модель прямо сейчас —
            // значит, следующая реплика начинает новую мысль, как бы близко она
            // ни стояла по времени. Метка ставится ПОСЛЕ дозакрытия: границей
            // должна стать последняя реплика вместе с дозакрытым хвостом
            // вопроса, а не та, что была до него.
            if let last = transcript.indices.last { transcript[last].isBeforePress = true }
        }
        for channel in [Channel.them, .you] {
            guard let captured = segmenters[channel]?.closeIgnoringMinimum() else { continue }
            append(captured)
        }
    }

    private func startSuggestion(
        _ ask: SuggestionAsk,
        screen: ScreenContext,
        heardEverything: Bool = true
    ) {
        isPreparingAnswer = false
        guard let provider else { return }
        let request = composer.compose(
            ask,
            transcript: transcript,
            screen: screen,
            accepting: provider.capabilities
        )
        stream(
            request,
            from: provider,
            screen: screen,
            notice: notice(for: ask, heardEverything: heardEverything),
            kind: ask.kind
        )
    }

    /// What the user has to be told about the answer that is starting.
    ///
    /// One case: a press that reads the conversation while nothing is being
    /// captured. The request is **not** blocked — `Solve on screen` without
    /// listening is the ordinary way to use it, and refusing mid-interview would
    /// be worse than a thin answer — but an answer built from an empty transcript
    /// is indistinguishable from an answer built from the question, and without a
    /// word the user blames the model for it. `Solve on screen` gets no notice:
    /// it reads no conversation, so listening changes nothing about its answer.
    /// **Второй случай найден первым же живым прогоном, и он был молчаливым.**
    /// Интервьюер задал вопрос, пользователь нажал — распознавание последней
    /// реплики не уложилось в бюджет, запрос ушёл без неё, и модель ответила на
    /// предыдущий вопрос. Ответ при этом выглядел совершенно обычно: он связный,
    /// он по теме разговора, он просто не про то, что спросили секунду назад.
    /// Отличить это от «модель не поняла вопрос» пользователь не мог никак.
    ///
    /// Запрос по-прежнему уходит: ждать дольше — значит терять то, ради чего
    /// нажали. Но теперь над ответом стоит строка, и следующее нажатие уже
    /// застанет слова в транскрипте — распознавание не отменяется никогда.
    private func notice(for ask: SuggestionAsk, heardEverything: Bool) -> String? {
        guard ask.readsTranscript else { return nil }
        if !isListening { return String(localized: "Прослушивание выключено — отвечаю только по экрану.") }
        if !heardEverything {
            return String(localized: """
            Последние слова ещё распознавались — ответ собран без них. \
            Нажмите ещё раз, если он не про то.
            """)
        }
        return nil
    }

    /// Says in the feed that there is no model to answer with.
    ///
    /// Reported because the user pressed: silence in answer to a press reads as a
    /// broken app. Inside the window and nowhere else, like every other failure
    /// (ADR-0004).
    ///
    /// Carries the kind even though there is no answer to describe: in a saved
    /// call «не было ключа на просьбу решить задачу с экрана» and «не было ключа
    /// на короткое нажатие» are different accounts of the same evening, and the
    /// press happened either way.
    private func reportNothingToAnswerWith(_ ask: SuggestionAsk) {
        suggestions.append(
            Suggestion(
                state: .failed(LLMFailure.missingKey.message),
                startedAt: Date(),
                kind: ask.kind
            )
        )
    }

    // MARK: - Suggestions

    /// Starts one generation and puts it in the feed straight away.
    ///
    /// The suggestion is appended empty and `streaming`, before a single
    /// fragment has arrived: that is what lets the window show the answer being
    /// written instead of a spinner followed by a wall of text.
    ///
    /// Reading the stream is a task of its own — the one `supersedeAnswerInFlight()`
    /// cancels — rather than a continuation of the preparation that led here. That
    /// split is what lets a superseded press lose its answer and keep its words.
    ///
    /// The engine gets no further than this into what was asked: which prompt,
    /// how much of the conversation and how many tokens were all decided by the
    /// composer, and from here on the four things the user can press for are one
    /// object with one lifecycle.
    private func stream(
        _ request: SuggestionRequest,
        from provider: any LLMProvider,
        screen: ScreenContext,
        notice: String?,
        kind: Suggestion.Kind
    ) {
        // A screen that could not be grabbed is reported and then stepped over:
        // the request goes out without a picture rather than not at all. The
        // reason lives in the window and nowhere else — a system banner would be
        // drawn over the shared screen (ADR-0004).
        //
        // Cleared on a capture that worked, so a one-off failure does not leave
        // a sentence on screen for the rest of the call. Nothing else writes
        // here mid-session: an audio source that fails to start throws out of
        // `start()` and there is no session to report into.
        lastError = screen.failure

        let suggestion = Suggestion(notice: notice, startedAt: Date(), kind: kind)
        suggestions.append(suggestion)

        // The request leaves before the task that reads it is scheduled: the user
        // is waiting with their mouth open, and every hop between here and the
        // first token is latency they sit through.
        let stream = provider.stream(request)

        let id = suggestion.id
        suggestionTask = Task { [weak self] in
            do {
                for try await fragment in stream {
                    guard !Task.isCancelled else { return }
                    self?.append(fragment: fragment, to: id)
                }
                guard !Task.isCancelled else { return }
                self?.settle(id, as: .complete)
            } catch is CancellationError {
                // Superseded by a newer press; whoever cancelled owns the state.
                return
            } catch let cutoff as SuggestionCutoff {
                // Not a failure: whatever arrived is already in the card and
                // stays there. Only the reason is added, under the text it
                // explains — until now an answer cut mid-word looked exactly
                // like a model that had answered briefly.
                guard !Task.isCancelled else { return }
                self?.settle(id, as: .cut(cutoff.message))
            } catch {
                // Reported in the feed and nowhere else. A system notification
                // would be drawn over the shared screen (ADR-0004).
                self?.settle(id, as: .failed(Self.message(for: error)))
            }
        }
    }

    private func append(fragment: String, to id: Suggestion.ID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }),
              !suggestions[index].isSettled
        else { return }
        suggestions[index].text += fragment
    }

    /// Settles a suggestion, unless something already settled it: a stream that
    /// finishes after being superseded must not claim it completed.
    private func settle(_ id: Suggestion.ID, as state: Suggestion.State) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }),
              !suggestions[index].isSettled
        else { return }
        suggestions[index].state = state
    }

    /// The failure in words meant for the user: the provider's own wording when
    /// it gave one, the system's otherwise.
    private static func message(for error: any Error) -> String {
        (error as? LLMFailure)?.message ?? error.localizedDescription
    }

    private func startPauseWatchdog() {
        pauseWatchdog = Timer.scheduledTimer(
            withTimeInterval: config.pauseCheckInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
}

extension SessionEngine {
    /// Engine for the `You` channel alone: microphone in, recognition stubbed.
    ///
    /// `Them` joins later as a second source behind the same protocol, without
    /// the engine changing.
    static func microphoneOnly(config: TurnSegmentationConfig = .default) -> SessionEngine {
        SessionEngine(
            sources: [MicCaptureService()],
            recognizer: StubSpeechRecognizer(),
            config: config
        )
    }
}
