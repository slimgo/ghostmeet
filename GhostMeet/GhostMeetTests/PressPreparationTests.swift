//
//  PressPreparationTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// What a press manages to do before the request leaves — and what it refuses to
/// wait for.
///
/// The scenario every one of these is built around: the interviewer finishes
/// «…а как вы это делали с Postgres?» and the candidate presses immediately,
/// because that is the moment they know they are stuck. At that instant the pause
/// threshold has not run, so the tail of the question is still an open turn; and
/// even once it closes, its words do not exist yet, because recognition takes a
/// moment more. A request composed without either of them is not a shortened
/// question — `TranscriptFormatter` drops a turn with no text, so the model would
/// not see the question at all.
///
/// The budget is the dangerous half and is checked under `ManualClock`: the test
/// waits for the deadline to be armed and then moves the hands past it, so
/// "recognition against the clock" has one outcome and not two.
@Suite("Подготовка запроса по нажатию")
@MainActor
struct PressPreparationTests {

    // MARK: - Ожидание распознавания

    @Test("Нажали сразу после закрытия реплики — её слова всё-таки уходят в запрос")
    func aPressWaitsForTheWordsStillBeingRecognised() async {
        let call = PressCall(
            model: PressModel(.fragments(["Скажи ", "про GiST."])),
            recognises: "а как вы это делали с Postgres"
        )

        call.says(.them)
        call.engine.suggestBriefly()

        #expect(
            await call.nothingReachesTheModel(),
            "запрос не имеет права уйти, пока вопрос не распознан: модель не увидела бы его вовсе"
        )

        await call.recognizer.release()
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.count == 1)
        #expect(call.model.requests.first?.userPrompt.contains("Them: а как вы это делали с Postgres") == true)
        #expect(call.engine.suggestions.first?.text == "Скажи про GiST.")
    }

    @Test("Распознавание застряло — по бюджету запрос уходит без опоздавших слов")
    func anOverdueRecognitionLosesItsPlaceInTheRequest() async {
        let call = PressCall(
            model: PressModel(.fragments(["Отвечу по экрану."])),
            recognises: "а как вы это делали с Postgres"
        )

        call.says(.them)
        call.engine.suggestBriefly()

        // Ждём, пока бюджет заведён, и только потом двигаем стрелки: иначе
        // дедлайн отсчитался бы от уже переведённого времени и не наступил бы
        // никогда.
        await call.clock.waitForSleeper()
        call.clock.advance(by: SessionEngine.recognitionBudget)

        #expect(
            await call.modelWasAsked(1),
            "просроченный бюджет не отменяет запрос, а отпускает его"
        )
        #expect(
            call.model.requests.first?.userPrompt.contains(BriefPrompt.emptyTranscriptPlaceholder) == true,
            "слов ещё нет — в промпте подстановка, а не пустая реплика Them"
        )
        #expect(call.engine.suggestions.count == 1)

        // Опоздавшие слова доезжают как обычно — и ничего не запускают.
        await call.recognizer.release()
        await call.engine.waitForSuggestion()

        #expect(
            call.engine.transcript.map(\.text) == ["а как вы это делали с Postgres"],
            "распознавание не отменяется никогда: слова остаются в транскрипте"
        )
        #expect(call.model.requests.count == 1, "опоздавшая реплика не имеет права породить второй запрос")
        #expect(call.engine.suggestions.count == 1)
    }

    @Test("Снимок экрана идёт параллельно ожиданию слов, а не после него")
    func theScreenIsGrabbedBesideTheWait() async {
        let capturer = RecordingCapturer(ScreenContext(text: "main.swift"))
        let call = PressCall(
            model: PressModel(.fragments(["готово"])),
            recognises: "что тут не так",
            capturer: capturer
        )

        call.says(.them)
        call.engine.suggestBriefly()

        #expect(
            await capturer.startedCapturing(),
            "иначе задержки складываются: сначала секунда на распознавание, потом ещё одна на экран"
        )
        #expect(await call.nothingReachesTheModel(), "запрос при этом всё ещё ждёт слов")

        await call.recognizer.release()
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.first?.userPrompt.contains("main.swift") == true)
    }

    @Test("Решение с экрана разговора не читает — и ждать слов не обязано")
    func solveOnScreenNeverWaitsForWords() async {
        let call = PressCall(
            model: PressModel(.fragments(["def two_sum"])),
            recognises: "решите вот это"
        )

        call.says(.them)
        call.engine.solveOnScreen()

        // Распознавание всё ещё держат, а запрос уже ушёл.
        #expect(
            await call.modelWasAsked(1),
            "режим отвечает экрану: ждать распознавания там — чистая задержка в момент, когда она дороже всего"
        )
        #expect(call.model.requests.first?.systemPrompt == SolvePrompt.system)

        await call.recognizer.release()
        await call.engine.waitForSuggestion()
    }

    // MARK: - Дозакрытие реплики Them

    @Test("Нажали, пока собеседник не договорил — хвост в 0.4 с попадает в запрос")
    func aPressClosesTheTailOfTheQuestion() async {
        let call = PressCall(
            model: PressModel(.fragments(["готово"])),
            recognises: "с Postgres",
            holdingRecognition: false
        )

        // Хвост короче минимальной длины реплики и без паузы после него: сам по
        // себе он не закрылся бы, а через обычный флаш был бы уничтожен.
        call.speaks(.them, for: 0.4)
        #expect(call.engine.transcript.isEmpty, "порог паузы ещё не набежал")

        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.count == 1, "нажатие обязано дозакрыть реплику")
        #expect(call.engine.transcript.first?.channel == .them)
        #expect(
            call.model.requests.first?.userPrompt.contains("Them: с Postgres") == true,
            "без дозакрытия последняя фраза вопроса просто не существует в момент сборки промпта"
        )
    }

    @Test("Дозакрытая реплика остаётся в транскрипте, даже если ответ на неё вытеснят")
    func theClosedTailSurvivesASupersededAnswer() async throws {
        let call = PressCall(
            model: PressModel(.manual),
            recognises: "с Postgres",
            holdingRecognition: false
        )

        call.speaks(.them, for: 0.4)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))

        // Передумали и нажали ещё раз.
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))

        #expect(call.engine.transcript.map(\.text) == ["с Postgres"], "слова не зависят от судьбы подсказки")
        #expect(call.engine.suggestions[0].state == .superseded)

        call.model.finish(1)
        await call.engine.waitForSuggestion()
    }

    @Test("Модель не настроена — хвост вопроса всё равно дозакрывается")
    func theTailIsClosedEvenWithNothingToAnswerWith() async {
        let call = PressCall(
            model: PressModel(.fragments(["готово"])),
            recognises: "с Postgres",
            holdingRecognition: false,
            withProvider: false
        )

        call.speaks(.them, for: 0.4)
        call.engine.suggestBriefly()
        await call.engine.waitForRecognition()

        #expect(
            call.engine.transcript.map(\.text) == ["с Postgres"],
            "реплика — факт о разговоре: она не зависит от того, есть ли чем на неё отвечать"
        )
        #expect(call.model.requests.isEmpty)
        #expect(
            call.engine.suggestions.map(\.state) == [.failed(LLMFailure.missingKey.message)],
            "молчание в ответ на нажатие читается как сломанное приложение"
        )
    }

    @Test("Нажали, когда никто не говорит — ничего не ломается и запрос уходит")
    func aPressWithNothingOpenStillWorks() async {
        let call = PressCall(
            model: PressModel(.fragments(["готово"])),
            recognises: "не должно распознаваться",
            holdingRecognition: false
        )

        call.silenceLasts(1.6, on: .them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.isEmpty, "тишина репликой не становится и по нажатию")
        #expect(call.model.requests.count == 1)
        #expect(call.engine.suggestions.count == 1)
    }

    @Test("Полуфраза You доезжает до модели: жанр «коротко» весь на ней держится")
    func thePressClosesTheUserSOwnHalfPhraseToo() async {
        let call = PressCall(
            model: PressModel(.fragments(["готово"])),
            recognises: "я обычно делаю это так",
            holdingRecognition: false
        )

        // Пользователь уже отвечает вслух — именно поэтому он и жмёт: он
        // говорит и не может вспомнить недостающее.
        call.speaks(.you, for: 0.4)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        // Ровно это и просит промпт: «он уже начал отвечать — дай недостающее,
        // а не ответ с начала». Без строки You модель угадывает, на каком месте
        // фразы её прервали, и выдаёт то, что человек уже произнёс сам.
        #expect(
            call.model.requests.first?.userPrompt.contains("You: я обычно делаю это так") == true,
            "модели сказано, что пользователь уже говорит, — она обязана видеть, чем именно"
        )

        // И слова не потеряны: 0.4 с короче `minimumTurnDuration`, то есть
        // обычное закрытие выбросило бы эту реплику вместе с сэмплами.
        #expect(call.engine.transcript.count == 1)
        #expect(call.engine.transcript.first?.channel == .you)
        #expect(call.engine.transcript.first?.text == "я обычно делаю это так")

        // Но запускать она по-прежнему ничего не имеет права: речь пользователя
        // не вопрос, и запрос здесь ровно один — тот, который он попросил.
        #expect(call.model.requests.count == 1)
        #expect(call.engine.suggestions.count == 1)
    }

    // MARK: - Обратная связь на нажатие

    @Test("Пока запрос готовится, окно говорит, что нажатие принято")
    func theWindowSaysThePressWasTaken() async {
        let call = PressCall(
            model: PressModel(.fragments(["готово"])),
            recognises: "а как вы это делали с Postgres"
        )

        call.says(.them)
        #expect(call.engine.isPreparingAnswer == false)

        call.engine.suggestBriefly()

        #expect(
            call.engine.isPreparingAnswer,
            "секунда тишины после нажатия читается как «не нажалось» — и пользователь жмёт второй раз"
        )
        let preparing = SessionIndicators.make(
            isListening: true,
            failure: nil,
            recognition: .ready,
            themStatus: .capturing(application: "Google Chrome"),
            isPreparingAnswer: true,
            isGenerating: false,
            suggestionFailure: nil
        )
        #expect(preparing.model.state == .waiting)
        #expect(preparing.model.detail.contains("Нажатие принято"))
        #expect(preparing.them.state == .listening, "подготовка ответа — не состояние захвата")

        // Точки мало: 7×7 pt и подсказка при наведении мыши — не то, что ловят
        // боковым зрением, глядя на интервьюера. Пояснение обязано быть словами
        // в окне, иначе второе нажатие вытеснит первое и удвоит ожидание.
        #expect(preparing.preparationNotice == preparing.model.detail)

        let answering = SessionIndicators.make(
            isListening: true,
            failure: nil,
            recognition: .ready,
            themStatus: .capturing(application: "Google Chrome"),
            isPreparingAnswer: false,
            isGenerating: true,
            suggestionFailure: nil
        )
        #expect(
            answering.preparationNotice == nil,
            "пошёл ответ — объяснять нечего, текст в ленте говорит сам за себя"
        )

        let failed = SessionIndicators.make(
            isListening: true,
            failure: nil,
            recognition: .ready,
            themStatus: .capturing(application: "Google Chrome"),
            isPreparingAnswer: false,
            isGenerating: false,
            suggestionFailure: "Ключ не задан."
        )
        #expect(
            failed.preparationNotice == nil,
            "отказ уже приезжает карточкой в ленту — сказанный дважды, он станет шумом"
        )

        await call.recognizer.release()
        await call.engine.waitForSuggestion()

        #expect(call.engine.isPreparingAnswer == false, "подготовка кончилась, когда пошёл ответ")
    }

    @Test("Повторное нажатие вытесняет предыдущий ответ, а не запускает второй параллельно")
    func asecondPressSupersedesTheFirstAnswer() async throws {
        let call = PressCall(
            model: PressModel(.manual),
            recognises: "расскажите про индексы",
            holdingRecognition: false
        )

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.model.emit("Индекс — это ", into: 0)
        #expect(await call.textOfLatestReaches("Индекс — это "))

        call.engine.suggestInDetail()
        try #require(await call.modelWasAsked(2))

        #expect(
            await call.model.streamWasCancelled(0),
            "вытесненный запрос обязан оборваться на проводе, а не досчитываться в фоне"
        )
        #expect(call.engine.suggestions.count == 2)
        #expect(call.engine.suggestions[0].state == .superseded)
        #expect(
            call.engine.suggestions[0].text == "Индекс — это ",
            "написанное остаётся в ленте: пользователь мог начать это читать"
        )
        #expect(call.engine.suggestions[1].state == .streaming)

        call.model.finish(1)
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[1].state == .complete)
    }
}

// MARK: - Обстановка звонка

/// A call where the test decides when speech recognition finishes, when the
/// screen comes back, and when the clock moves.
///
/// Recognition is held by default: everything this suite is about happens in the
/// window between a press and the words being ready, and with a recogniser that
/// answers instantly that window does not exist.
@MainActor
private struct PressCall {
    let engine: SessionEngine
    let model: PressModel
    let recognizer: HeldRecognizer
    let clock: ManualClock

    private let frameLength: TimeInterval = 0.1

    init(
        model: PressModel,
        recognises reply: String = "",
        holdingRecognition: Bool = true,
        capturer: (any ScreenCapturer)? = nil,
        withProvider: Bool = true
    ) {
        let clock = ManualClock()
        let recognizer = HeldRecognizer(reply: reply, holding: holdingRecognition)
        self.clock = clock
        self.model = model
        self.recognizer = recognizer
        self.engine = SessionEngine(
            recognizer: recognizer,
            // The double is still handed to the test even when the engine has no
            // provider: what is checked then is that nothing reached it.
            provider: withProvider ? model : nil,
            composer: PromptComposer(profile: { .empty }),
            capturer: capturer ?? NoScreenCapturer(),
            clock: clock
        )
    }

    /// A whole turn: someone talks, then stops long enough for the turn to close.
    func says(_ channel: Channel, for seconds: TimeInterval = 1.2) {
        speaks(channel, for: seconds)
        silenceLasts(TurnSegmentationConfig.default.pauseThreshold + 0.2, on: channel)
    }

    /// Speech that is not followed by a pause — the turn stays open.
    func speaks(_ channel: Channel, for seconds: TimeInterval) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
    }

    func silenceLasts(_ seconds: TimeInterval, on channel: Channel) {
        feed(seconds: seconds) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    func textOfLatestReaches(_ text: String, within timeout: Duration = TestWait.budget) async -> Bool {
        await settling(within: timeout) { engine.suggestions.last?.text == text }
    }

    func modelWasAsked(_ count: Int, within timeout: Duration = TestWait.budget) async -> Bool {
        await settling(within: timeout) { model.requests.count == count }
    }

    /// Gives the pipeline every chance to send a request, and reports that it did
    /// not. A negative check needs a deadline of its own: passing instantly would
    /// prove only that nothing had happened yet.
    func nothingReachesTheModel(within timeout: Duration = .milliseconds(80)) async -> Bool {
        let asked = await settling(within: timeout) { !model.requests.isEmpty }
        return !asked
    }

    private func feed(seconds: TimeInterval, frame: () -> AudioFrame) {
        let frames = Int((seconds / frameLength).rounded())
        for _ in 0..<frames {
            clock.advance(by: frameLength)
            engine.ingest(frame())
        }
    }
}

/// Waits for something that lands on a later turn of the main actor.
@MainActor
private func settling(within timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

// MARK: - Распознавание

/// Recognition that does not finish until the test lets it.
private actor HeldRecognizer: SpeechRecognizer {

    private let reply: String
    private var holding: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(reply: String, holding: Bool) {
        self.reply = reply
        self.holding = holding
    }

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        if holding {
            await withCheckedContinuation { waiting.append($0) }
        }
        return reply
    }

    /// Lets the held passes finish.
    func release() {
        holding = false
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

// MARK: - Экран

/// A screen that answers at once and remembers being asked.
private final class RecordingCapturer: ScreenCapturer, @unchecked Sendable {

    private let lock = NSLock()
    private let stored: ScreenContext
    private var asked = false

    init(_ context: ScreenContext) {
        stored = context
    }

    func capture() async -> ScreenContext {
        lock.withLock { asked = true }
        return stored
    }

    @MainActor
    func startedCapturing(within timeout: Duration = TestWait.budget) async -> Bool {
        await settling(within: timeout) { self.lock.withLock { self.asked } }
    }
}

// MARK: - Модель-заглушка

/// A model that answers from a script, remembers what it was asked, and reports
/// which of its streams were terminated by cancellation.
private final class PressModel: LLMProvider, @unchecked Sendable {

    enum Script {
        /// Yields every fragment, then finishes.
        case fragments([String])
        /// The test yields the fragments by hand.
        case manual
    }

    let name = "Заглушка"
    let capabilities = ProviderCapabilities.multimodal

    private let lock = NSLock()
    private let script: Script
    private var recorded: [SuggestionRequest] = []
    private var streams: [AsyncThrowingStream<String, any Error>.Continuation] = []
    private var cancelled: Set<Int> = []

    init(_ script: Script) {
        self.script = script
    }

    /// Requests that actually reached the model, in order.
    var requests: [SuggestionRequest] {
        lock.withLock { recorded }
    }

    /// Streams the consumer abandoned, by their position in `requests`.
    var cancelledStreams: Set<Int> {
        lock.withLock { cancelled }
    }

    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error> {
        let index = lock.withLock { () -> Int in
            recorded.append(request)
            return recorded.count - 1
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { streams.append(continuation) }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.markCancelled(index)
            }
            switch script {
            case .fragments(let parts):
                for part in parts { continuation.yield(part) }
                continuation.finish()
            case .manual:
                break
            }
        }
    }

    func emit(_ fragment: String, into index: Int) {
        continuation(index)?.yield(fragment)
    }

    func finish(_ index: Int) {
        continuation(index)?.finish()
    }

    @MainActor
    func streamWasCancelled(_ index: Int, within timeout: Duration = TestWait.budget) async -> Bool {
        await settling(within: timeout) { self.cancelledStreams.contains(index) }
    }

    private func continuation(_ index: Int) -> AsyncThrowingStream<String, any Error>.Continuation? {
        lock.withLock { streams.indices.contains(index) ? streams[index] : nil }
    }

    private func markCancelled(_ index: Int) {
        lock.withLock { _ = cancelled.insert(index) }
    }
}
