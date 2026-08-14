//
//  ManualModesTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// The two modes that answer something other than the conversation: a question
/// typed into the overlay (`Ask`) and the demand for the task on screen to be
/// solved (`Solve on screen`).
///
/// Two things are checked here and nowhere else. What the model is actually
/// shown — the wording is copied from docs/GhostMeet-Prompts.md §5 and §6, and
/// these tests are what stops the code and the document drifting apart. And that
/// these two live under exactly the same rules as the genres: one press at a
/// time, superseded by the next press and by nothing else (ADR-0008).
@Suite("Промпт режима Ask")
struct AskPromptTests {

    // MARK: - Вопрос пользователя

    @Test("Вопрос уходит в промпт последним — после разговора и после экрана")
    func theQuestionComesLast() {
        let prompt = AskPrompt.user(
            question: "что это за ошибка?",
            transcript: [spoken(.them, "смотрите на консоль", at: 0)],
            screenText: "fatal error: index out of range"
        )

        #expect(prompt.hasSuffix("Вопрос: что это за ошибка?"))
        #expect(prompt.contains("Разговор:"))
        #expect(prompt.contains("Them: смотрите на консоль"))
        #expect(prompt.contains("Текст с экрана (OCR):"))
        #expect(prompt.contains("fatal error: index out of range"))
    }

    @Test("Пробелы вокруг вопроса не уезжают в промпт")
    func theQuestionIsTrimmed() {
        #expect(
            AskPrompt.user(question: "  как это свернуть?\n").hasSuffix("Вопрос: как это свернуть?")
        )
    }

    // MARK: - Окно транскрипта

    @Test("Разговор идёт давно — вопрос про сказанное полчаса назад отвечать есть чем")
    func thewholeCallReachesTheModel() {
        let long = (1...200).map { spoken(.them, "вопрос-\(String(format: "%03d", $0))", at: Double($0) * 10) }

        let prompt = AskPrompt.user(question: "о чём вообще речь?", transcript: long)

        #expect(AskPrompt.transcriptWindow == TranscriptFormatter.wholeCall)
        #expect(prompt.contains("вопрос-200"), "последняя реплика обязана быть в промпте")
        #expect(prompt.contains("вопрос-001"), "и первая тоже: окно накрывает весь звонок")
        #expect(transcriptLines(of: prompt).count == 200)
    }

    @Test("У каждой реплики стоит метка её канала")
    func everyTurnCarriesItsChannelLabel() {
        let prompt = AskPrompt.user(
            question: "что ему ответить?",
            transcript: [spoken(.them, "как работает GCD?", at: 0), spoken(.you, "это очередь задач", at: 10)]
        )

        #expect(prompt.contains("Them: как работает GCD?"))
        #expect(prompt.contains("You: это очередь задач"))
    }

    // MARK: - Пустой транскрипт

    @Test("Разговор ещё не начался — запрос всё равно собирается, без пустого блока разговора")
    func emptyTranscriptStillProducesARequest() {
        let request = AskPrompt.request(question: "что на экране?")

        #expect(request.userPrompt == "Вопрос: что на экране?")
        #expect(!request.userPrompt.contains("Разговор:"), "пустой заголовок — ложь про разговор")
        #expect(!request.systemPrompt.isEmpty)
    }

    @Test("Все реплики пока без текста — это тот же пустой разговор, а не пустые строки")
    func transcriptOfSilentTurnsAddsNoBlock() {
        let unrecognised = [
            Turn(channel: .them, text: "", timestamp: 0, duration: 1),
            Turn(channel: .you, text: "   ", timestamp: 10, duration: 1),
        ]

        #expect(
            AskPrompt.user(question: "и что теперь?", transcript: unrecognised)
                == "Вопрос: и что теперь?"
        )
    }

    @Test("Экран ничего не отдал — блока OCR нет, а вопрос уходит")
    func anEmptyScreenAddsNoBlock() {
        let request = AskPrompt.request(question: "что дальше?", screenText: "   ")

        #expect(!request.userPrompt.contains(AskPrompt.screenTextHeading))
        #expect(request.userPrompt.contains("Вопрос: что дальше?"))
    }

    // MARK: - Профиль

    @Test("Профиль пользователя дописан в конец системной части")
    func profileLandsInTheSystemPrompt() {
        let system = AskPrompt.system(
            profile: UserProfile(role: "Senior iOS Engineer", stack: "Swift, Core Audio")
        )

        #expect(system.contains("Контекст о пользователе (резюме / роль / стек):"))
        #expect(system.contains("Роль: Senior iOS Engineer"))
        #expect(system.hasSuffix("Стек: Swift, Core Audio"), "профиль идёт последним")
    }

    @Test("Профиль не заполнен — пустого блока в системной части нет")
    func emptyProfileAddsNothing() {
        #expect(!AskPrompt.system(profile: .empty).contains("Контекст о пользователе"))
    }

    @Test("Заготовки к собеседованию доходят и до режима Ask")
    func theInterviewContextReachesAsk() {
        let system = AskPrompt.system(
            profile: .empty,
            interviewContext: InterviewContext(compensation: "вилка 350–420")
        )

        #expect(system.contains(PromptFragment.interviewContextHeading))
        #expect(
            system.contains("Ожидания по деньгам:\nвилка 350–420"),
            "«что сказать про зарплату» — типичный вопрос в поле Ask, и сумма у него уже заготовлена"
        )
        #expect(!AskPrompt.system(profile: .empty).contains(PromptFragment.interviewContextHeading))
    }

    // MARK: - Текст промпта и настройки режима

    @Test("Системная часть слово в слово повторяет документ промптов, §5")
    func theSystemPromptMatchesTheDocument() {
        #expect(AskPrompt.system(profile: .empty) == """
        Ты — GhostMeet, real-time copilot с доступом к экрану пользователя и живому разговору («Them» / «You»).

        Ответь на вопрос пользователя прямо и кратко, опираясь на экран и сказанное. Без преамбулы («На основе скриншота…»).
        Язык ответа — язык вопроса пользователя.
        """)
    }

    @Test("Язык ответа не форсируется: правило отсылает к языку вопроса")
    func answerLanguageFollowsTheQuestion() {
        #expect(AskPrompt.system(profile: .empty).contains("Язык ответа — язык вопроса пользователя"))
    }

    @Test("Бюджет токенов — из полосы, отведённой режимам про экран и код")
    func tokenBudgetMatchesTheMode() {
        let request = AskPrompt.request(question: "перепиши этот запрос")

        #expect(request.maxTokens == AskPrompt.maxTokens)
        #expect((2_000...4_096).contains(request.maxTokens), "короткой полосы 256–512 режиму мало: вопрос может быть про код")
        #expect(request.maxTokens < SolvePrompt.maxTokens, "ответить велено кратко")
    }

    @Test("Скриншот прикладывается к запросу как есть")
    func screenshotIsCarriedIntoTheRequest() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        #expect(AskPrompt.request(question: "что тут?", screenshot: png).screenshot == png)
    }

    // MARK: - Хелперы

    /// Turns are spaced well past `TranscriptFormatter.mergeGap`, so each of them
    /// stays a line of its own: what is checked here is the window, not the merge.
    private func spoken(_ channel: Channel, _ text: String, at timestamp: TimeInterval) -> Turn {
        Turn(channel: channel, text: text, timestamp: timestamp, duration: 1)
    }

    /// Lines of the transcript block — everything that carries a channel label.
    private func transcriptLines(of prompt: String) -> [String] {
        prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("Them: ") || $0.hasPrefix("You: ") }
    }
}

// MARK: - Solve on screen

@Suite("Промпт режима Solve on screen")
struct SolvePromptTests {

    @Test("Системная часть слово в слово повторяет документ промптов, §6")
    func theSystemPromptMatchesTheDocument() {
        #expect(SolvePrompt.system == """
        Ты — эксперт по решению задач с экрана (алгоритмы, код, тесты, формы, расчёты).

        На скриншоте (и/или в OCR-тексте) — задача. Ответь строго структурой:

        1. Одна строка: что требуется
        2. Краткий подход (2–4 предложения)
        3. Готовое решение в fenced code block (язык как на экране, иначе Python) ИЛИ готовый итоговый ответ, если это не код
        4. Для кода: time и space complexity

        Правила:
        - Не лей воду и не учи теории сверх необходимого.
        - Решение должно быть рабочим.
        - Если условия нечитаемы — напиши, чего не хватает, одним абзацем.
        - Язык пояснений — как у задачи на экране (часто русский или английский).
        """)
    }

    @Test("Модель просят решение, а не разбор теории")
    func theModeAsksForTheSolutionItself() {
        let system = SolvePrompt.system

        #expect(system.contains("Готовое решение в fenced code block"))
        #expect(system.contains("Не лей воду и не учи теории сверх необходимого."))
        #expect(system.contains("Решение должно быть рабочим."))
    }

    @Test("Язык пояснений не форсируется: правило отсылает к языку задачи на экране")
    func answerLanguageFollowsTheTask() {
        #expect(SolvePrompt.system.contains("Язык пояснений — как у задачи на экране"))
    }

    @Test("Текст с экрана уходит отдельным блоком перед требованием решить")
    func theScreenTextTravelsWithTheAsk() {
        let prompt = SolvePrompt.user(screenText: "def two_sum(nums, target):")

        #expect(prompt == """
        Текст с экрана (OCR):
        def two_sum(nums, target):

        Реши задачу, показанную на скриншоте.
        """)
    }

    @Test("Экран ничего не отдал — запрос всё равно уходит, без пустого блока OCR")
    func anUnreadableScreenStillProducesARequest() {
        let request = SolvePrompt.request()

        #expect(request.userPrompt == "Реши задачу, показанную на скриншоте.")
        #expect(!request.userPrompt.contains(SolvePrompt.screenTextHeading))
        #expect(request.systemPrompt.contains("Если условия нечитаемы"))
    }

    @Test("Разговор режим не читает вовсе — ни реплик, ни заголовка")
    func theTranscriptIsNeverRead() {
        #expect(SolvePrompt.readsTranscript == false)

        let prompt = SolvePrompt.user(screenText: "Them: расскажите про индексы")

        #expect(!prompt.contains("Недавний разговор:"))
        // Текст с экрана попадает как есть — это экран, а не транскрипт.
        #expect(prompt.contains(SolvePrompt.screenTextHeading))
    }

    @Test("Бюджет токенов — верх полосы: обрезанное на середине решение не стоит ничего")
    func tokenBudgetMatchesTheMode() {
        #expect(SolvePrompt.maxTokens == 4_096)
        #expect(SolvePrompt.request().maxTokens == SolvePrompt.maxTokens)
    }

    @Test("И снимок, и текст с экрана доезжают до запроса")
    func bothHalvesOfTheScreenReachTheRequest() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let request = SolvePrompt.request(screenText: "2 + 2 = ?", screenshot: png)

        #expect(request.screenshot == png)
        #expect(request.userPrompt.contains("2 + 2 = ?"))
    }
}

// MARK: - Сборка запроса под возможности провайдера

@Suite("Сборка запроса по тому, что нажали")
@MainActor
struct PromptComposerTests {

    private let screen = ScreenContext(
        image: Data([0x89, 0x50, 0x4E, 0x47]),
        text: "class Solution:"
    )

    @Test("Ask собирается промптом своего режима, с профилем и разговором")
    func askUsesItsOwnPrompt() {
        let composer = PromptComposer(profile: { UserProfile(role: "Backend Engineer") })

        let request = composer.compose(
            .question("что ему ответить?"),
            transcript: [Turn(channel: .them, text: "как вы шардируете?", timestamp: 0, duration: 1)],
            screen: screen,
            accepting: .multimodal
        )

        #expect(request.systemPrompt == AskPrompt.system(profile: UserProfile(role: "Backend Engineer")))
        #expect(request.maxTokens == AskPrompt.maxTokens)
        #expect(request.userPrompt.contains("Them: как вы шардируете?"))
        #expect(request.userPrompt.hasSuffix("Вопрос: что ему ответить?"))
    }

    @Test("Solve собирается промптом своего режима и разговор не читает")
    func solveUsesItsOwnPrompt() {
        let composer = PromptComposer(profile: { UserProfile(role: "Backend Engineer") })

        let request = composer.compose(
            .screenTask,
            transcript: [Turn(channel: .them, text: "как вы шардируете?", timestamp: 0, duration: 1)],
            screen: screen,
            accepting: .multimodal
        )

        #expect(request.systemPrompt == SolvePrompt.system)
        #expect(request.maxTokens == SolvePrompt.maxTokens)
        #expect(!request.userPrompt.contains("как вы шардируете?"), "решаем экран, а не разговор")
        #expect(
            !request.systemPrompt.contains("Контекст о пользователе"),
            "резюме в задаче с экрана — только лишние токены: вслух её никто не произносит"
        )
    }

    @Test("Каждый жанр собирается своим промптом, а не обрезанным чужим")
    func eachGenreUsesItsOwnPrompt() {
        let composer = PromptComposer(profile: { UserProfile(role: "Backend Engineer") })
        let transcript = [Turn(channel: .them, text: "как вы шардируете?", timestamp: 0, duration: 1)]

        let brief = composer.compose(.brief, transcript: transcript, screen: screen, accepting: .multimodal)
        let detailed = composer.compose(.detailed, transcript: transcript, screen: screen, accepting: .multimodal)

        #expect(brief.systemPrompt == BriefPrompt.system(
            profile: UserProfile(role: "Backend Engineer"),
            hasStartedAnswering: TranscriptFormatter.hasStartedAnswering(transcript)
        ))
        #expect(detailed.systemPrompt == AssistPrompt.system(profile: UserProfile(role: "Backend Engineer")))
        #expect(brief.maxTokens == BriefPrompt.maxTokens)
        #expect(detailed.maxTokens == AssistPrompt.maxTokens)
        #expect(brief.userPrompt.contains("Them: как вы шардируете?"))
        #expect(detailed.userPrompt.contains("Them: как вы шардируете?"))
        #expect(brief.screenshot == screen.image, "скриншот прикладывается к каждому запросу")
        #expect(detailed.screenshot == screen.image)
    }

    @Test("Разговор читают все нажатия, кроме решения задачи с экрана")
    func onlySolveIgnoresTheConversation() {
        #expect(SuggestionAsk.brief.readsTranscript)
        #expect(SuggestionAsk.detailed.readsTranscript)
        #expect(SuggestionAsk.question("что тут?").readsTranscript)
        #expect(
            SuggestionAsk.screenTask.readsTranscript == false,
            "иначе решение с экрана платило бы ожиданием слов, которых его промпт всё равно не увидит"
        )
    }

    @Test("Провайдер не берёт картинок — снимок снимается, а текст с экрана остаётся")
    func aTextOnlyProviderKeepsTheScreenText() {
        let composer = PromptComposer()

        let ask = composer.compose(.question("что тут?"), transcript: [], screen: screen, accepting: .textOnly)
        let solve = composer.compose(.screenTask, transcript: [], screen: screen, accepting: .textOnly)
        let brief = composer.compose(.brief, transcript: [], screen: screen, accepting: .textOnly)

        #expect(ask.screenshot == nil)
        #expect(solve.screenshot == nil)
        #expect(brief.screenshot == nil)
        #expect(ask.userPrompt.contains("class Solution:"), "для локальной модели это всё, что она узнает про экран")
        #expect(solve.userPrompt.contains("class Solution:"))
        #expect(brief.userPrompt.contains("class Solution:"))
    }

    @Test("Очищенный контекст не доезжает до вопроса пользователя")
    func clearedTurnsNeverReachTheQuestion() {
        let context = ConversationContext()
        let forgotten = Turn(channel: .them, text: "старый вопрос", timestamp: 0, duration: 1)
        let kept = Turn(channel: .them, text: "новый вопрос", timestamp: 1, duration: 1)
        context.forget(turns: [forgotten], suggestions: [])

        let composer = ContextLimitedComposer(context: context, wrapped: PromptComposer())
        let request = composer.compose(
            .question("о чём речь?"),
            transcript: [forgotten, kept],
            screen: .none,
            accepting: .multimodal
        )

        #expect(!request.userPrompt.contains("старый вопрос"), "очистка обязана дойти до модели, а не только до окна")
        #expect(request.userPrompt.contains("новый вопрос"))
    }
}

// MARK: - Ручной запрос в живом цикле

/// `Ask` and `Solve on screen` inside the session: what reaches the model, and
/// what happens to their answer when the user presses again.
@Suite("Ask и Solve в жизни сессии")
@MainActor
struct ManualRequestLifecycleTests {

    // MARK: - Что уходит к модели

    @Test("Пользователь спросил сам — запрос ушёл, ответ появился в ленте")
    func askReachesTheModel() async {
        let call = ManualCall(model: ManualModel(.fragments(["Скажи ", "про индексы."])))

        call.engine.ask("что ответить про индексы?")
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.count == 1)
        #expect(call.model.requests.first?.userPrompt.hasSuffix("Вопрос: что ответить про индексы?") == true)
        #expect(call.model.requests.first?.maxTokens == AskPrompt.maxTokens)
        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].text == "Скажи про индексы.")
        #expect(call.engine.suggestions[0].state == .complete)
    }

    @Test("Пустой вопрос не уходит никуда")
    func aBlankQuestionAsksNothing() async {
        let call = ManualCall(model: ManualModel(.fragments(["ответ"])))

        call.engine.ask("   \n ")
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.isEmpty)
        #expect(call.engine.suggestions.isEmpty)
    }

    @Test("Решение с экрана уходит со снимком и с распознанным текстом")
    func solveCarriesBothHalvesOfTheScreen() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let call = ManualCall(
            model: ManualModel(.fragments(["def two_sum"])),
            capturer: FixedScreenCapturer(
                ScreenContext(image: png, text: "Given an array of integers…")
            )
        )

        call.engine.solveOnScreen()
        await call.engine.waitForSuggestion()

        let request = call.model.requests.first
        #expect(request?.systemPrompt == SolvePrompt.system)
        #expect(request?.screenshot == png)
        #expect(request?.userPrompt.contains("Given an array of integers…") == true)
        #expect(request?.maxTokens == SolvePrompt.maxTokens)
    }

    @Test("Разговор ещё не распознан — ручной запрос всё равно уходит")
    func anEmptyTranscriptNeverBlocksAManualRequest() async {
        let call = ManualCall(model: ManualModel(.fragments(["готово"])))

        call.engine.ask("что на экране?")
        await call.engine.waitForSuggestion()
        call.engine.solveOnScreen()
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.isEmpty)
        #expect(call.model.requests.count == 2, "оба режима обязаны собраться без единой реплики")
        #expect(call.model.requests[0].userPrompt == "Вопрос: что на экране?")
        #expect(call.model.requests[1].userPrompt == "Реши задачу, показанную на скриншоте.")
    }

    @Test("Модель не настроена — в ленте видна причина, а не тишина в ответ на нажатие")
    func aManualRequestWithoutAProviderSaysSo() async {
        let call = ManualCall(model: nil)

        call.engine.solveOnScreen()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].state == .failed(LLMFailure.missingKey.message))
    }

    // MARK: - Вытеснение

    @Test("Собеседник заговорил — ответ на вопрос пользователя это не отменяет")
    func aThemTurnLeavesTheAnswerAlone() async throws {
        let call = ManualCall(model: ManualModel(.manual), recognises: "а расскажите про индексы")

        call.engine.ask("что тут на экране?")
        try #require(await call.modelWasAsked(1))
        call.model.emit("На экране ", into: 0)
        #expect(await call.textOfLatestReaches("На экране "))

        call.says(.them)
        await call.engine.waitForRecognition()

        #expect(call.model.cancelledStreams.isEmpty, "реплика Them больше ничего не отменяет (ADR-0008)")
        #expect(call.engine.suggestions.count == 1, "и ничего не запускает")
        #expect(call.engine.suggestions[0].state == .streaming)
        #expect(call.engine.transcript.count == 1, "слова при этом пишутся как обычно")

        call.model.finish(0)
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[0].state == .complete)
    }

    @Test("Своя речь ответ не отменяет")
    func aYouTurnCancelsNothing() async throws {
        let call = ManualCall(model: ManualModel(.manual), recognises: "сейчас посмотрю")

        call.engine.ask("что тут на экране?")
        try #require(await call.modelWasAsked(1))
        call.model.emit("Это ", into: 0)
        #expect(await call.textOfLatestReaches("Это "))

        call.says(.you)
        await call.engine.waitForRecognition()

        #expect(call.model.cancelledStreams.isEmpty, "собственная речь не имеет права обрывать генерацию")
        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].state == .streaming)

        call.model.emit("выход за границы массива.", into: 0)
        #expect(await call.textOfLatestReaches("Это выход за границы массива."))

        call.model.finish(0)
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[0].state == .complete)
    }

    @Test("Solve поверх начатого ответа — две генерации в одну ленту не пишут")
    func solveSupersedesTheAnswerInFlight() async throws {
        let call = ManualCall(model: ManualModel(.manual), recognises: "расскажите про транзакции")

        call.says(.them)
        call.engine.suggestBriefly()
        try #require(await call.modelWasAsked(1))
        call.model.emit("Транзакция — ", into: 0)
        #expect(await call.textOfLatestReaches("Транзакция — "))

        call.engine.solveOnScreen()
        try #require(await call.modelWasAsked(2))

        #expect(await call.model.streamWasCancelled(0), "предыдущий ответ обязан оборваться")
        #expect(call.engine.suggestions.count == 2)
        #expect(call.engine.suggestions[0].state == .superseded)
        #expect(call.engine.suggestions[0].text == "Транзакция — ")
        #expect(call.model.requests[1].systemPrompt == SolvePrompt.system)

        call.model.finish(1)
        await call.engine.waitForSuggestion()
        #expect(call.engine.suggestions[1].state == .complete)
    }

    @Test("Реплика, закрытая перед вопросом пользователя, своего запроса не делает")
    func aClosedTurnNeverLandsOnTopOfTheQuestion() async {
        // Распознавание держится: реплика Them закрылась, слов у неё ещё нет —
        // ровно тот зазор, в который попадает вопрос пользователя.
        let call = ManualCall(
            model: ManualModel(.fragments(["готово"])),
            recognises: "расскажите про транзакции",
            holdingRecognition: true
        )

        call.says(.them)
        call.engine.ask("что тут на экране?")

        await call.recognizer.release()
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.count == 1, "закрытая реплика запроса не делает")
        #expect(call.model.requests[0].userPrompt.hasSuffix("Вопрос: что тут на экране?") == true)
        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions[0].state == .complete)
        #expect(
            call.engine.transcript.map(\.text) == ["расскажите про транзакции"],
            "распознавание не отменяется никогда — слова остаются в транскрипте"
        )
    }

    @Test("После вопроса пользователя нажатия продолжают работать")
    func pressesKeepWorkingAfterAQuestion() async {
        let call = ManualCall(model: ManualModel(.fragments(["ответ"])), recognises: "следующий вопрос")

        call.engine.ask("что на экране?")
        await call.engine.waitForSuggestion()
        call.says(.them)
        call.engine.suggestBriefly()
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.count == 2)
        #expect(call.model.requests[1].userPrompt.contains("Them: следующий вопрос"))
        #expect(call.engine.suggestions.count == 2)
        #expect(call.engine.suggestions.allSatisfy { $0.state == .complete })
    }
}

// MARK: - Хоткеи

@Suite("Аккорды, по которым уходит запрос")
@MainActor
struct RequestHotkeyTests {

    /// Everything that reaches the model has a chord, because since ADR-0008 a
    /// chord is the only way anything reaches it at all.
    private static let asking: [HotkeyAction] = [.suggestBriefly, .suggestInDetail, .solveOnScreen]

    @Test("У каждого запроса своя комбинация, и все они годятся для глобальной регистрации")
    func everyRequestHasAUsableChord() {
        for action in Self.asking {
            let hotkey = HotkeyBindings.default[action]
            #expect(hotkey != nil, "\(action.rawValue): без комбинации запрос был бы недостижим без мыши")
            #expect(hotkey?.isValid == true, "комбинация без ⌘/⌥/⌃ отберёт обычный ввод у всей системы")
        }
    }

    @Test("Нажатие каждой комбинации запускает именно своё действие")
    func eachChordRunsItsOwnAction() {
        var ran: [HotkeyAction] = []
        var actions = HotkeyActions()
        actions.suggestBriefly = { ran.append(.suggestBriefly) }
        actions.suggestInDetail = { ran.append(.suggestInDetail) }
        actions.solveOnScreen = { ran.append(.solveOnScreen) }

        for action in Self.asking { actions[action]() }

        #expect(ran == Self.asking)
    }

    @Test("Оба жанра доходят до движка и собираются разными промптами")
    func bothGenresReachTheEngine() async {
        let call = ManualCall(model: ManualModel(.fragments(["ответ"])), recognises: "что такое GiST")
        var actions = HotkeyActions()
        actions.suggestBriefly = { call.engine.suggestBriefly() }
        actions.suggestInDetail = { call.engine.suggestInDetail() }

        call.says(.them)
        actions[.suggestBriefly]()
        await call.engine.waitForSuggestion()
        actions[.suggestInDetail]()
        await call.engine.waitForSuggestion()

        #expect(call.model.requests.count == 2)
        // Сказал только собеседник — значит, редакция «вслух он ещё ничего не сказал».
        #expect(call.model.requests[0].systemPrompt == BriefPrompt.system(profile: .empty, hasStartedAnswering: false))
        #expect(call.model.requests[1].systemPrompt == AssistPrompt.system(profile: .empty))
    }
}

// MARK: - Обстановка звонка

/// A call with a model, a screen and recognition, all doubles, where the user
/// can both speak and type.
///
/// Same shape as the fixtures of the automatic suites, with the one thing these
/// tests need added: the ability to hold recognition, so a manual request can be
/// slipped into the gap between a closed `Them` turn and its automatic answer.
@MainActor
private struct ManualCall {
    let engine: SessionEngine
    let model: ManualModel
    let recognizer: HoldingRecognizer

    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(
        model: ManualModel?,
        recognises reply: String = "",
        holdingRecognition: Bool = false,
        capturer: (any ScreenCapturer)? = nil
    ) {
        let clock = ManualClock()
        let recognizer = HoldingRecognizer(reply: reply, holding: holdingRecognition)
        self.clock = clock
        self.model = model ?? ManualModel(.fragments([]))
        self.recognizer = recognizer
        self.engine = SessionEngine(
            recognizer: recognizer,
            provider: model,
            composer: PromptComposer(profile: { .empty }),
            capturer: capturer ?? NoScreenCapturer(),
            clock: clock
        )
    }

    /// A whole turn of one channel: someone talks, then stops long enough for
    /// the turn to close.
    func says(_ channel: Channel, for seconds: TimeInterval = 1.2) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
        feed(seconds: TurnSegmentationConfig.default.pauseThreshold + 0.2) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    func textOfLatestReaches(_ text: String, within timeout: Duration = .seconds(8)) async -> Bool {
        await settling(within: timeout) { engine.suggestions.last?.text == text }
    }

    /// Waits until the model has been asked `count` times. A manual request goes
    /// through a screenshot first, so it lands a hop later rather than instantly.
    func modelWasAsked(_ count: Int, within timeout: Duration = .seconds(8)) async -> Bool {
        await settling(within: timeout) { model.requests.count == count }
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

/// Recognition that answers with one canned line and can be made to hold every
/// pass until the test lets it through.
private actor HoldingRecognizer: SpeechRecognizer {

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

/// A screen that always shows the same thing.
private struct FixedScreenCapturer: ScreenCapturer {
    let context: ScreenContext

    init(_ context: ScreenContext) { self.context = context }

    func capture() async -> ScreenContext { context }
}

// MARK: - Модель-заглушка

/// A model that answers from a script, remembers what it was asked, and reports
/// which of its streams were terminated by cancellation.
///
/// The same double the automatic suites use; it lives here again rather than
/// being shared because each suite's copy is free to grow whatever that suite
/// needs to observe.
private final class ManualModel: LLMProvider, @unchecked Sendable {

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
    func streamWasCancelled(_ index: Int, within timeout: Duration = .seconds(8)) async -> Bool {
        await settling(within: timeout) { self.cancelledStreams.contains(index) }
    }

    private func continuation(_ index: Int) -> AsyncThrowingStream<String, any Error>.Continuation? {
        lock.withLock { streams.indices.contains(index) ? streams[index] : nil }
    }

    private func markCancelled(_ index: Int) {
        lock.withLock { _ = cancelled.insert(index) }
    }
}
