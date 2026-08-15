//
//  SuggestionLifecycleTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// What happens to a suggestion when the call moves on while it is being written.
///
/// Since ADR-0008 exactly one thing supersedes an answer: **another press.** The
/// interlocutor's next question does not — the user asked for this answer and may
/// still be reading it — and the user's own speech never did.
///
/// The scenario most of these are built around: the interviewer says «Расскажите
/// про…», pauses long enough for the turn to close, and finishes «…ваш опыт с
/// шардированием». Both halves are in the transcript by the time the candidate
/// presses, and the request goes out on the whole question.
///
/// Cancellation is checked by what the doubles can observe — a stream terminated
/// by cancellation, a screen capture that never got to run its text recognition —
/// and never by a flag the engine sets about itself.
@Suite("Жизненный цикл подсказки")
@MainActor
struct SuggestionLifecycleTests {

    // MARK: - Нажатие во время генерации

    @Test("Нажали ещё раз — предыдущий ответ перестаёт расти, но остаётся на экране")
    func aSecondPressSupersedesTheAnswerInFlight() async throws {
        let call = LifecycleCall(
            model: ScriptedModel(.manual),
            recognises: ["расскажите про", "ваш опыт с шардированием"]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.model.emit("Шардирование — это ", into: 0)
        #expect(await call.textOfLatestReaches("Шардирование — это "))

        // Пауза кончилась не потому, что вопрос кончился: собеседник договорил,
        // и пользователь нажал заново.
        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))

        #expect(
            await call.model.streamWasCancelled(0),
            "отменённый запрос обязан оборваться на проводе, а не досчитываться в фоне"
        )
        #expect(call.engine.suggestions.count == 2, "новое нажатие обязано запустить новую генерацию")
        #expect(call.engine.suggestions[0].state == .superseded)
        #expect(
            call.engine.suggestions[0].text == "Шардирование — это ",
            "написанное остаётся в ленте: пользователь мог начать это читать"
        )
        #expect(call.engine.suggestions[1].state == .streaming)

        let question = call.model.requests.last?.userPrompt ?? ""
        #expect(question.contains("расскажите про"))
        #expect(question.contains("ваш опыт с шардированием"), "новый запрос уходит на полном вопросе")

        call.model.finish(1)
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[1].state == .complete)
    }

    @Test("Первая половина ещё распознаётся — запрос ждёт её, а не уходит на огрызке вопроса")
    func theRequestWaitsForTheHalfStillBeingRecognised() async {
        // Распознавание первой реплики держится: если запрос уйдёт без неё, в
        // промпте окажется пустая реплика Them вместо начала вопроса.
        let call = LifecycleCall(
            model: ScriptedModel(.fragments(["Отвечу ", "по шардированию."])),
            recognises: ["расскажите про", "ваш опыт с шардированием"],
            holdingFirst: 1
        )

        call.says(.them)
        call.says(.them)
        call.engine.suggestBriefly()
        #expect(await call.nothingReachesTheModel(), "запрос не имеет права уйти, пока вопрос распознан наполовину")

        await call.recognizer.release()
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.count == 1, "нажатие было одно — и запрос один")
        let question = call.model.requests.first?.userPrompt ?? ""
        #expect(question.contains("расскажите про"))
        #expect(question.contains("ваш опыт с шардированием"))
        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].state == .complete)
    }

    @Test("Вытесненную подсказку не дописывают: отменённый поток больше не растит её")
    func aCancelledStreamNeverAppendsAgain() async throws {
        let call = LifecycleCall(
            model: ScriptedModel(.manual),
            recognises: ["первая половина", "вторая половина"]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.model.emit("Половина ответа", into: 0)
        #expect(await call.textOfLatestReaches("Половина ответа"))

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))
        #expect(await call.model.streamWasCancelled(0))

        // Провайдер, не заметивший отмены, продолжает писать в старый поток.
        call.model.emit(" и ещё немного", into: 0)
        call.model.finish(0)
        await call.letThingsLand()

        #expect(
            call.engine.suggestions[0].text == "Половина ответа",
            "дописанное после отмены — это ответ на вопрос, который уже не задан"
        )
        #expect(
            call.engine.suggestions[0].state == .superseded,
            "досчитавшийся поток не имеет права объявить вытесненную подсказку законченной"
        )

        call.model.finish(1)
        await call.engine.waitForSuggestion()
    }

    @Test("Нажали ещё раз — начатый снимок экрана отменяется, а не досчитывается")
    func supersedingCancelsTheScreenshotToo() async {
        let capturer = HeldScreenCapturer()
        let call = LifecycleCall(
            model: ScriptedModel(.fragments(["готово"])),
            recognises: ["расскажите про", "ваш опыт с шардированием"],
            capturer: capturer
        )

        call.says(.them)
        call.engine.suggestBriefly()
        #expect(await capturer.startedCapturing(), "снимок обязан начаться сразу по нажатию")

        call.engine.suggestBriefly()

        #expect(
            await capturer.wasCancelled(),
            "вытесненное нажатие иначе тратит лишний кадр и ~200 мс распознавания текста впустую"
        )

        await call.engine.waitForSuggestion()
        #expect(call.model.requests.count == 1, "запрос уходит только на актуальное нажатие")
        #expect(
            call.engine.suggestions.count == 1,
            "первое нажатие не дошло до генерации — карточки у него нет, и вытеснять в ленте было нечего"
        )
        #expect(call.engine.suggestions[0].state == .complete)
    }

    // MARK: - Реплика Them после ответа

    @Test("Собеседник задал следующий вопрос — законченный ответ остаётся в ленте как есть")
    func aThemTurnAfterTheAnswerLeavesItFinished() async {
        let call = LifecycleCall(
            model: ScriptedModel(.fragments(["Отвечу ", "коротко."])),
            recognises: ["первый вопрос", "второй вопрос"]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[0].state == .complete)

        call.says(.them)
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 1, "реплика Them больше ничего не запускает")
        #expect(
            call.engine.suggestions[0].state == .complete,
            "законченный ответ не переписывается в superseded — отменять было нечего"
        )
        #expect(call.engine.suggestions[0].text == "Отвечу коротко.")
        #expect(call.model.cancelledStreams.isEmpty)
    }

    @Test("Собеседник заговорил, пока модель пишет — подсказка не отменяется")
    func aThemTurnDuringGenerationCancelsNothing() async throws {
        let call = LifecycleCall(
            model: ScriptedModel(.manual),
            recognises: ["чем транзакция отличается от блокировки", "и ещё вопрос"]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.model.emit("Транзакция ", into: 0)
        #expect(await call.textOfLatestReaches("Транзакция "))

        // Собеседник добавляет что-то, пока ответ пишется. Пользователь просил
        // именно этот ответ и, возможно, дочитывает его.
        call.says(.them)
        await call.engine.waitForRecognition()

        #expect(call.model.cancelledStreams.isEmpty, "реплика Them больше ничего не отменяет")
        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].state == .streaming)
        #expect(call.engine.transcript.count == 2, "слова при этом пишутся как обычно")

        call.model.finish(0)
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[0].state == .complete)
    }

    // MARK: - Реплика You

    @Test("Пользователь заговорил, пока модель пишет — подсказка дописывается до конца")
    func aYouTurnDuringGenerationCancelsNothing() async throws {
        let call = LifecycleCall(
            model: ScriptedModel(.manual),
            recognises: ["чем транзакция отличается от блокировки", "сейчас расскажу"]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.model.emit("Транзакция ", into: 0)
        #expect(await call.textOfLatestReaches("Транзакция "))

        // Пользователь начал отвечать вслух — подсказка ему нужна именно сейчас.
        call.says(.you)
        await call.engine.waitForRecognition()

        #expect(call.model.cancelledStreams.isEmpty, "собственная речь не имеет права обрывать генерацию")
        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].state == .streaming)

        call.model.emit("— это единица работы.", into: 0)
        #expect(
            await call.textOfLatestReaches("Транзакция — это единица работы."),
            "поток жив: подсказка продолжает расти под ответ пользователя"
        )

        call.model.finish(0)
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[0].state == .complete)
        #expect(call.model.requests.count == 1)
    }

    @Test("Пользователь договорил после ответа — шпаргалка остаётся на экране нетронутой")
    func aYouTurnAfterTheAnswerChangesNothing() async {
        let call = LifecycleCall(
            model: ScriptedModel(.fragments(["Скажи, что ", "мигрировал схему."])),
            recognises: ["расскажите про базы", "я мигрировал схему на живой базе"]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        call.says(.you)
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.map(\.channel) == [.them, .you])
        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].state == .complete)
        #expect(
            call.engine.suggestions[0].text == "Скажи, что мигрировал схему.",
            "подсказка живёт до следующего нажатия, а не до конца собственного ответа"
        )
        #expect(call.model.requests.count == 1)
        #expect(call.model.cancelledStreams.isEmpty)
    }

    // MARK: - Транскрипт переживает отмену

    @Test("Отмена забирает ответ, но не слова: обе половины вопроса остаются в транскрипте")
    func supersedingKeepsTheTranscript() async throws {
        let call = LifecycleCall(
            model: ScriptedModel(.manual),
            recognises: ["расскажите про", "ваш опыт с шардированием"]
        )

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))

        #expect(call.engine.transcript.count == 2)
        #expect(
            Set(call.engine.transcript.map(\.text)) == ["расскажите про", "ваш опыт с шардированием"],
            "распознавание вытесненного нажатия не отменяется — иначе половина вопроса пропадёт навсегда"
        )

        call.model.finish(1)
        await call.engine.waitForSuggestion()
    }
}

// MARK: - Обстановка звонка

/// A call whose model, recognition and screen are all doubles.
///
/// Same shape as `SuggestionCall` in the trigger suite, with the two things this
/// suite needs added: recognition that answers differently for each turn (so "the
/// request went out on the whole question" is checkable at all), and a model that
/// reports which of its streams were terminated by cancellation.
@MainActor
private struct LifecycleCall {
    let engine: SessionEngine
    let model: ScriptedModel
    let recognizer: ScriptedRecognizer

    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(
        model: ScriptedModel,
        recognises replies: [String],
        holdingFirst held: Int = 0,
        capturer: (any ScreenCapturer)? = nil
    ) {
        let clock = ManualClock()
        let recognizer = ScriptedRecognizer(replies, holdingFirst: held)
        self.clock = clock
        self.model = model
        self.recognizer = recognizer
        self.engine = SessionEngine(
            recognizer: recognizer,
            provider: model,
            composer: PromptComposer(profile: { .empty }),
            // The screen is not what most of these are about, and a real
            // screenshot would put a display server and a TCC grant between the
            // test and the answer. `supersedingCancelsTheScreenshotToo` brings
            // its own.
            capturer: capturer ?? NoScreenCapturer(),
            clock: clock
        )
    }

    /// A whole turn of one channel: someone talks, then stops long enough for the
    /// turn to close.
    func says(_ channel: Channel, for seconds: TimeInterval = 1.2) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
        feed(seconds: TurnSegmentationConfig.default.pauseThreshold + 0.2) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    /// Waits until the newest suggestion has grown to `text`.
    ///
    /// Fragments cross a task boundary, so they land a hop later rather than
    /// instantly; the loop is bounded so a stalled stream fails the test instead
    /// of hanging it.
    func textOfLatestReaches(_ text: String, within timeout: Duration = TestWait.budget) async -> Bool {
        await eventually(within: timeout) { engine.suggestions.last?.text == text }
    }

    /// Waits until the model has been asked `count` times. A press waits for the
    /// words and the screen first, so the request lands a hop later.
    func modelWasAsked(_ count: Int, within timeout: Duration = TestWait.budget) async -> Bool {
        await eventually(within: timeout) { model.requests.count == count }
    }

    /// Gives the pipeline every chance to send a request, and reports that it did
    /// not. A negative check needs a deadline of its own: passing instantly would
    /// prove only that nothing had happened yet.
    func nothingReachesTheModel(within timeout: Duration = .milliseconds(80)) async -> Bool {
        let asked = await eventually(within: timeout) { !model.requests.isEmpty }
        return !asked
    }

    /// Lets whatever was already in flight finish landing, for the assertions
    /// that are about something *not* appearing.
    func letThingsLand() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
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
private func eventually(within timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

// MARK: - Распознавание

/// Recognition that answers with a different line for each turn, in order, and
/// can be made to hold the first passes until the test lets them through.
///
/// Different lines per turn are the point: with one canned reply for everything,
/// "the request went out on the whole question" would be unprovable.
private actor ScriptedRecognizer: SpeechRecognizer {

    private let replies: [String]
    private let held: Int
    private var started = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ replies: [String], holdingFirst held: Int = 0) {
        self.replies = replies
        self.held = held
    }

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        let position = started
        started += 1
        if position < held, !released {
            await withCheckedContinuation { waiting.append($0) }
        }
        return position < replies.count ? replies[position] : ""
    }

    /// Lets the held passes finish.
    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

// MARK: - Экран

/// A capture that does not come back until it is cancelled — and says so.
///
/// Only the first capture is held: the press that superseded it needs a screen of
/// its own, and holding that one too would deadlock the test rather than fail it.
private final class HeldScreenCapturer: ScreenCapturer, @unchecked Sendable {

    private let lock = NSLock()
    private var started = 0
    private var cancelled = 0

    func capture() async -> ScreenContext {
        let first = lock.withLock {
            started += 1
            return started == 1
        }
        guard first else { return ScreenContext(text: "второй экран") }

        while !Task.isCancelled {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        lock.withLock { cancelled += 1 }
        return .none
    }

    /// Whether the engine has already asked for the screen.
    @MainActor
    func startedCapturing(within timeout: Duration = TestWait.budget) async -> Bool {
        await eventually(within: timeout) { self.lock.withLock { self.started > 0 } }
    }

    /// Whether the held capture was cut short — the observable half of "the
    /// screenshot really was abandoned".
    @MainActor
    func wasCancelled(within timeout: Duration = TestWait.budget) async -> Bool {
        await eventually(within: timeout) { self.lock.withLock { self.cancelled > 0 } }
    }
}

// MARK: - Модель-заглушка

/// A model that answers from a script, remembers what it was asked, and reports
/// which of its streams were terminated by cancellation.
///
/// That last part is what makes "the request was really dropped" checkable
/// without a socket — the same trick the provider suites use on their transports.
private final class ScriptedModel: LLMProvider, @unchecked Sendable {

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

    /// Writes one more fragment into the n-th answer the model was asked for.
    func emit(_ fragment: String, into index: Int) {
        continuation(index)?.yield(fragment)
    }

    /// The model finished writing the n-th answer.
    func finish(_ index: Int) {
        continuation(index)?.finish()
    }

    /// Whether the n-th stream was terminated by its consumer rather than by the
    /// answer ending.
    @MainActor
    func streamWasCancelled(_ index: Int, within timeout: Duration = TestWait.budget) async -> Bool {
        await eventually(within: timeout) { self.cancelledStreams.contains(index) }
    }

    private func continuation(_ index: Int) -> AsyncThrowingStream<String, any Error>.Continuation? {
        lock.withLock { streams.indices.contains(index) ? streams[index] : nil }
    }

    private func markCancelled(_ index: Int) {
        lock.withLock { _ = cancelled.insert(index) }
    }
}
