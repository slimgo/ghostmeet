//
//  SuggestionTriggerTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// What starts a suggestion, and what deliberately does not.
///
/// Since ADR-0008 the answer is: a press, and nothing else. The interlocutor can
/// ask a whole question and fall silent — it lands in the transcript and asks the
/// model for nothing, because the candidate knows most of the answers and the
/// suggestion is for the minority they do not.
///
/// What is checked is what the user would see in the window: whether a suggestion
/// showed up at all, what text grew in it, and what it said when nothing could be
/// produced. The model is a stub: none of these tests reach a network.
@Suite("Запуск подсказки нажатием")
@MainActor
struct SuggestionTriggerTests {

    // MARK: - Что запускает подсказку

    @Test("Пользователь нажал — подсказка запустилась")
    func aPressStartsTheSuggestion() async {
        let call = SuggestionCall(
            provider: StubLLMProvider(.fragments(["Расскажу ", "про миграцию."])),
            recognisesAs: "расскажите про ваш опыт"
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 1, "нажатие должно было запустить подсказку")
        #expect(call.engine.suggestions.first?.text == "Расскажу про миграцию.")
        #expect(call.engine.suggestions.first?.state == .complete)
        #expect(call.provider.requests.count == 1, "к модели должен был уйти ровно один запрос")
    }

    @Test("Собеседник договорил и замолчал — сам по себе запрос не уходит")
    func aClosedThemTurnAsksForNothing() async {
        let call = SuggestionCall(
            provider: StubLLMProvider(),
            recognisesAs: "расскажите про ваш опыт"
        )

        call.says(.them)
        await call.engine.waitForSuggestion()

        #expect(
            call.engine.transcript.map(\.channel) == [.them],
            "реплика обязана попасть в транскрипт: распознавание работает без нажатий"
        )
        #expect(call.engine.transcript.first?.text == "расскажите про ваш опыт")
        #expect(call.engine.suggestions.isEmpty, "закрытая реплика Them больше ничего не запускает")
        #expect(call.provider.requests.isEmpty, "к модели не должно было уйти ничего")
    }

    @Test("Реплику договорил сам пользователь — тоже ничего не запускается")
    func aYouTurnStartsNothing() async {
        let call = SuggestionCall(
            provider: StubLLMProvider(),
            recognisesAs: "я работал в основном с бэкендом"
        )

        call.says(.you)
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.map(\.channel) == [.you], "реплика должна была попасть в транскрипт")
        #expect(call.engine.suggestions.isEmpty)
        #expect(call.provider.requests.isEmpty)
    }

    @Test("Разговор идёт, нажатие одно — подсказка ровно одна")
    func onlyPressesAskForSuggestions() async {
        let call = SuggestionCall(provider: StubLLMProvider(), recognisesAs: "ага")

        call.says(.you)
        call.says(.them)
        call.says(.you)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.map(\.channel) == [.you, .them, .you])
        #expect(call.engine.suggestions.count == 1, "три реплики и одно нажатие — это одна подсказка")
        #expect(call.provider.requests.count == 1)
    }

    // MARK: - Два нажатия подряд

    /// Прогон нашёл это первым же действием: интервьюер задал вопрос, нажали
    /// «подробно», интервьюер задал следующий, нажали «коротко» — и ответ пришёл
    /// на предыдущий вопрос.
    /// Живой прогон: пользователь видел в окне правильный вопрос, нажал — и
    /// получил ответ на предыдущий. Захват и распознавание были ни при чём.
    /// Склейка соединяла два вопроса в одну строку `Them:`, а промпт про такую
    /// строку говорит, что это «один человек и одна мысль», — модель отвечала
    /// на начало склейки.
    @Test("Два вопроса подряд не склеиваются в один, если между ними было нажатие")
    func aPressBreaksTheMerge() async throws {
        let provider = StubLLMProvider(.fragments(["ответ"]))
        let call = SuggestionCall(
            provider: provider,
            recognisesInOrder: ["Расскажите про event loop.", "А чем any отличается от unknown?"]
        )
        call.listen()

        call.says(.them)
        call.engine.suggestInDetail()
        try #require(await call.modelWasAsked(1))

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))

        let lines = provider.requests[1].userPrompt
            .split(separator: "\n")
            .filter { $0.hasPrefix("Them: ") }
        #expect(lines.count == 2, "вопросы склеились в одну строку: \(lines)")
        #expect(lines.last?.contains("any отличается от unknown") == true)
    }

    @Test("Текущий вопрос назван отдельной строкой — гадать модели не приходится")
    func theCurrentQuestionIsNamed() async throws {
        let provider = StubLLMProvider(.fragments(["ответ"]))
        let call = SuggestionCall(
            provider: provider,
            recognisesInOrder: ["Расскажите про event loop.", "А чем any отличается от unknown?"]
        )
        call.listen()

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))

        #expect(provider.requests[1].userPrompt.contains("Сейчас он спросил: «А чем any отличается от unknown?»"))
        #expect(provider.requests[0].userPrompt.contains("Сейчас он спросил: «Расскажите про event loop.»"))
    }

    @Test("Собеседник ещё не сказал ничего — строки про текущий вопрос нет вовсе")
    func noQuestionMeansNoLine() async throws {
        let provider = StubLLMProvider(.fragments(["ответ"]))
        let call = SuggestionCall(provider: provider, recognisesAs: "мои слова")
        call.listen()

        call.says(.you)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))

        #expect(!provider.requests[0].userPrompt.contains("Сейчас он спросил"))
    }

    @Test("Второе нажатие отвечает на второй вопрос, а не на первый")
    func aSecondPressAnswersTheSecondQuestion() async throws {
        let provider = StubLLMProvider(.fragments(["ответ"]))
        let call = SuggestionCall(
            provider: provider,
            recognisesInOrder: ["Что такое B-tree?", "Чем GiST отличается от GIN?"]
        )

        call.says(.them)
        call.engine.suggestInDetail()
        try #require(await call.modelWasAsked(1))

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))

        let second = provider.requests[1].userPrompt
        #expect(second.contains("Чем GiST отличается от GIN?"), "второй вопрос не доехал: \(second)")
        #expect(provider.requests[0].userPrompt.contains("Что такое B-tree?"))
    }

    /// Найдено первым же живым прогоном и было молчаливым: распознавание
    /// последней реплики не уложилось в бюджет, запрос ушёл без неё, и модель
    /// ответила на предыдущий вопрос. Ответ выглядел обычным — связным и по
    /// теме, просто не про то, что спросили секунду назад.
    @Test("Слова не успели распознаться — запрос уходит, но об этом сказано")
    func aLateRecognitionIsAnnounced() async throws {
        let provider = StubLLMProvider(.fragments(["ответ"]))
        let call = SuggestionCall(
            provider: provider,
            recognizer: StallingRecognizer(replies: ["Что такое B-tree?"], stallsAt: 2)
        )
        call.listen()

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))

        call.says(.them)
        call.engine.suggestBriefly()
        await call.waitOutRecognitionBudget()
        try #require(await call.modelWasAsked(2))

        let notice = call.engine.suggestions.last?.notice
        #expect(notice?.contains("ещё распознавались") == true, "молчать об этом нельзя")
    }

    @Test("Все слова успели — лишней строки над ответом нет")
    func aTimelyRecognitionSaysNothing() async throws {
        let provider = StubLLMProvider(.fragments(["ответ"]))
        let call = SuggestionCall(provider: provider, recognisesAs: "Что такое B-tree?")
        call.listen()

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))

        #expect(call.engine.suggestions.last?.notice == nil)
    }

    // MARK: - Оборванный ответ

    /// Пока приложение этого не умело, оборванная на полуслове подсказка
    /// выглядела на карточке ровно как короткая — и разницу пользователь узнавал,
    /// уже произнося половину фразы вслух.
    @Test("Ответ оборвался — текст остаётся, а причина стоит под ним")
    func aCutAnswerKeepsItsTextAndSaysWhy() async throws {
        let provider = StubLLMProvider(.manual)
        let call = SuggestionCall(provider: provider, recognisesAs: "что такое B-tree")

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        provider.emit("Я бы взял составной индекс по статусу и дате, ")
        provider.cut(.connection)
        await call.engine.waitForSuggestion()

        let suggestion = call.engine.suggestions.last
        #expect(suggestion?.text == "Я бы взял составной индекс по статусу и дате, ")
        #expect(suggestion?.state == .cut(SuggestionCutoff.connection.message))
    }

    @Test("Обрыв по бюджету — это не отказ: подсказка не помечается как несостоявшаяся")
    func aBudgetCutIsNotAFailure() async throws {
        let provider = StubLLMProvider(.manual)
        let call = SuggestionCall(provider: provider, recognisesAs: "что такое B-tree")

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        provider.emit("Половина ответа")
        provider.cut(.budget)
        await call.engine.waitForSuggestion()

        let state = call.engine.suggestions.last?.state
        #expect(state == .cut(SuggestionCutoff.budget.message))
        if case .failed = state { Issue.record("обрыв по бюджету не должен быть отказом") }
    }

    @Test("Модель не сказала ни слова — сказано, что ответ пуст, а не пустая карточка")
    func anEmptyAnswerIsExplained() async throws {
        let provider = StubLLMProvider(.manual)
        let call = SuggestionCall(provider: provider, recognisesAs: "что такое B-tree")

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        provider.cut(.empty)
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.last?.text.isEmpty == true)
        #expect(call.engine.suggestions.last?.state == .cut(SuggestionCutoff.empty.message))
    }

    // MARK: - Два жанра

    @Test("Коротко и подробно — это разные промпты и разные бюджеты")
    func theTwoGenresDifferInPromptAndBudget() async {
        let call = SuggestionCall(provider: StubLLMProvider(), recognisesAs: "что такое B-tree")

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()
        call.engine.suggestInDetail()
        await call.engine.waitForSuggestion()

        #expect(call.provider.requests.count == 2)
        let brief = call.provider.requests[0]
        let detailed = call.provider.requests[1]

        // Сказал только собеседник — значит, редакция «вслух он ещё ничего не сказал».
        #expect(brief.systemPrompt == BriefPrompt.system(profile: .empty, hasStartedAnswering: false))
        #expect(brief.maxTokens == BriefPrompt.maxTokens)
        #expect(detailed.systemPrompt == AssistPrompt.system(profile: .empty))
        #expect(detailed.maxTokens == AssistPrompt.maxTokens)
        #expect(
            brief.maxTokens < detailed.maxTokens,
            "короткий жанр — это не обрезанный развёрнутый, у него свой потолок"
        )
        #expect(
            brief.userPrompt.contains("Them: что такое B-tree"),
            "оба жанра отвечают на один и тот же разговор"
        )
        #expect(detailed.userPrompt.contains("Them: что такое B-tree"))
    }

    // MARK: - Стриминг

    @Test("Ответ печатается по мере генерации, а не появляется целиком в конце")
    func fragmentsArriveOneByOne() async throws {
        let provider = StubLLMProvider(.manual)
        let call = SuggestionCall(provider: provider, recognisesAs: "оцените сложность решения")

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))

        #expect(call.engine.suggestions.count == 1, "подсказка должна появиться до первого фрагмента")
        #expect(call.engine.suggestions.first?.text.isEmpty == true)
        #expect(call.engine.suggestions.first?.state == .streaming)

        provider.emit("Сейчас это ")
        #expect(await call.textOfLatestReaches("Сейчас это "), "первый фрагмент должен быть виден сразу")
        #expect(call.engine.suggestions.first?.state == .streaming, "подсказка ещё пишется")

        provider.emit("O(n²).")
        #expect(await call.textOfLatestReaches("Сейчас это O(n²)."), "второй фрагмент дописывается к первому")

        provider.finish()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.first?.state == .complete)
        #expect(call.engine.suggestions.first?.text == "Сейчас это O(n²).")
    }

    // MARK: - Ошибки

    @Test("Провайдер отказал — это состояние подсказки, а не падение сессии")
    func providerFailureBecomesFailedSuggestion() async {
        let call = SuggestionCall(
            provider: StubLLMProvider(.failure(LLMFailure.unauthorized)),
            recognisesAs: "первый вопрос"
        )

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions.first?.state == .failed(LLMFailure.unauthorized.message))

        // Разговор продолжается: следующее нажатие снова просит подсказку, а не
        // упирается в предыдущий сбой.
        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.count == 2)
        #expect(call.engine.suggestions.count == 2, "сбой не должен был сломать следующее нажатие")
    }

    @Test("Ключа нет — в ленте видна причина словами, а не пустая карточка")
    func failureCarriesItsReasonIntoTheFeed() async {
        let call = SuggestionCall(provider: StubLLMProvider(.failure(LLMFailure.missingKey)))

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        guard case .failed(let message) = call.engine.suggestions.first?.state else {
            Issue.record("подсказка должна была перейти в состояние failed")
            return
        }
        #expect(message == "Не задан ключ провайдера — откройте настройки.")
    }

    // MARK: - Пустой транскрипт

    @Test("Ничего ещё не распознано — запрос всё равно уходит, с подстановкой вместо разговора")
    func emptyTranscriptStillMakesARequest() async {
        // Распознавание вернуло пустую строку: реплика в транскрипте есть, слов в ней нет.
        let call = SuggestionCall(provider: StubLLMProvider(.fragments(["Готов помочь."])))

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        let request = call.provider.requests.first
        #expect(request?.userPrompt.contains(BriefPrompt.emptyTranscriptPlaceholder) == true)
        #expect(request?.maxTokens == BriefPrompt.maxTokens)
        #expect(call.engine.suggestions.first?.text == "Готов помочь.", "подсказка всё равно должна прийти")
        #expect(call.engine.suggestions.first?.state == .complete)
    }

    @Test("Разговор уже идёт — в запрос уходят реплики с метками каналов")
    func transcriptReachesTheRequest() async {
        let call = SuggestionCall(provider: StubLLMProvider(), recognisesAs: "какой у вас стек")

        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        let prompt = call.provider.requests.first?.userPrompt ?? ""
        #expect(prompt.contains("Them: какой у вас стек"))
        #expect(
            !prompt.contains(BriefPrompt.emptyTranscriptPlaceholder),
            "подстановка нужна только там, где разговора нет"
        )
    }
}

// MARK: - Чем попросили

/// Нажатие знает, о чём просило, — и с этого момента знает и подсказка.
///
/// Нужно это одному потребителю, сохранённому диалогу: в нём все ответы модели
/// выглядели одинаково, хотя просить можно четыре разные вещи. Живёт свойство в
/// слое контекста, а `SuggestionAsk` отображается в него здесь — стрелка только в
/// эту сторону, иначе хранилище ответов узнало бы про сборку промптов.
@Suite("Подсказка помнит, чем её попросили")
@MainActor
struct SuggestionKindTests {

    @Test("Каждое из четырёх нажатий записывает свой вид")
    func everyPressRecordsItsKind() async {
        let call = SuggestionCall(provider: StubLLMProvider(.fragments(["готово"])))

        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()
        call.engine.suggestInDetail()
        await call.engine.waitForSuggestion()
        call.engine.ask("почему не Mongo?")
        await call.engine.waitForSuggestion()
        call.engine.solveOnScreen()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.map(\.kind) == [
            .brief,
            .detailed,
            .question("почему не Mongo?"),
            .screenTask,
        ])
    }

    @Test("Вопрос сохраняется тем же, каким ушёл в модель, — обрезанным")
    func theRecordedQuestionIsTheOneAsked() async {
        // Две записи одного вопроса, разойдись они пробелом, читались бы в файле
        // как ответ не на тот вопрос, который видела модель.
        let call = SuggestionCall(provider: StubLLMProvider())

        call.engine.ask("  чем крыть про шардинг?\n ")
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.first?.kind == .question("чем крыть про шардинг?"))
        #expect(
            call.provider.requests.first?.userPrompt.hasSuffix("Вопрос: чем крыть про шардинг?") == true
        )
    }

    @Test("Перебитая подсказка вид не теряет")
    func asupersededAnswerKeepsItsKind() async throws {
        let call = SuggestionCall(provider: StubLLMProvider(.manual))

        call.engine.suggestInDetail()
        try #require(await call.modelWasAsked(1))
        call.provider.emit("Начал разбирать")
        #expect(await call.textOfLatestReaches("Начал разбирать"))

        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(2))
        call.provider.finish()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 2)
        #expect(call.engine.suggestions[0].state == .superseded)
        #expect(
            call.engine.suggestions[0].kind == .detailed,
            "недочитанный разбор остаётся в ленте разбором, а не превращается в короткий ответ"
        )
        #expect(call.engine.suggestions[1].kind == .brief)
    }
}

// MARK: - Обстановка звонка

/// A call whose model is a stub: speech goes in, presses go in, requests and
/// suggestions come out.
///
/// Mirrors `CallFixture`, with the model plugged in — the other suite has no
/// provider and must keep working without one.
@MainActor
private struct SuggestionCall {
    let engine: SessionEngine
    let provider: StubLLMProvider

    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(
        provider: StubLLMProvider,
        recognisesAs text: String = "",
        recognisesInOrder replies: [String] = [],
        recognizer: (any SpeechRecognizer)? = nil,
        profile: UserProfile = .empty
    ) {
        let clock = ManualClock()
        self.clock = clock
        self.provider = provider
        self.engine = SessionEngine(
            recognizer: recognizer ?? (replies.isEmpty ? RecognizerSpy(reply: text) : RecognizerSpy(replies: replies)),
            provider: provider,
            composer: PromptComposer(profile: { profile }),
            // No screen here: what this suite is about is what starts, cancels
            // and settles a suggestion, and a real screenshot would put a
            // display server and a TCC grant between the test and the answer.
            // The screen has its own suite.
            capturer: NoScreenCapturer(),
            clock: clock
        )
    }

    /// A whole turn of one channel: someone talks, then stops long enough for
    /// the turn to close.
    func says(_ channel: Channel, for seconds: TimeInterval = 1.2) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
        feed(seconds: TurnSegmentationConfig.default.pauseThreshold + 0.2) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    /// Включает прослушивание. Без источников звука это просто поднимает флаг —
    /// кадры сюда и так приходят напрямую, — но флаг решает, какую строку
    /// получит подсказка, а проверяем мы именно её.
    func listen() {
        try? engine.start()
    }

    /// Прожигает бюджет ожидания распознавания, не трогая звук.
    ///
    /// Сначала дожидается, пока ожидание зарегистрирует спящего: перевести часы
    /// раньше — значит перевести их мимо, и тест станет монеткой.
    func waitOutRecognitionBudget() async {
        await clock.waitForSleeper()
        clock.advance(by: SessionEngine.recognitionBudget + 0.5)
    }

    /// Waits until the newest suggestion has grown to `text`.
    ///
    /// Fragments cross a task boundary, so they land a hop later rather than
    /// instantly; the loop is bounded so a stalled stream fails the test instead
    /// of hanging it.
    func textOfLatestReaches(_ text: String, within timeout: Duration = TestWait.budget) async -> Bool {
        await settling(within: timeout) { engine.suggestions.last?.text == text }
    }

    /// Waits until the model has been asked `count` times. A press goes through
    /// the screenshot and the wait for words first, so the request lands a hop
    /// later rather than instantly.
    ///
    /// Предел — общий `TestWait.budget`, и почему он именно такой, написано там.
    /// Здесь этот стенд держал две секунды, ронял CI начиная с 0.2.0 и сорвал
    /// публикацию 0.3.1.
    func modelWasAsked(_ count: Int, within timeout: Duration = TestWait.budget) async -> Bool {
        await settling(within: timeout) { provider.requests.count == count }
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

// MARK: - Модель-заглушка

/// A model that answers from a script and remembers what it was asked.
///
/// `manual` exists for the one thing a scripted answer cannot show: that the
/// text appears in the window while the model is still writing it.
private final class StubLLMProvider: LLMProvider, @unchecked Sendable {

    enum Script {
        /// Yields every fragment, then finishes.
        case fragments([String])
        /// Refuses straight away.
        case failure(any Error)
        /// The test yields the fragments by hand.
        case manual
    }

    let name = "Заглушка"
    let capabilities = ProviderCapabilities.multimodal

    private let lock = NSLock()
    private let script: Script
    private var recorded: [SuggestionRequest] = []
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?

    init(_ script: Script = .fragments(["готово"])) {
        self.script = script
    }

    /// Requests that actually reached the model, in order.
    var requests: [SuggestionRequest] {
        lock.withLock { recorded }
    }

    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            switch script {
            case .fragments(let parts):
                for part in parts { continuation.yield(part) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .manual:
                break
            }
        }
    }

    /// Writes one more fragment of the answer.
    func emit(_ fragment: String) {
        lock.withLock { continuation }?.yield(fragment)
    }

    /// The model finished writing.
    func finish() {
        lock.withLock { continuation }?.finish()
    }

    /// The answer stopped before the model finished saying it — the reason
    /// arrives after the words, exactly as a real provider delivers it.
    func cut(_ cutoff: SuggestionCutoff) {
        lock.withLock { continuation }?.finish(throwing: cutoff)
    }
}


/// Распознавание, которое зависает на указанной по счёту реплике.
///
/// Нужно, чтобы проверить единственный путь, на котором подсказка собирается из
/// неполного транскрипта: бюджет ожидания истёк, слова ещё в работе.
private actor StallingRecognizer: SpeechRecognizer {
    private var replies: [String]
    private let stallsAt: Int
    private var seen = 0

    init(replies: [String], stallsAt: Int) {
        self.replies = replies
        self.stallsAt = stallsAt
    }

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        seen += 1
        if seen == stallsAt {
            // Никогда не завершается сама: тест уводит время вперёд, и ждать её
            // перестаёт бюджет, а не отмена — распознавание не отменяется.
            try? await Task.sleep(nanoseconds: .max)
        }
        return replies.isEmpty ? "" : replies.removeFirst()
    }
}
