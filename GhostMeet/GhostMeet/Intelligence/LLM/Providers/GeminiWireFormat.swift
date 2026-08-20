//
//  GeminiWireFormat.swift
//  GhostMeet
//

import Foundation

/// One decoded line of Gemini's server-sent event stream.
nonisolated enum GeminiStreamEvent: Equatable, Sendable {
    /// A fragment of the answer, to be appended to the suggestion as it grows.
    case text(String)
    /// The provider gave up, or its safety filter did.
    case failure(LLMFailure)
    /// The model finished on its own.
    case done
    /// The model stopped before finishing. What arrived stays; the reason is
    /// shown under it.
    case cut(SuggestionCutoff)
}

/// Everything Gemini-specific about the bytes on the wire.
///
/// Gemini is not OpenAI-compatible and not Anthropic-compatible: the prompt is a
/// `contents`/`parts` tree, the system prompt is a separate `systemInstruction`
/// field rather than a role, and each SSE chunk is a **whole**
/// `GenerateContentResponse` rather than a delta object — the new text is simply
/// whatever `candidates[].content.parts[].text` holds in that chunk.
///
/// Endpoint shape (verified against ai.google.dev, not memory):
/// `POST {base}/models/{model}:streamGenerateContent?alt=sse` with the key in the
/// `x-goog-api-key` header. Google also accepts `?key=…`, which we deliberately
/// do not use: a secret in a URL leaks into logs and proxies.
///
/// Note for later: Google now markets the Interactions API
/// (`POST /v1beta/interactions`) as the successor and labels `generateContent`
/// "legacy". `generateContent` is what `ProviderTransport.gemini` is defined as,
/// it is still current on v1beta, and it is the shape every third-party
/// Gemini-compatible gateway implements — so it is what ships. Moving to
/// Interactions later means rewriting this file and nothing above it (ADR-0001).
///
/// Kept apart from `GeminiProvider` so the format can be tested as pure
/// functions, with neither a socket nor a task involved.
nonisolated enum GeminiWireFormat {

    // MARK: - Request

    /// `{base}/models/{model}:streamGenerateContent?alt=sse`.
    ///
    /// Built by hand rather than with `appending(path:)`, which percent-encodes
    /// the `:` that the method name depends on. A model the user typed as
    /// `models/gemini-…` is accepted too — Google's own docs name models both
    /// ways, and a duplicated path segment would be a 404 the user cannot
    /// diagnose.
    static func endpoint(baseURL: String, model: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        var name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("models/") { name.removeFirst("models/".count) }

        guard !base.isEmpty, !name.isEmpty,
              let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/models/\(escaped):streamGenerateContent?alt=sse")
        else {
            throw LLMFailure.provider(String(localized: "Некорректный адрес Gemini: «\(baseURL)», модель «\(model)»."))
        }
        return url
    }

    static func body(
        for request: SuggestionRequest,
        configuration: GeminiProvider.Configuration
    ) throws -> Data {
        var parts: [Part] = []
        // The screenshot goes ahead of the text, as it does for Claude: look at
        // the screen first, then read the conversation.
        if let screenshot = request.screenshot {
            parts.append(.image(screenshot))
        }
        parts.append(.text(request.userPrompt))

        let payload = GenerateContentRequest(
            contents: [Content(role: "user", parts: parts)],
            // The system prompt — with the user's `Профиль` already appended by
            // the prompt builder — is a field of its own here, not a message.
            systemInstruction: Content(parts: [.text(request.systemPrompt)]),
            generationConfig: GenerationConfig(
                maxOutputTokens: request.maxTokens,
                thinkingConfig: configuration.thinkingLevel.map(ThinkingConfig.init(thinkingLevel:))
            )
        )
        return try JSONEncoder().encode(payload)
    }

    // MARK: - Response

    /// Reads one line of the event stream.
    ///
    /// Anything unrecognised is ignored rather than treated as an error: chunks
    /// carry usage counters, safety ratings and (when asked for) thought
    /// summaries, and a suggestion must not die because of one of them.
    /// Reads one line of the event stream into everything it carries.
    ///
    /// **A list and not one event, and for Gemini that is not an edge case but
    /// the normal shape.** Each SSE chunk here is a whole `GenerateContentResponse`,
    /// and the last one carries both the closing fragment and `finishReason`; a
    /// short answer arrives as a single such chunk. Checking the text first and
    /// returning meant the reason was never seen at all — and since this dialect
    /// has no `[DONE]`, the stream then ended with no terminal event, so **every
    /// finished answer** was reported as a dropped connection. The `MAX_TOKENS`
    /// branch was unreachable in live traffic for the same reason.
    static func decode(line: String) -> [GeminiStreamEvent] {
        guard let payload = payload(of: line) else { return [] }
        // Not part of Gemini's dialect, but gateways that re-emit it as OpenAI
        // do send it; cheaper to accept than to explain.
        if payload == "[DONE]" { return [.done] }
        guard let object = json(payload) else { return [] }

        if object["error"] != nil {
            return [.failure(failure(status: 200, body: payload))]
        }
        // The prompt itself was refused — no candidate will ever arrive.
        if let feedback = object["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String {
            return [.failure(.provider(String(localized: "Gemini отклонил запрос: \(reason).")))]
        }

        let candidates = object["candidates"] as? [[String: Any]] ?? []
        var events: [GeminiStreamEvent] = []
        let text = answerText(in: candidates)
        if !text.isEmpty { events.append(.text(text)) }

        switch candidates.compactMap({ $0["finishReason"] as? String }).first {
        case nil:
            break
        case "STOP":
            events.append(.done)
        case "MAX_TOKENS":
            events.append(.cut(.budget))
        case .some(let reason):
            // A failure rather than a cut-off — but only while the screen is
            // empty; text already being read aloud is kept by the read loop.
            events.append(.failure(.provider(String(localized: "Gemini прервал ответ: \(reason)."))))
        }
        return events
    }

    /// Turns a refusal into words meant for the user.
    ///
    /// The canonical `status` string is trusted over the HTTP code where it is
    /// present, because Gemini's codes lie in one important case: a bad API key
    /// comes back as **400 INVALID_ARGUMENT**, not 401, and reporting that as a
    /// nameless request error would send the user hunting through prompt code
    /// instead of retyping the key.
    static func failure(status: Int, body: String) -> LLMFailure {
        let reported = reportedError(in: body)

        if reported.isRejectedKey { return .unauthorized }

        switch reported.status {
        case "UNAUTHENTICATED", "PERMISSION_DENIED":
            return .unauthorized
        case "RESOURCE_EXHAUSTED", "UNAVAILABLE":
            // Quota and "model is overloaded" call for the same thing from the
            // user: wait and let the next `Them` turn try again.
            return .throttled
        default:
            break
        }

        switch status {
        case 401, 403:
            return .unauthorized
        case 429, 503:
            return .throttled
        default:
            return .provider(reported.message ?? String(localized: "Провайдер вернул ошибку (HTTP \(String(status)))."))
        }
    }

    // MARK: - Parsing helpers

    /// The answer text of a chunk: every `text` part of every candidate, in order.
    ///
    /// Parts flagged `thought` are dropped. We never ask for thought summaries,
    /// but if a model or a gateway sends them anyway they are reasoning, not an
    /// answer, and they must not be pasted into the overlay as one.
    private static func answerText(in candidates: [[String: Any]]) -> String {
        candidates
            .compactMap { $0["content"] as? [String: Any] }
            .compactMap { $0["parts"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    private static func payload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private struct ReportedError {
        var status: String?
        var message: String?
        /// Google reports a rejected key as an ordinary invalid argument. Both
        /// the wording and the `details[].reason` are checked, because which of
        /// the two arrives depends on the endpoint.
        var isRejectedKey = false
    }

    private static func reportedError(in body: String) -> ReportedError {
        guard let error = errorObject(in: body) else { return ReportedError() }

        let message = (error["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reasons = (error["details"] as? [[String: Any]] ?? [])
            .compactMap { $0["reason"] as? String }

        return ReportedError(
            status: error["status"] as? String,
            message: message?.isEmpty == false ? message : nil,
            isRejectedKey: reasons.contains("API_KEY_INVALID")
                || message?.localizedCaseInsensitiveContains("API key not valid") == true
                || message?.localizedCaseInsensitiveContains("API key expired") == true
        )
    }

    /// Google wraps the error in an array when the streaming endpoint fails
    /// before the stream starts, and returns it bare otherwise. Accept both.
    private static func errorObject(in body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if let object = root as? [String: Any] {
            return object["error"] as? [String: Any]
        }
        if let array = root as? [[String: Any]] {
            return array.compactMap { $0["error"] as? [String: Any] }.first
        }
        return nil
    }
}

// MARK: - Request payload

/// Field names are the canonical lowerCamelCase of the REST reference. Gemini's
/// proto3 JSON also accepts the `snake_case` spelling shown in some curl
/// examples; picking one and staying with it keeps the payload readable.
private extension GeminiWireFormat {

    nonisolated struct GenerateContentRequest: Encodable {
        let contents: [Content]
        let systemInstruction: Content
        let generationConfig: GenerationConfig
    }

    nonisolated struct Content: Encodable {
        /// Omitted for `systemInstruction`, which has no role.
        var role: String?
        let parts: [Part]
    }

    nonisolated struct GenerationConfig: Encodable {
        let maxOutputTokens: Int
        let thinkingConfig: ThinkingConfig?
    }

    nonisolated struct ThinkingConfig: Encodable {
        let thinkingLevel: String
    }

    nonisolated enum Part: Encodable {
        case text(String)
        case image(Data)

        enum CodingKeys: String, CodingKey {
            case text, inlineData
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(text, forKey: .text)
            case .image(let data):
                try container.encode(InlineData(data: data.base64EncodedString()), forKey: .inlineData)
            }
        }
    }

    nonisolated struct InlineData: Encodable {
        /// The screen is captured as PNG (ticket 09); nothing else is attached.
        let mimeType = "image/png"
        let data: String
    }
}
