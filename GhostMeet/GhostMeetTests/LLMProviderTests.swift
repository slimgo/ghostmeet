//
//  LLMProviderTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// The provider seam, driven without a socket: a scripted transport replays what
/// Claude would put on the wire, so what is checked is the behaviour the rest of
/// the app depends on — fragments arriving as they are written, failures the user
/// can act on, and a cancelled suggestion that actually stops costing money.
@Suite("Провайдер Claude")
struct LLMProviderTests {

    // MARK: - Стриминг

    @Test("Подсказка приходит фрагментами по мере генерации, а не целиком в конце")
    func answerArrivesInFragments() async {
        let transport = ScriptedTransport(lines: [
            SSE.messageStart,
            SSE.contentBlockStart,
            SSE.text("Расскажу "),
            SSE.text("про GCD."),
            SSE.messageStop,
        ])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.error == nil)
        #expect(answer.fragments == ["Расскажу ", "про GCD."], "служебные события подсказкой не становятся")
    }

    @Test("Поток оборвался без message_stop — текст остаётся, и об обрыве сказано")
    func truncatedStreamKeepsWhatArrivedAndSaysSo() async {
        let transport = ScriptedTransport(lines: [SSE.text("Начало ответа")])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.fragments == ["Начало ответа"])
        #expect(answer.error as? SuggestionCutoff == .connection)
    }

    @Test("Claude сказал max_tokens — ответ оборван бюджетом, а не дописан")
    func hittingTheBudgetIsReported() async {
        let transport = ScriptedTransport(lines: [
            SSE.text("Половина ответа"),
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.fragments == ["Половина ответа"])
        #expect(answer.error as? SuggestionCutoff == .budget)
    }

    /// Обычное окончание не должно попадать в обрыв: `end_turn` приходит тем же
    /// событием `message_delta`, что и `max_tokens`, и различать их обязано
    /// поле, а не порядок.
    /// Классификатор Anthropic останавливает генерацию и возвращает уже
    /// написанное. Раньше `refusal` попадал в `default: .ignored`, следом
    /// `message_stop` закрывал поток как нормальный, и половина фразы стояла на
    /// карточке законченной подсказкой — её читали вслух.
    @Test("Claude сказал refusal — половина ответа остаётся, но названа обрывом")
    func aRefusalAfterTextBecomesACutoff() async {
        let transport = ScriptedTransport(lines: [
            SSE.text("Я бы вынес это в отдельный сервис и"),
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.fragments == ["Я бы вынес это в отдельный сервис и"])
        #expect(answer.error as? SuggestionCutoff == .stopped("Модель отказалась продолжать."))
    }

    @Test("Claude упёрся в окно контекста — это тот же обрыв по бюджету")
    func aContextWindowStopIsABudgetCut() async {
        let transport = ScriptedTransport(lines: [
            SSE.text("Половина"),
            #"data: {"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"}}"#,
        ])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.error as? SuggestionCutoff == .budget)
    }

    /// Без `message_stop` намеренно: событие может не доехать, и штатно
    /// договоривший ответ не должен из-за этого получить строку об обрыве.
    @Test("Claude сказал end_turn — это нормальный конец, без строки об обрыве")
    func aNormalStopIsNotACutoff() async {
        let transport = ScriptedTransport(lines: [
            SSE.text("Целый ответ"),
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.fragments == ["Целый ответ"])
        #expect(answer.error == nil)
    }

    // MARK: - Форма запроса

    @Test("Запрос уходит стримом, с ключом и версией API в заголовках")
    func requestCarriesTheKeyAndAsksForAStream() async throws {
        let transport = ScriptedTransport(lines: [SSE.text("ок"), SSE.messageStop])
        let provider = ClaudeProvider(apiKey: { "sk-test-key" }, transport: transport)
        let request = SuggestionRequest.fixture()

        _ = await drain(provider.stream(request))

        let sent = try #require(await transport.sent.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test-key")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try #require(jsonObject(sent.httpBody))
        #expect(body["stream"] as? Bool == true)
        #expect(body["system"] as? String == request.systemPrompt)
        #expect(body["max_tokens"] as? Int == request.maxTokens)
        #expect(body["model"] as? String == ClaudeProvider.Configuration.default.model)
    }

    @Test("Транскрипт уходит в пользовательском сообщении")
    func transcriptGoesIntoTheUserMessage() async throws {
        let transport = ScriptedTransport(lines: [SSE.messageStop])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)
        let request = SuggestionRequest.fixture()

        _ = await drain(provider.stream(request))

        let body = try #require(jsonObject(await transport.sent.first?.httpBody))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")

        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == request.userPrompt)
    }

    @Test("Скриншот прикладывается к пользовательскому сообщению перед текстом")
    func screenshotIsAttachedAheadOfTheText() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let transport = ScriptedTransport(lines: [SSE.messageStop])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        _ = await drain(provider.stream(.fixture(screenshot: png)))

        let body = try #require(jsonObject(await transport.sent.first?.httpBody))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])

        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content.first?["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == png.base64EncodedString())
    }

    // MARK: - Ошибки

    @Test("Ключ не задан — в сеть не идём вовсе")
    func missingKeyNeverReachesTheNetwork() async {
        let transport = ScriptedTransport(lines: [SSE.messageStop])
        let provider = ClaudeProvider(apiKey: { nil }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.error as? LLMFailure == .missingKey)
        #expect(await transport.sent.isEmpty, "без ключа запрос отправлять нечем")
    }

    @Test("В Keychain лежат одни пробелы — это тот же отсутствующий ключ")
    func blankKeyCountsAsMissing() async {
        let transport = ScriptedTransport(lines: [SSE.messageStop])
        let provider = ClaudeProvider(apiKey: { "   \n" }, transport: transport)

        #expect(await drain(provider.stream(.fixture())).error as? LLMFailure == .missingKey)
        #expect(await transport.sent.isEmpty)
    }

    @Test("Провайдер отклонил ключ — это unauthorized, а не безымянная ошибка")
    func rejectedKeyBecomesUnauthorized() async {
        let provider = ClaudeProvider(
            apiKey: { "sk-wrong" },
            transport: ScriptedTransport(
                statusCode: 401,
                lines: [errorBody(type: "authentication_error", message: "invalid x-api-key")]
            )
        )

        #expect(await drain(provider.stream(.fixture())).error as? LLMFailure == .unauthorized)
    }

    @Test("Провайдер ограничил частоту — это throttled")
    func rateLimitBecomesThrottled() async {
        let provider = ClaudeProvider(
            apiKey: { "sk-test" },
            transport: ScriptedTransport(
                statusCode: 429,
                lines: [errorBody(type: "rate_limit_error", message: "slow down")]
            )
        )

        #expect(await drain(provider.stream(.fixture())).error as? LLMFailure == .throttled)
    }

    @Test("Провайдер перегружен — это тоже throttled: пользователю нужно то же самое")
    func overloadBecomesThrottled() async {
        let provider = ClaudeProvider(
            apiKey: { "sk-test" },
            transport: ScriptedTransport(
                statusCode: 529,
                lines: [errorBody(type: "overloaded_error", message: "overloaded")]
            )
        )

        #expect(await drain(provider.stream(.fixture())).error as? LLMFailure == .throttled)
    }

    @Test("Остальные отказы доносят формулировку провайдера дословно")
    func otherFailuresKeepTheProvidersWording() async {
        let provider = ClaudeProvider(
            apiKey: { "sk-test" },
            transport: ScriptedTransport(
                statusCode: 400,
                lines: [errorBody(type: "invalid_request_error", message: "max_tokens: слишком много")]
            )
        )

        #expect(
            await drain(provider.stream(.fixture())).error as? LLMFailure
                == .provider("max_tokens: слишком много")
        )
    }

    @Test("Отказ без внятного тела всё равно превращается в понятную ошибку")
    func unreadableFailureStillReachesTheUser() async {
        let provider = ClaudeProvider(
            apiKey: { "sk-test" },
            transport: ScriptedTransport(statusCode: 502, lines: ["<html>bad gateway</html>"])
        )

        let failure = await drain(provider.stream(.fixture())).error as? LLMFailure
        #expect(failure != nil)
        #expect(failure?.message.isEmpty == false)
    }

    @Test("Ошибка пришла посреди генерации — начатая подсказка обрывается ошибкой")
    func midStreamErrorStopsTheSuggestion() async {
        let transport = ScriptedTransport(lines: [
            SSE.text("Начну отвечать"),
            SSE.error(type: "overloaded_error", message: "overloaded"),
        ])
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.fragments == ["Начну отвечать"], "то, что уже пришло, не пропадает")
        // Договор «то, что уже пришло, не пропадает» тот же, но теперь он
        // доезжает до экрана: отказ поверх показанного текста стал обрывом,
        // потому что карточка при `.failed` рисует причину ВМЕСТО ответа —
        // и фраза исчезала у пользователя из-под глаз, пока он её читал.
        #expect(answer.error as? SuggestionCutoff == .stopped(LLMFailure.throttled.message))
    }

    @Test("Сеть отвалилась — это ошибка провайдера, а не молчаливо пустая подсказка")
    func transportFailureBecomesAProviderFailure() async {
        let provider = ClaudeProvider(
            apiKey: { "sk-test" },
            transport: FailingTransport(error: URLError(.notConnectedToInternet))
        )

        let answer = await drain(provider.stream(.fixture()))

        #expect(answer.fragments.isEmpty)
        #expect(answer.error is LLMFailure)
    }

    // MARK: - Отмена

    @Test("Новая реплика отменила подсказку — HTTP-запрос брошен, а не досчитывается в фоне")
    func cancellationAbandonsTheRequest() async {
        let transport = ScriptedTransport(
            lines: [SSE.text("Начало ответа")],
            keepsConnectionOpen: true
        )
        let provider = ClaudeProvider(apiKey: { "sk-test" }, transport: transport)
        let received = Collector()

        let consumer = Task {
            for try await fragment in provider.stream(.fixture()) {
                await received.append(fragment)
            }
        }

        let started = await eventually { await received.count == 1 }
        #expect(started, "стрим должен был начать отдавать фрагменты")

        consumer.cancel()

        #expect(
            await eventually { await transport.wasAbandoned },
            "отмена обязана оборвать соединение, а не оставить его дочитываться"
        )
    }
}

// MARK: - Транспорт-дублёр

/// A transport that replays canned lines and remembers whether the connection
/// was abandoned.
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

/// A transport that cannot reach the network at all.
private struct FailingTransport: StreamingHTTPTransport {
    let error: any Error

    func send(_ request: URLRequest) async throws -> HTTPLineStream {
        throw error
    }
}

private actor Collector {
    private(set) var fragments: [String] = []

    var count: Int { fragments.count }

    func append(_ fragment: String) {
        fragments.append(fragment)
    }
}

// MARK: - Хелперы

/// Lines of Claude's event stream, in the shape they arrive in.
private enum SSE {
    static let messageStart = event(#"{"type":"message_start","message":{"id":"msg_1"}}"#)
    static let contentBlockStart =
        event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
    static let messageStop = event(#"{"type":"message_stop"}"#)

    static func text(_ value: String) -> String {
        event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(value)"}}"#)
    }

    static func error(type: String, message: String) -> String {
        event(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#)
    }

    private static func event(_ json: String) -> String { "data: \(json)" }
}

/// The body of a non-streaming failure response.
private func errorBody(type: String, message: String) -> String {
    #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#
}

private func jsonObject(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Reads a stream to its end, keeping both what arrived and how it ended.
private func drain(
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
private func eventually(
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

private extension SuggestionRequest {
    static func fixture(screenshot: Data? = nil) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: "Ты — GhostMeet, скрытый real-time copilot.",
            userPrompt: "Недавний разговор:\nThem: расскажите про GCD\n\nСделай то, что нужно мне прямо сейчас.",
            screenshot: screenshot,
            maxTokens: AssistPrompt.maxTokens
        )
    }
}
