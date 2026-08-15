//
//  OpenAICompatibleProviderTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// The one provider that stands for eight servers, driven without a socket.
///
/// What is checked is what the rest of the app leans on: fragments arriving as
/// they are written, a cancelled suggestion that really drops the connection,
/// failures phrased so the user can act, and — because `Solve on screen` is the
/// primary mode of this scenario — a screenshot that reaches only the servers
/// that accept one.
@Suite("OpenAI-совместимый провайдер")
struct OpenAICompatibleProviderTests {

    // MARK: - Стриминг

    @Test("Подсказка приходит фрагментами по мере генерации, а не целиком в конце")
    func answerArrivesInFragments() async throws {
        let transport = ChunkTransport(lines: [
            Chunk.roleOnly,
            Chunk.text("Расскажу "),
            Chunk.text("про GCD."),
            Chunk.done,
        ])
        let provider = try makeProvider(presetID: "openai", transport: transport)

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.error == nil)
        #expect(answer.fragments == ["Расскажу ", "про GCD."], "служебные дельты подсказкой не становятся")
    }

    @Test("Шлюз досылает служебные строки — на подсказку они не влияют")
    func bookkeepingLinesAreIgnored() async throws {
        let transport = ChunkTransport(lines: [
            Chunk.keepAlive,
            "",
            Chunk.text("Ответ"),
            Chunk.emptyContent,
            Chunk.usageOnly,
            Chunk.done,
        ])
        let provider = try makeProvider(presetID: "openrouter", transport: transport)

        #expect(await collect(provider.stream(.sample())).fragments == ["Ответ"])
    }

    @Test("Поток оборвался без [DONE] — текст остаётся, и об обрыве сказано")
    func truncatedStreamKeepsWhatArrivedAndSaysSo() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(lines: [Chunk.text("Начало ответа")])
        )

        let answer = await collect(provider.stream(.sample()))

        // Половина ответа по-прежнему доезжает до пользователя — это половина
        // договора и она не менялась.
        #expect(answer.fragments == ["Начало ответа"])
        // Вторая половина новая: раньше здесь было `nil`, и оборванный на
        // полуслове ответ выглядел на карточке как короткий.
        #expect(answer.error as? SuggestionCutoff == .connection)
    }

    @Test("Модель упёрлась в лимит токенов — сказано, что ответ оборван бюджетом")
    func hittingTheBudgetIsReported() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(lines: [
                Chunk.text("Половина ответа"),
                #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#,
                Chunk.done,
            ])
        )

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments == ["Половина ответа"])
        #expect(answer.error as? SuggestionCutoff == .budget)
    }

    /// Ложная тревога опаснее той тишины, которую всё это чинит: половина
    /// каталога — чужие шлюзы и локальные серверы, и не все закрывают поток
    /// sentinel-строкой. Штатно договоривший ответ не должен получать строку
    /// «соединение закрылось».
    @Test("Штатное окончание без [DONE] обрывом не считается")
    func aNormalFinishWithoutTheSentinelIsNotACutoff() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(lines: [
                Chunk.text("Целый ответ"),
                #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            ])
        )

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments == ["Целый ответ"])
        #expect(answer.error == nil)
    }

    /// Так закрывает поток vLLM и часть шлюзов: последняя дельта и признак в
    /// одном чанке. Пока `decode` возвращал одно событие и читал текст первым,
    /// признак терялся — обрыв по бюджету не замечался вовсе, и правка про
    /// оборванный ответ на этих серверах не работала.
    @Test("Текст и finish_reason одним чанком — обрыв по бюджету замечен")
    func aBudgetCutBesideTheTextIsSeen() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(lines: [
                #"data: {"choices":[{"delta":{"content":" попада"},"finish_reason":"length"}]}"#,
                Chunk.done,
            ])
        )

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments == [" попада"])
        #expect(answer.error as? SuggestionCutoff == .budget)
    }

    @Test("Текст и stop одним чанком, без [DONE] — обрывом не считается")
    func aNormalFinishBesideTheTextIsNotACutoff() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(lines: [
                #"data: {"choices":[{"delta":{"content":" и дате."},"finish_reason":"stop"}]}"#,
            ])
        )

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments == [" и дате."])
        #expect(answer.error == nil)
    }

    /// Модель отказалась и положила отказ в `delta.refusal` — поле, которого мы
    /// не читаем, — после чего честно закрыла поток. Раньше это оседало как
    /// `.complete` с пустым текстом: карточка показывала «…» под заголовком
    /// «подсказка» и ни слова о том, что ответа нет.
    @Test("Поток закрыт по правилам и пуст — сказано, что ответа нет")
    func aProperlyClosedEmptyStreamIsReported() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(lines: [
                #"data: {"choices":[{"delta":{"refusal":"I can't help with that."},"finish_reason":null}]}"#,
                #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
                Chunk.done,
            ])
        )

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments.isEmpty)
        #expect(answer.error as? SuggestionCutoff == .empty)
    }

    @Test("Поток закрылся, не сказав ни слова — это не пустая подсказка молча")
    func anEmptyStreamIsReported() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(lines: [Chunk.usageOnly])
        )

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments.isEmpty)
        #expect(answer.error as? SuggestionCutoff == .empty)
    }

    // MARK: - Форма запроса

    @Test("Запрос уходит стримом на адрес предустановки, с ключом в заголовке")
    func requestCarriesTheKeyAndAsksForAStream() async throws {
        let transport = ChunkTransport(lines: [Chunk.done])
        let provider = try makeProvider(presetID: "openrouter", key: "sk-or-key", transport: transport)
        let request = SuggestionRequest.sample()

        _ = await collect(provider.stream(request))

        let sent = try #require(await transport.sent.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "authorization") == "Bearer sk-or-key")

        let body = try #require(decodeJSON(sent.httpBody))
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "anthropic/claude-opus-5")
        #expect(body["max_tokens"] as? Int == request.maxTokens)
    }

    @Test("Системный промпт и контекст едут разными сообщениями")
    func promptAndContextTravelAsTwoMessages() async throws {
        let transport = ChunkTransport(lines: [Chunk.done])
        let provider = try makeProvider(presetID: "openai", transport: transport)
        let request = SuggestionRequest.sample()

        _ = await collect(provider.stream(request))

        let body = try #require(decodeJSON(await transport.sent.first?.httpBody))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.first?["content"] as? String == request.systemPrompt)
        #expect(
            messages.last?["content"] as? String == request.userPrompt,
            "без картинки content — обычная строка: её понимает даже самый старый локальный сервер"
        )
    }

    @Test("OpenAI получает max_completion_tokens: max_tokens он не принимает вовсе")
    func openAIGetsItsOwnSpellingOfTheTokenBudget() async throws {
        let transport = ChunkTransport(lines: [Chunk.done])
        let provider = try makeProvider(presetID: "openai", transport: transport)
        let request = SuggestionRequest.sample()

        _ = await collect(provider.stream(request))

        let body = try #require(decodeJSON(await transport.sent.first?.httpBody))
        #expect(body["max_completion_tokens"] as? Int == request.maxTokens)
        #expect(body["max_tokens"] == nil, "лишнее поле OpenAI отвергает, а не игнорирует")
    }

    @Test("Свой адрес, указывающий на OpenAI, получает ту же форму бюджета")
    func aHandTypedOpenAIAddressStillGetsTheRightField() throws {
        let configuration = try makeConfiguration(
            presetID: "lmstudio",
            baseURL: "https://api.openai.com/v1"
        )

        #expect(configuration.tokenLimit == .maxCompletionTokens)
    }

    @Test("Скриншот уходит data-URL'ом перед текстом")
    func screenshotIsAttachedAheadOfTheText() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let transport = ChunkTransport(lines: [Chunk.done])
        let provider = try makeProvider(presetID: "openai", transport: transport)

        _ = await collect(provider.stream(.sample(screenshot: png)))

        let body = try #require(decodeJSON(await transport.sent.first?.httpBody))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])

        #expect(content.map { $0["type"] as? String } == ["image_url", "text"])
        let image = try #require(content.first?["image_url"] as? [String: Any])
        #expect(image["url"] as? String == "data:image/png;base64,\(png.base64EncodedString())")
    }

    @Test("Текстовому провайдеру скриншот не отправляется вовсе — иначе это провалившийся запрос")
    func textOnlyProviderNeverSeesTheScreenshot() async throws {
        let transport = ChunkTransport(lines: [Chunk.done])
        let provider = try makeProvider(presetID: "deepseek", transport: transport)

        #expect(provider.capabilities.acceptsImages == false)

        _ = await collect(provider.stream(.sample(screenshot: Data([0x89, 0x50]))))

        let sent = try #require(await transport.sent.first)
        let body = try #require(decodeJSON(sent.httpBody))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] is String, "картинке в текстовом запросе места нет")

        let raw = String(data: try #require(sent.httpBody), encoding: .utf8) ?? ""
        #expect(raw.contains("image_url") == false)
    }

    @Test("Локальный сервер работает без ключа — заголовка авторизации просто нет")
    func localServerNeedsNoKey() async throws {
        let transport = ChunkTransport(lines: [Chunk.text("локальный ответ"), Chunk.done])
        let provider = try makeProvider(presetID: "ollama", key: nil, transport: transport)

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments == ["локальный ответ"])
        let sent = try #require(await transport.sent.first)
        #expect(sent.value(forHTTPHeaderField: "authorization") == nil)
        #expect(sent.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    // MARK: - Ошибки

    @Test("Ключ не задан — в сеть не идём вовсе")
    func missingKeyNeverReachesTheNetwork() async throws {
        let transport = ChunkTransport(lines: [Chunk.done])
        let provider = try makeProvider(presetID: "openai", key: nil, transport: transport)

        #expect(await collect(provider.stream(.sample())).error as? LLMFailure == .missingKey)
        #expect(await transport.sent.isEmpty, "без ключа запрос отправлять нечем")
    }

    @Test("В Keychain лежат одни пробелы — это тот же отсутствующий ключ")
    func blankKeyCountsAsMissing() async throws {
        let transport = ChunkTransport(lines: [Chunk.done])
        let provider = try makeProvider(presetID: "kimi", key: "  \n ", transport: transport)

        #expect(await collect(provider.stream(.sample())).error as? LLMFailure == .missingKey)
        #expect(await transport.sent.isEmpty)
    }

    @Test("Провайдер отклонил ключ — это unauthorized, а не безымянная ошибка")
    func rejectedKeyBecomesUnauthorized() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(
                statusCode: 401,
                lines: [errorBody(type: "invalid_request_error", code: "invalid_api_key", message: "Incorrect API key")]
            )
        )

        #expect(await collect(provider.stream(.sample())).error as? LLMFailure == .unauthorized)
    }

    @Test("Провайдер ограничил частоту — это throttled")
    func rateLimitBecomesThrottled() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(
                statusCode: 429,
                lines: [errorBody(type: "rate_limit_error", code: "rate_limit_exceeded", message: "slow down")]
            )
        )

        #expect(await collect(provider.stream(.sample())).error as? LLMFailure == .throttled)
    }

    @Test("Шлюз ответил кодом в теле, а не в статусе — ошибка всё равно опознана")
    func numericCodeInTheBodyIsUnderstood() async throws {
        let transport = ChunkTransport(lines: [
            Chunk.text("Начну отвечать"),
            Chunk.error(code: 401, message: "No auth credentials found"),
        ])
        let provider = try makeProvider(presetID: "openrouter", transport: transport)

        let answer = await collect(provider.stream(.sample()))

        #expect(answer.fragments == ["Начну отвечать"], "то, что уже пришло, не пропадает")
        // Договор «то, что уже пришло, не пропадает» тот же, но теперь он
        // доезжает до экрана: отказ поверх показанного текста стал обрывом,
        // потому что карточка при `.failed` рисует причину ВМЕСТО ответа —
        // и фраза исчезала у пользователя из-под глаз, пока он её читал.
        #expect(answer.error as? SuggestionCutoff == .stopped(LLMFailure.unauthorized.message))
    }

    @Test("Остальные отказы доносят формулировку провайдера дословно")
    func otherFailuresKeepTheProvidersWording() async throws {
        let provider = try makeProvider(
            presetID: "polza",
            transport: ChunkTransport(
                statusCode: 400,
                lines: [errorBody(type: "invalid_request_error", code: "model_not_found", message: "Модель недоступна")]
            )
        )

        #expect(
            await collect(provider.stream(.sample())).error as? LLMFailure
                == .provider("Модель недоступна")
        )
    }

    @Test("Локальный сервер отвечает ошибкой-строкой — она и доходит до пользователя")
    func aBareStringErrorStillReachesTheUser() async throws {
        let provider = try makeProvider(
            presetID: "ollama",
            key: nil,
            transport: ChunkTransport(statusCode: 404, lines: [#"{"error":"model 'qwen3:8b' not found"}"#])
        )

        #expect(
            await collect(provider.stream(.sample())).error as? LLMFailure
                == .provider("model 'qwen3:8b' not found")
        )
    }

    @Test("Отказ без внятного тела всё равно превращается в понятную ошибку")
    func unreadableFailureStillReachesTheUser() async throws {
        let provider = try makeProvider(
            presetID: "openai",
            transport: ChunkTransport(statusCode: 502, lines: ["<html>bad gateway</html>"])
        )

        let failure = await collect(provider.stream(.sample())).error as? LLMFailure
        #expect(failure != nil)
        #expect(failure?.message.isEmpty == false)
    }

    @Test("Локальный сервер не запущен — в ошибке видно, куда не удалось достучаться")
    func unreachableLocalServerNamesTheAddress() async throws {
        let provider = try makeProvider(
            presetID: "lmstudio",
            key: nil,
            transport: DeadTransport(error: URLError(.cannotConnectToHost))
        )

        let failure = await collect(provider.stream(.sample())).error as? LLMFailure
        #expect(failure?.message.contains("localhost:1234") == true)
    }

    // MARK: - Отмена

    @Test("Новая реплика отменила подсказку — HTTP-запрос брошен, а не досчитывается в фоне")
    func cancellationAbandonsTheRequest() async throws {
        let transport = ChunkTransport(
            lines: [Chunk.text("Начало ответа")],
            keepsConnectionOpen: true
        )
        let provider = try makeProvider(presetID: "openai", transport: transport)
        let received = FragmentLog()

        let consumer = Task {
            for try await fragment in provider.stream(.sample()) {
                await received.append(fragment)
            }
        }

        #expect(
            await waitUntil { await received.count == 1 },
            "стрим должен был начать отдавать фрагменты"
        )

        consumer.cancel()

        #expect(
            await waitUntil { await transport.wasAbandoned },
            "отмена обязана оборвать соединение, а не оставить его дочитываться"
        )
    }

    // MARK: - Предустановки и фабрика

    @Test("Каждая OpenAI-совместимая предустановка собирается в готовый запрос без правок руками")
    func everyPresetIsUsableAsIs() throws {
        let family = ProviderFactory.presets.filter { $0.transport == .openAICompatible }
        #expect(family.count >= 8, "семейство — это весь список от OpenAI до llama.cpp")

        for preset in family {
            let built = try ProviderFactory.make(
                selection: ProviderSelection(presetID: preset.id, baseURL: "", model: ""),
                key: { "sk-test" }
            )
            let provider = try #require(built as? OpenAICompatibleProvider, "\(preset.name)")

            #expect(provider.name == preset.name)
            #expect(provider.configuration.model == preset.defaultModel)
            #expect(
                provider.configuration.endpoint.absoluteString
                    == preset.defaultBaseURL + "/chat/completions",
                "\(preset.name): адрес собирается из базового без сюрпризов"
            )
            #expect(provider.capabilities.acceptsImages == preset.capabilities.acceptsImages)
        }
    }

    @Test("Локальные предустановки ключа не требуют, облачные — требуют")
    func onlyCloudPresetsAskForAKey() throws {
        for id in ["ollama", "lmstudio", "llamacpp"] {
            #expect(try makeConfiguration(presetID: id).needsKey == false, "предустановка \(id)")
        }
        for id in ["openai", "openrouter", "polza", "deepseek", "kimi"] {
            #expect(try makeConfiguration(presetID: id).needsKey, "предустановка \(id)")
        }
    }

    @Test("Провайдера нет в списке — его адрес и модель вводятся руками")
    func anUnlistedProviderIsReachedByTyping() throws {
        let built = try ProviderFactory.make(
            selection: ProviderSelection(
                presetID: "lmstudio",
                baseURL: "https://llm.example.org/openai/v1",
                model: "some-new-model"
            ),
            key: { nil }
        )
        let provider = try #require(built as? OpenAICompatibleProvider)

        #expect(
            provider.configuration.endpoint.absoluteString
                == "https://llm.example.org/openai/v1/chat/completions"
        )
        #expect(provider.configuration.model == "some-new-model")
    }

    @Test("Лишний слэш и уже дописанный путь адрес не портят")
    func theAddressIsAssembledOnceAndOnlyOnce() throws {
        let withSlash = try makeConfiguration(presetID: "openai", baseURL: "https://api.example.com/v1/")
        let withPath = try makeConfiguration(
            presetID: "openai",
            baseURL: "https://api.example.com/v1/chat/completions"
        )

        #expect(withSlash.endpoint.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(withPath.endpoint.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test("Адрес введён с опечаткой — пользователь узнаёт об этом словами")
    func aMistypedAddressIsRefusedInWords() throws {
        #expect(throws: LLMFailure.self) {
            _ = try makeConfiguration(presetID: "openai", baseURL: "локалхост:1234")
        }
    }

    @Test("Пустое переопределение — это «как в предустановке», а не пустой адрес")
    func blankOverridesFallBackToThePreset() throws {
        let configuration = try makeConfiguration(presetID: "kimi", baseURL: "  ", model: "\n")

        #expect(configuration.endpoint.absoluteString == "https://api.moonshot.ai/v1/chat/completions")
        #expect(configuration.model == "kimi-k3")
    }

    @Test("Ни адреса, ни модели — провайдер не собирается молча")
    func aPresetWithoutAnAddressIsRefused() {
        let blank = ProviderPreset(
            id: "blank",
            name: "Без адреса",
            transport: .openAICompatible,
            defaultBaseURL: "",
            defaultModel: "",
            needsKey: false,
            capabilities: .textOnly
        )

        #expect(throws: LLMFailure.self) {
            _ = try OpenAICompatibleProvider.Configuration.resolve(
                preset: blank,
                selection: ProviderSelection(presetID: "blank", baseURL: "", model: "")
            )
        }
        #expect(throws: LLMFailure.self) {
            _ = try OpenAICompatibleProvider.Configuration.resolve(
                preset: blank,
                selection: ProviderSelection(presetID: "blank", baseURL: "http://localhost:1234/v1", model: "")
            )
        }
    }
}

// MARK: - Транспорт-дублёр

/// A transport that replays canned lines and remembers whether the connection was
/// abandoned.
private actor ChunkTransport: StreamingHTTPTransport {

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

/// A server that is not listening — the everyday state of a local provider.
private struct DeadTransport: StreamingHTTPTransport {
    let error: any Error

    func send(_ request: URLRequest) async throws -> HTTPLineStream {
        throw error
    }
}

private actor FragmentLog {
    private(set) var fragments: [String] = []

    var count: Int { fragments.count }

    func append(_ fragment: String) {
        fragments.append(fragment)
    }
}

// MARK: - Хелперы

private func makeConfiguration(
    presetID: String,
    baseURL: String = "",
    model: String = ""
) throws -> OpenAICompatibleProvider.Configuration {
    guard let preset = ProviderFactory.preset(id: presetID) else {
        throw LLMFailure.provider("нет предустановки «\(presetID)»")
    }
    return try .resolve(
        preset: preset,
        selection: ProviderSelection(presetID: presetID, baseURL: baseURL, model: model)
    )
}

private func makeProvider(
    presetID: String,
    key: String? = "sk-test",
    transport: any StreamingHTTPTransport
) throws -> OpenAICompatibleProvider {
    OpenAICompatibleProvider(
        configuration: try makeConfiguration(presetID: presetID),
        apiKey: { key },
        transport: transport
    )
}

/// Lines of the chat-completions event stream, in the shape they arrive in.
private enum Chunk {
    static let roleOnly = event(#"{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#)
    static let emptyContent = event(#"{"choices":[{"index":0,"delta":{"content":""}}]}"#)
    static let usageOnly = event(#"{"choices":[],"usage":{"total_tokens":42}}"#)
    static let done = "data: [DONE]"
    /// OpenRouter pads a slow stream with SSE comments.
    static let keepAlive = ": OPENROUTER PROCESSING"

    static func text(_ value: String) -> String {
        event(#"{"choices":[{"index":0,"delta":{"content":"\#(value)"}}]}"#)
    }

    static func error(code: Int, message: String) -> String {
        event(#"{"error":{"code":\#(code),"message":"\#(message)"}}"#)
    }

    private static func event(_ json: String) -> String { "data: \(json)" }
}

/// The body of a non-streaming failure response, OpenAI's shape.
private func errorBody(type: String, code: String, message: String) -> String {
    #"{"error":{"message":"\#(message)","type":"\#(type)","code":"\#(code)"}}"#
}

private func decodeJSON(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Reads a stream to its end, keeping both what arrived and how it ended.
private func collect(
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

private extension SuggestionRequest {
    static func sample(screenshot: Data? = nil) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: "Ты — GhostMeet, скрытый real-time copilot.",
            userPrompt: "Недавний разговор:\nThem: расскажите про GCD\n\nСделай то, что нужно мне прямо сейчас.",
            screenshot: screenshot,
            maxTokens: AssistPrompt.maxTokens
        )
    }
}
