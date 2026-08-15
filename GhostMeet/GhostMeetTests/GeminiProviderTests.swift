//
//  GeminiProviderTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// Gemini driven without a socket: a scripted transport replays what Google
/// would put on the wire.
///
/// The point of these tests is that Gemini's dialect is its own — a
/// `contents`/`parts` tree, a separate `systemInstruction`, whole-response
/// chunks instead of deltas, and an HTTP code that lies about a rejected key —
/// while the behaviour the rest of the app sees stays identical to Claude's.
@Suite("Провайдер Gemini")
struct GeminiProviderTests {

    // MARK: - Стриминг

    @Test("Подсказка приходит фрагментами по мере генерации, а не целиком в конце")
    func answerArrivesInFragments() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.text("Расскажу "),
                GeminiSSE.text("про GCD."),
                GeminiSSE.finished("STOP"),
            ])
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.error == nil)
        #expect(answer.fragments == ["Расскажу ", "про GCD."])
    }

    @Test("Несколько частей в одном чанке склеиваются в один фрагмент")
    func partsOfOneChunkAreJoined() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.chunk(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"два "},{"text":"куска"}]}}]}"#),
                GeminiSSE.finished("STOP"),
            ])
        )

        #expect(await drainStream(provider.stream(fixture())).fragments == ["два куска"])
    }

    @Test("Рассуждения модели подсказкой не становятся")
    func thoughtPartsNeverReachTheOverlay() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.chunk(#"{"candidates":[{"content":{"parts":[{"text":"сначала подумаю","thought":true}]}}]}"#),
                GeminiSSE.text("Ответ."),
                GeminiSSE.finished("STOP"),
            ])
        )

        #expect(await drainStream(provider.stream(fixture())).fragments == ["Ответ."])
    }

    @Test("Служебные чанки без текста подсказку не портят")
    func bookkeepingChunksAreIgnored() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.chunk(#"{"usageMetadata":{"promptTokenCount":12}}"#),
                GeminiSSE.chunk(#"{"candidates":[{"safetyRatings":[{"category":"HARM_CATEGORY_HARASSMENT","probability":"NEGLIGIBLE"}]}]}"#),
                GeminiSSE.text("Ответ."),
                // Закрывающий чанк дописан намеренно: тест про служебные строки,
                // а не про обрыв, и без него он проверял бы теперь второе.
                GeminiSSE.finished("STOP"),
            ])
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.fragments == ["Ответ."])
        #expect(answer.error == nil)
    }

    // MARK: - Форма запроса

    @Test("Запрос уходит на потоковый метод, ключ — в заголовке, а не в адресе")
    func requestGoesToTheStreamingMethodWithTheKeyInAHeader() async throws {
        let transport = ScriptedTransport(lines: [GeminiSSE.finished("STOP")])
        let provider = GeminiProvider(apiKey: { "AIza-test-key" }, transport: transport)

        _ = await drainStream(provider.stream(fixture()))

        let sent = try #require(await transport.sent.first)
        let url = try #require(sent.url)
        #expect(sent.httpMethod == "POST")
        #expect(
            url.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse"
        )
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-test-key")
        #expect(
            !url.absoluteString.contains("AIza-test-key"),
            "секрет в адресе утечёт в логи и прокси"
        )
    }

    @Test("Модель, названную как «models/…», в адресе не задваиваем")
    func modelNamedWithItsCollectionIsNotDoubled() async throws {
        let transport = ScriptedTransport(lines: [GeminiSSE.finished("STOP")])
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: transport,
            configuration: GeminiProvider.Configuration(model: "models/gemini-2.5-pro")
        )

        _ = await drainStream(provider.stream(fixture()))

        let url = try #require(await transport.sent.first?.url)
        #expect(url.path == "/v1beta/models/gemini-2.5-pro:streamGenerateContent")
    }

    @Test("Системный промпт уходит отдельным полем, а не ролью в переписке")
    func systemPromptTravelsAsSystemInstruction() async throws {
        let transport = ScriptedTransport(lines: [GeminiSSE.finished("STOP")])
        let provider = GeminiProvider(apiKey: { "key" }, transport: transport)
        let request = fixture()

        _ = await drainStream(provider.stream(request))

        let body = try #require(jsonBody(await transport.sent.first?.httpBody))
        let instruction = try #require(body["systemInstruction"] as? [String: Any])
        let parts = try #require(instruction["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == request.systemPrompt)

        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents.first?["role"] as? String == "user")
        let userParts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(userParts.count == 1)
        #expect(userParts.first?["text"] as? String == request.userPrompt)
    }

    @Test("Бюджет режима и уровень размышлений уходят в generationConfig")
    func budgetAndThinkingLevelTravelInGenerationConfig() async throws {
        let transport = ScriptedTransport(lines: [GeminiSSE.finished("STOP")])
        let provider = GeminiProvider(apiKey: { "key" }, transport: transport)
        let request = fixture()

        _ = await drainStream(provider.stream(request))

        let body = try #require(jsonBody(await transport.sent.first?.httpBody))
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["maxOutputTokens"] as? Int == request.maxTokens)

        let thinking = try #require(config["thinkingConfig"] as? [String: Any])
        #expect(thinking["thinkingLevel"] as? String == "low", "размышления перед ответом — это пауза на экране")
    }

    @Test("Модели, не знающей про размышления, поле не отправляем вовсе")
    func thinkingConfigIsOmittedWhenTurnedOff() async throws {
        let transport = ScriptedTransport(lines: [GeminiSSE.finished("STOP")])
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: transport,
            configuration: GeminiProvider.Configuration(thinkingLevel: nil)
        )

        _ = await drainStream(provider.stream(fixture()))

        let body = try #require(jsonBody(await transport.sent.first?.httpBody))
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["thinkingConfig"] == nil)
    }

    @Test("Скриншот прикладывается к пользовательскому сообщению перед текстом")
    func screenshotIsAttachedAheadOfTheText() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let transport = ScriptedTransport(lines: [GeminiSSE.finished("STOP")])
        let provider = GeminiProvider(apiKey: { "key" }, transport: transport)

        _ = await drainStream(provider.stream(fixture(screenshot: png)))

        let body = try #require(jsonBody(await transport.sent.first?.httpBody))
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])

        #expect(parts.count == 2)
        let inline = try #require(parts.first?["inlineData"] as? [String: Any])
        #expect(inline["mimeType"] as? String == "image/png")
        #expect(inline["data"] as? String == png.base64EncodedString())
        #expect(parts.last?["text"] as? String != nil)
    }

    @Test("Gemini принимает изображения — про это говорим честно")
    func capabilitiesSayImagesAreAccepted() {
        let provider = GeminiProvider(apiKey: { nil })

        #expect(provider.capabilities.acceptsImages)
        #expect(provider.capabilities.streams)
    }

    // MARK: - Ошибки

    @Test("Ключ не задан — в сеть не идём вовсе")
    func missingKeyNeverReachesTheNetwork() async {
        let transport = ScriptedTransport(lines: [GeminiSSE.finished("STOP")])
        let provider = GeminiProvider(apiKey: { nil }, transport: transport)

        #expect(await drainStream(provider.stream(fixture())).error as? LLMFailure == .missingKey)
        #expect(await transport.sent.isEmpty)
    }

    @Test("Отклонённый ключ Google отдаёт как 400 — всё равно показываем это как отклонённый ключ")
    func rejectedKeyIsUnauthorizedEvenThoughGoogleCallsItBadRequest() async {
        let provider = GeminiProvider(
            apiKey: { "AIza-wrong" },
            transport: ScriptedTransport(
                statusCode: 400,
                lines: [
                    googleError(
                        code: 400,
                        status: "INVALID_ARGUMENT",
                        message: "API key not valid. Please pass a valid API key.",
                        reason: "API_KEY_INVALID"
                    )
                ]
            )
        )

        #expect(await drainStream(provider.stream(fixture())).error as? LLMFailure == .unauthorized)
    }

    @Test("Квота исчерпана — это throttled")
    func quotaBecomesThrottled() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(
                statusCode: 429,
                lines: [googleError(code: 429, status: "RESOURCE_EXHAUSTED", message: "Quota exceeded")]
            )
        )

        #expect(await drainStream(provider.stream(fixture())).error as? LLMFailure == .throttled)
    }

    @Test("Модель перегружена — это тоже throttled: пользователю нужно то же самое")
    func overloadBecomesThrottled() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(
                statusCode: 503,
                lines: [googleError(code: 503, status: "UNAVAILABLE", message: "The model is overloaded")]
            )
        )

        #expect(await drainStream(provider.stream(fixture())).error as? LLMFailure == .throttled)
    }

    @Test("Остальные отказы доносят формулировку провайдера дословно")
    func otherFailuresKeepTheProvidersWording() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(
                statusCode: 400,
                lines: [
                    googleError(
                        code: 400,
                        status: "INVALID_ARGUMENT",
                        message: "maxOutputTokens: слишком много"
                    )
                ]
            )
        )

        #expect(
            await drainStream(provider.stream(fixture())).error as? LLMFailure
                == .provider("maxOutputTokens: слишком много")
        )
    }

    @Test("Ошибку, завёрнутую в массив, тоже понимаем")
    func arrayWrappedErrorIsUnderstood() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(
                statusCode: 403,
                lines: ["[", googleError(code: 403, status: "PERMISSION_DENIED", message: "нет доступа"), "]"]
            )
        )

        #expect(await drainStream(provider.stream(fixture())).error as? LLMFailure == .unauthorized)
    }

    @Test("Отказ без внятного тела всё равно превращается в понятную ошибку")
    func unreadableFailureStillReachesTheUser() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(statusCode: 502, lines: ["<html>bad gateway</html>"])
        )

        let failure = await drainStream(provider.stream(fixture())).error as? LLMFailure
        #expect(failure != nil)
        #expect(failure?.message.isEmpty == false)
    }

    // MARK: - Причина в том же чанке, что и текст

    /// Ровно та форма, которой Google закрывает `streamGenerateContent?alt=sse`,
    /// и для короткой подсказки — единственный чанк ответа. Пока `decode`
    /// возвращал одно событие на строку и проверял текст первым, причина не
    /// читалась никогда: sentinel `[DONE]` в этом диалекте отсутствует, поэтому
    /// **каждый** дописанный ответ объявлялся обрывом связи.
    @Test("Текст и STOP пришли одним чанком — это конец ответа, а не обрыв")
    func aFinishReasonBesideTheTextClosesTheStream() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.textAndFinish("Я бы взял составной индекс.", "STOP"),
            ])
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.fragments == ["Я бы взял составной индекс."])
        #expect(answer.error == nil, "штатно дописанный ответ обрывом не является")
    }

    /// Обратная сторона того же дефекта: чанк с `MAX_TOKENS` по природе события
    /// несёт и последние токены, поэтому отдельного пустого чанка с этой
    /// причиной сервер не шлёт — и ветка бюджета была в живом трафике
    /// недостижима, а пользователь вместо «упёрлась в лимит» видел «соединение
    /// закрылось».
    @Test("Текст и MAX_TOKENS одним чанком — обрыв назван бюджетом, а не связью")
    func aBudgetCutBesideTheTextIsNamedCorrectly() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.text("Начало ответа "),
                GeminiSSE.textAndFinish("и хвост, обрезанный на", "MAX_TOKENS"),
            ])
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.fragments == ["Начало ответа ", "и хвост, обрезанный на"])
        #expect(answer.error as? SuggestionCutoff == .budget)
    }

    @Test("Фильтр остановил ответ посреди генерации — начатое остаётся, дальше ошибка")
    func safetyStopKeepsWhatArrived() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.text("Начну отвечать"),
                GeminiSSE.finished("SAFETY"),
            ])
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.fragments == ["Начну отвечать"])
        // Договор «то, что уже пришло, не пропадает» тот же, но теперь он
        // доезжает до экрана: отказ поверх показанного текста стал обрывом,
        // потому что карточка при `.failed` рисует причину ВМЕСТО ответа —
        // и фраза исчезала у пользователя из-под глаз, пока он её читал.
        #expect(answer.error as? SuggestionCutoff == .stopped("Gemini прервал ответ: SAFETY."))
    }

    @Test("Запрос отклонён фильтром до генерации — это ошибка, а не пустая подсказка")
    func blockedPromptBecomesAFailure() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [GeminiSSE.chunk(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#)])
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.fragments.isEmpty)
        #expect(answer.error as? LLMFailure == .provider("Gemini отклонил запрос: SAFETY."))
    }

    /// Решение прежнее и не пересматривалось: упереться в бюджет — **не ошибка**,
    /// текст остаётся подсказкой и читается вслух. Изменился только механизм:
    /// раньше это молча выдавалось за нормальное окончание ответа, теперь под
    /// текстом стоит причина. `LLMFailure` тут по-прежнему быть не должно.
    @Test("Ответ упёрся в лимит токенов — не ошибка, но об обрыве сказано")
    func hittingTheTokenBudgetIsNotAFailure() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: ScriptedTransport(lines: [
                GeminiSSE.text("Длинный ответ"),
                GeminiSSE.finished("MAX_TOKENS"),
            ])
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.fragments == ["Длинный ответ"])
        #expect(answer.error as? LLMFailure == nil, "обрыв по бюджету — не отказ провайдера")
        #expect(answer.error as? SuggestionCutoff == .budget)
    }

    @Test("Сеть отвалилась — это ошибка провайдера, а не молчаливо пустая подсказка")
    func transportFailureBecomesAProviderFailure() async {
        let provider = GeminiProvider(
            apiKey: { "key" },
            transport: UnreachableTransport(error: URLError(.notConnectedToInternet))
        )

        let answer = await drainStream(provider.stream(fixture()))

        #expect(answer.fragments.isEmpty)
        #expect(answer.error is LLMFailure)
    }

    // MARK: - Отмена

    @Test("Новая реплика отменила подсказку — HTTP-запрос брошен, а не досчитывается в фоне")
    func cancellationAbandonsTheRequest() async {
        let transport = ScriptedTransport(
            lines: [GeminiSSE.text("Начало ответа")],
            keepsConnectionOpen: true
        )
        let provider = GeminiProvider(apiKey: { "key" }, transport: transport)
        let received = FragmentCollector()

        let consumer = Task {
            for try await fragment in provider.stream(fixture()) {
                await received.append(fragment)
            }
        }

        #expect(await waitUntil { await received.count == 1 }, "стрим должен был начать отдавать фрагменты")

        consumer.cancel()

        #expect(
            await waitUntil { await transport.wasAbandoned },
            "отмена обязана оборвать соединение, а не оставить его дочитываться"
        )
    }

    // MARK: - Выбор в настройках

    @Test("Фабрика собирает Gemini с моделью и адресом из предустановки")
    func factoryBuildsGeminiFromThePreset() throws {
        let provider = try ProviderFactory.make(
            selection: ProviderSelection(presetID: "gemini", baseURL: "", model: ""),
            key: { "key" }
        )

        #expect(provider is GeminiProvider)
        #expect(provider.capabilities.acceptsImages)
    }

    @Test("Модель и адрес, вписанные в настройках, перебивают предустановку")
    func typedOverridesWin() throws {
        let configuration = try GeminiProvider.Configuration.resolve(
            preset: #require(ProviderFactory.preset(id: "gemini")),
            selection: ProviderSelection(
                presetID: "gemini",
                baseURL: "http://localhost:8787/v1beta",
                model: "gemini-3.5-flash"
            )
        )

        #expect(configuration.baseURL == "http://localhost:8787/v1beta")
        #expect(configuration.model == "gemini-3.5-flash")
    }
}

// MARK: - Транспорт-дублёр

/// Replays canned lines and remembers whether the connection was abandoned.
private actor ScriptedTransport: StreamingHTTPTransport {

    private(set) var sent: [URLRequest] = []
    /// Set when the line stream is terminated by cancellation rather than by the
    /// body ending — the observable half of "the request was really dropped".
    private(set) var wasAbandoned = false

    private let statusCode: Int
    private let scripted: [String]
    private let keepsConnectionOpen: Bool

    init(statusCode: Int = 200, lines: [String] = [], keepsConnectionOpen: Bool = false) {
        self.statusCode = statusCode
        self.scripted = lines
        self.keepsConnectionOpen = keepsConnectionOpen
    }

    func send(_ request: URLRequest) async throws -> HTTPLineStream {
        sent.append(request)
        let lines = scripted
        let staysOpen = keepsConnectionOpen
        let body = AsyncThrowingStream<String, any Error> { continuation in
            for line in lines { continuation.yield(line) }
            if !staysOpen { continuation.finish() }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                Task { await self?.markAbandoned() }
            }
        }
        return HTTPLineStream(statusCode: statusCode, lines: body)
    }

    private func markAbandoned() {
        wasAbandoned = true
    }
}

private struct UnreachableTransport: StreamingHTTPTransport {
    let error: any Error

    func send(_ request: URLRequest) async throws -> HTTPLineStream {
        throw error
    }
}

private actor FragmentCollector {
    private(set) var fragments: [String] = []

    var count: Int { fragments.count }

    func append(_ fragment: String) {
        fragments.append(fragment)
    }
}

// MARK: - Хелперы

/// Lines of Gemini's event stream, in the shape they arrive in: each one carries
/// a whole `GenerateContentResponse`, not a delta.
private enum GeminiSSE {

    static func text(_ value: String) -> String {
        chunk(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"\#(value)"}]},"index":0}],"modelVersion":"gemini-3.6-flash"}"#)
    }

    static func finished(_ reason: String) -> String {
        chunk(#"{"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"\#(reason)","index":0}]}"#)
    }

    /// Настоящая форма закрывающего чанка: текст и причина вместе.
    ///
    /// Существующий `finished(_:)` кладёт `"parts":[]` — форму, которой Google в
    /// норме не присылает, и из-за этого все прежние тесты Gemini проходили мимо
    /// дефекта: `decode` возвращал текст и терял причину, поток заканчивался без
    /// закрывающего события, и каждый дописанный ответ объявлялся обрывом связи.
    static func textAndFinish(_ value: String, _ reason: String) -> String {
        chunk(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"\#(value)"}]},"finishReason":"\#(reason)","index":0}],"usageMetadata":{"promptTokenCount":12}}"#)
    }

    static func chunk(_ json: String) -> String { "data: \(json)" }
}

private func googleError(code: Int, status: String, message: String, reason: String? = nil) -> String {
    let details = reason.map {
        #","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"\#($0)"}]"#
    } ?? ""
    return #"{"error":{"code":\#(code),"message":"\#(message)","status":"\#(status)"\#(details)}}"#
}

private func jsonBody(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func fixture(screenshot: Data? = nil) -> SuggestionRequest {
    SuggestionRequest(
        systemPrompt: "Ты — GhostMeet, скрытый real-time copilot.",
        userPrompt: "Недавний разговор:\nThem: расскажите про GCD\n\nСделай то, что нужно мне прямо сейчас.",
        screenshot: screenshot,
        maxTokens: AssistPrompt.maxTokens
    )
}

/// Reads a stream to its end, keeping both what arrived and how it ended.
private func drainStream(
    _ stream: AsyncThrowingStream<String, any Error>
) async -> (fragments: [String], error: (any Error)?) {
    var fragments: [String] = []
    do {
        for try await fragment in stream { fragments.append(fragment) }
        return (fragments, nil)
    } catch {
        return (fragments, error)
    }
}

/// Waits for something that happens on another task, without sleeping blindly.
///
/// Предел — общий `TestWait.budget`, а не своё число: до 0.3.2 здесь стояли две
/// секунды, и на релизном прогоне 0.3.2 они не выдержали ровно так, как
/// предсказано в `TestWait` — три отмены подряд в трёх провайдерских сюитах,
/// на второй сборке за цикл. Стенд ждёт заглушку потока и выходит в тот же
/// момент, когда условие стало верным; длинный предел не стоит ничего.
private func waitUntil(
    within timeout: Duration = TestWait.budget,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
