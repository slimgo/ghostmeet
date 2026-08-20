//
//  ClaudeWireFormat.swift
//  GhostMeet
//

import Foundation

/// One decoded line of Claude's server-sent event stream.
nonisolated enum ClaudeStreamEvent: Equatable, Sendable {
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

/// Everything Claude-specific about the bytes on the wire: how a request is
/// encoded, how the event stream is read, and how a failure becomes an
/// `LLMFailure` the user can act on.
///
/// Kept apart from `ClaudeProvider` so the format can be tested as pure
/// functions, with neither a socket nor a task involved.
nonisolated enum ClaudeWireFormat {

    // MARK: - Request

    static func body(
        for request: SuggestionRequest,
        configuration: ClaudeProvider.Configuration
    ) throws -> Data {
        var content: [ContentBlock] = []
        // The screenshot goes ahead of the text: the model is asked to look at
        // the screen first and only then read the conversation.
        if let screenshot = request.screenshot {
            content.append(.image(screenshot))
        }
        content.append(.text(request.userPrompt))

        let payload = MessagesRequest(
            model: configuration.model,
            maxTokens: request.maxTokens,
            stream: true,
            system: request.systemPrompt,
            thinking: Thinking(type: configuration.thinkingEnabled ? "adaptive" : "disabled"),
            outputConfig: OutputConfig(effort: configuration.effort),
            messages: [Message(role: "user", content: content)]
        )
        return try JSONEncoder().encode(payload)
    }

    // MARK: - Response

    /// Reads one line of the event stream into everything it carries.
    ///
    /// Anything that is not a `data:` line, or carries a shape we do not consume,
    /// yields nothing rather than an error: the stream gains event types over
    /// time and a suggestion must not die because of one.
    ///
    /// A list for symmetry with the other two dialects, where one chunk really
    /// can hold both a fragment and the reason the answer ended. Claude keeps
    /// them in separate events, so the lists here are never longer than one —
    /// but three formats answering the same question in three shapes is how they
    /// drift apart.
    static func decode(line: String) -> [ClaudeStreamEvent] {
        guard let payload = payload(of: line) else { return [] }
        guard let object = json(payload) else { return [] }

        switch object["type"] as? String {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return [] }
            return [.text(text)]
        case "error":
            return [.failure(failure(status: 200, body: payload))]
        case "message_delta":
            // Claude reports how it stopped here, one event before closing the
            // message. A normal ending is counted as the close right here rather
            // than left to `message_stop` alone: a stream that ends without that
            // event would otherwise be reported as a dropped connection, which
            // is a false alarm on every answer.
            switch (object["delta"] as? [String: Any])?["stop_reason"] as? String {
            case "max_tokens", "model_context_window_exceeded":
                return [.cut(.budget)]
            case "refusal":
                // A classifier stopped the generation and returned what had
                // been written. While there is no text this is a failure; once
                // text exists the read loop turns it into a cut-off and keeps
                // what arrived.
                return [.failure(.provider(String(localized: "Модель отказалась продолжать.")))]
            // Everything else is an ordinary end. The default is generous on
            // purpose: Anthropic's list of reasons keeps growing, and calling an
            // unfamiliar one a cut-off would raise an alarm at every new word in
            // the protocol.
            default:
                return [.done]
            }
        case "message_stop":
            return [.done]
        default:
            return []
        }
    }

    /// Turns a refusal into words meant for the user.
    ///
    /// The provider's own error type is trusted over the status code where it is
    /// present — it distinguishes a rejected key from a missing permission, which
    /// share HTTP 403.
    static func failure(status: Int, body: String) -> LLMFailure {
        let reported = reportedError(in: body)

        switch reported.type {
        case "authentication_error", "permission_error":
            return .unauthorized
        case "rate_limit_error", "overloaded_error":
            return .throttled
        default:
            break
        }

        switch status {
        case 401, 403:
            return .unauthorized
        case 429, 529:
            return .throttled
        default:
            return .provider(reported.message ?? String(localized: "Провайдер вернул ошибку (HTTP \(String(status)))."))
        }
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

    private static func reportedError(in body: String) -> (type: String?, message: String?) {
        guard let object = json(body), let error = object["error"] as? [String: Any] else {
            return (nil, nil)
        }
        let message = (error["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (error["type"] as? String, message?.isEmpty == false ? message : nil)
    }
}

// MARK: - Request payload

private extension ClaudeWireFormat {

    struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let stream: Bool
        let system: String
        let thinking: Thinking
        let outputConfig: OutputConfig
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, stream, system, thinking, messages
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    struct Thinking: Encodable {
        let type: String
    }

    struct OutputConfig: Encodable {
        let effort: String
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    enum ContentBlock: Encodable {
        case text(String)
        case image(Data)

        enum CodingKeys: String, CodingKey {
            case type, text, source
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let data):
                try container.encode("image", forKey: .type)
                try container.encode(ImageSource(data: data.base64EncodedString()), forKey: .source)
            }
        }
    }

    struct ImageSource: Encodable {
        let type = "base64"
        /// The screen is captured as PNG (ticket 09); nothing else is attached.
        let mediaType = "image/png"
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }
}
