//
//  OpenAIWireFormat.swift
//  GhostMeet
//

import Foundation

/// One decoded line of an OpenAI-compatible server-sent event stream.
nonisolated enum OpenAIStreamEvent: Equatable, Sendable {
    /// A fragment of the answer, to be appended to the suggestion as it grows.
    case text(String)
    /// The provider gave up mid-stream.
    case failure(LLMFailure)
    /// The model finished on its own.
    case done
    /// The model stopped before finishing. What arrived stays; the reason is
    /// shown under it.
    case cut(SuggestionCutoff)
}

/// Everything the OpenAI chat-completions dialect does with bytes: how a request
/// is encoded, how the event stream is read, and how a refusal becomes an
/// `LLMFailure` the user can act on.
///
/// Kept apart from `OpenAICompatibleProvider` so the format can be tested as pure
/// functions, with neither a socket nor a task involved. The dialect is shared by
/// OpenAI, OpenRouter, Polza.AI, DeepSeek, Kimi and every local server worth
/// using, so the tolerance here is deliberate: unknown fields are ignored rather
/// than fatal, because eight servers disagree about the details.
nonisolated enum OpenAIWireFormat {

    // MARK: - Request

    static func body(
        for request: SuggestionRequest,
        configuration: OpenAICompatibleProvider.Configuration
    ) throws -> Data {
        // Last line of defence for the rule that matters most here: a screenshot
        // handed to a text-only model is a failed request, not a worse answer,
        // and every press attaches one (ADR-0008).
        let screenshot = configuration.acceptsImages ? request.screenshot : nil

        let payload = ChatRequest(
            model: configuration.model,
            stream: true,
            messages: [
                Message(role: "system", content: .text(request.systemPrompt)),
                Message(role: "user", content: MessageContent(text: request.userPrompt, image: screenshot)),
            ],
            maxTokens: configuration.tokenLimit == .maxTokens ? request.maxTokens : nil,
            maxCompletionTokens: configuration.tokenLimit == .maxCompletionTokens ? request.maxTokens : nil
        )
        return try JSONEncoder().encode(payload)
    }

    // MARK: - Response

    /// Reads one line of the event stream into everything it carries.
    ///
    /// **A list and not one event, because one chunk can carry two facts.** The
    /// first version of the cutoff logic returned a single event and checked the
    /// text first, so `finish_reason` sitting on the same chunk as the last
    /// fragment was never seen — vLLM and a good half of the gateways close a
    /// stream exactly that way. The consequence was not a missed nicety: the
    /// stream then ended with no terminal event at all, and a perfectly finished
    /// answer was reported as a dropped connection.
    ///
    /// Everything that is not a `data:` line — SSE comments such as OpenRouter's
    /// keep-alive, `event:` lines, blank separators — yields nothing on purpose:
    /// a suggestion must not die because a gateway padded the stream.
    static func decode(line: String) -> [OpenAIStreamEvent] {
        guard let payload = payload(of: line) else { return [] }
        // Every server in the family closes the stream with this sentinel.
        if payload == "[DONE]" { return [.done] }
        guard let object = json(payload) else { return [] }

        // A gateway that fails after the response headers reports it inside the
        // stream; HTTP already said 200, so only the body knows.
        if object["error"] != nil { return [.failure(failure(status: 200, body: payload))] }

        guard let choices = object["choices"] as? [[String: Any]] else { return [] }

        var events: [OpenAIStreamEvent] = []
        // `reasoning_content` (DeepSeek, Kimi) is skipped rather than shown: the
        // overlay promises the answer inside the pause, and a wall of thinking
        // arriving first is exactly the delay it exists to remove.
        let text = text(in: (choices.first?["delta"] as? [String: Any])?["content"])
        if !text.isEmpty { events.append(.text(text)) }

        switch choices.compactMap({ $0["finish_reason"] as? String }).first {
        case "length":
            events.append(.cut(.budget))
        case "content_filter":
            // Отказ, а не обрыв — но только пока на экране пусто. Если текст уже
            // читают вслух, цикл чтения превратит это в обрыв и текст оставит.
            events.append(.failure(.provider(String(localized: "Провайдер отфильтровал ответ."))))
        // Нормальный конец засчитывается здесь, а не только по `[DONE]`: часть
        // каталога — чужие шлюзы и локальные серверы, и не все шлют sentinel.
        case "stop", "end_turn", "stop_sequence":
            events.append(.done)
        default:
            break
        }
        return events
    }

    /// Turns a refusal into words meant for the user.
    ///
    /// The provider's own error type is trusted over the status code where it is
    /// present, because the family disagrees about codes: OpenRouter answers with
    /// HTTP 200 and a numeric `code` in the body, Ollama with a bare string.
    static func failure(status: Int, body: String) -> LLMFailure {
        let reported = reportedError(in: body)

        if mentions(reported.kind, any: ["invalid_api_key", "authentication", "unauthorized", "permission", "401", "403"]) {
            return .unauthorized
        }
        if mentions(reported.kind, any: ["rate_limit", "too_many", "overloaded", "429", "529"]) {
            return .throttled
        }

        switch status {
        case 401, 403:
            return .unauthorized
        case 429, 503, 529:
            return .throttled
        default:
            return .provider(reported.message ?? String(localized: "Провайдер вернул ошибку (HTTP \(String(status)))."))
        }
    }

    /// A request that never reached the server at all.
    ///
    /// The host is named because half this catalogue is a local server: "не
    /// удалось подключиться к localhost:11434" tells the user to start Ollama,
    /// while the bare system wording tells them nothing.
    static func failure(transport error: URLError, endpoint: URL) -> LLMFailure {
        var host = endpoint.host ?? endpoint.absoluteString
        if let port = endpoint.port { host += ":\(port)" }
        return .provider(String(localized: "Не удалось подключиться к \(host): \(error.localizedDescription)"))
    }

    // MARK: - Parsing helpers

    private static func payload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `delta.content` is a string almost everywhere, but some gateways send the
    /// multipart shape back at us. Both mean the same thing to the user.
    private static func text(in content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    /// The error as the provider described it: a haystack of type/code words to
    /// match against, plus the human-readable message if there is one.
    private static func reportedError(in body: String) -> (kind: String, message: String?) {
        guard let object = json(body) else { return ("", nil) }

        // Ollama and llama.cpp answer with a bare string.
        if let text = object["error"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.lowercased(), trimmed.isEmpty ? nil : trimmed)
        }

        guard let error = object["error"] as? [String: Any] else { return ("", nil) }

        var kind: [String] = []
        if let type = error["type"] as? String { kind.append(type) }
        if let code = error["code"] as? String { kind.append(code) }
        if let code = error["code"] as? Int { kind.append(String(code)) }
        if let status = error["status"] as? String { kind.append(status) }

        let message = (error["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (kind.joined(separator: " ").lowercased(), message?.isEmpty == false ? message : nil)
    }

    private static func mentions(_ haystack: String, any needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

// MARK: - Request payload

private extension OpenAIWireFormat {

    struct ChatRequest: Encodable {
        let model: String
        let stream: Bool
        let messages: [Message]
        /// Exactly one of the two is sent — see `Configuration.TokenLimitField`.
        let maxTokens: Int?
        let maxCompletionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, stream, messages
            case maxTokens = "max_tokens"
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    struct Message: Encodable {
        let role: String
        let content: MessageContent
    }

    enum MessageContent: Encodable {
        /// A plain string — what *every* server in the family understands,
        /// including the oldest local ones. Used whenever there is no image.
        case text(String)
        /// The multipart shape, sent only when an image is actually attached.
        case multipart(image: Data, text: String)

        init(text: String, image: Data?) {
            self = image.map { .multipart(image: $0, text: text) } ?? .text(text)
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .text(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .multipart(let image, let text):
                // The screenshot goes ahead of the text: the model is asked to
                // look at the screen first and only then read the conversation.
                var container = encoder.unkeyedContainer()
                try container.encode(ImagePart(image: image))
                try container.encode(TextPart(text: text))
            }
        }
    }

    struct TextPart: Encodable {
        let type = "text"
        let text: String
    }

    struct ImagePart: Encodable {
        let type = "image_url"
        let imageURL: ImageURL

        /// The screen is captured as PNG (ticket 09); nothing else is attached.
        init(image: Data) {
            self.imageURL = ImageURL(url: "data:image/png;base64,\(image.base64EncodedString())")
        }

        enum CodingKeys: String, CodingKey {
            case type
            case imageURL = "image_url"
        }
    }

    struct ImageURL: Encodable {
        let url: String
    }
}
