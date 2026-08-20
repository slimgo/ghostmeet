//
//  OpenAICompatibleProvider.swift
//  GhostMeet
//

import Foundation

/// One backend for most of the catalogue: OpenAI, OpenRouter, Polza.AI, DeepSeek,
/// Kimi, and the local servers — Ollama, LM Studio, llama.cpp.
///
/// They are not eight integrations. They speak the same chat-completions dialect
/// and differ only in three values, which is exactly what `Configuration` holds:
/// where to send the request, what to call the model, and whether a key is
/// needed. A provider nobody thought of is therefore reachable by typing a base
/// URL, without a code change (ADR-0001).
///
/// The two load-bearing properties are the same as for `ClaudeProvider`:
///
/// 1. **Streaming**, because a suggestion has to start appearing while the model
///    is still writing it.
/// 2. **Real cancellation.** A new press supersedes the suggestion in flight
///    (ADR-0008): terminating the stream cancels the work task, which tears down
///    the HTTP request instead of letting it finish in the background.
nonisolated struct OpenAICompatibleProvider: LLMProvider {

    /// Everything that differs between the servers in this family.
    nonisolated struct Configuration: Equatable, Sendable {

        /// Which of the two spellings of the output budget this server accepts.
        ///
        /// This is not cosmetic: OpenAI's reasoning-era models **reject**
        /// `max_tokens` outright and demand `max_completion_tokens`, while the
        /// rest of the family — and every local server — knows only
        /// `max_tokens`. Sending both is not an option either, since OpenAI
        /// refuses the request rather than ignoring the extra field.
        nonisolated enum TokenLimitField: Equatable, Sendable {
            case maxTokens
            case maxCompletionTokens
        }

        /// Shown in the settings screen and in error messages.
        var name: String

        /// The fully resolved chat-completions URL, base URL included.
        var endpoint: URL

        var model: String

        /// Whether an image may ride along. False for text-only models and for
        /// local servers, where the loaded model is unknown to us.
        var acceptsImages: Bool

        /// False for local servers, which authenticate nobody.
        var needsKey: Bool

        var tokenLimit: TokenLimitField

        /// Turns "what the user picked" into "where the bytes go".
        ///
        /// Pure and throwing rather than optional-returning: a base URL the user
        /// mistyped has to reach them as words, not as a silent fallback to some
        /// other provider's address.
        static func resolve(
            preset: ProviderPreset,
            selection: ProviderSelection
        ) throws -> Configuration {
            let base = override(selection.baseURL) ?? preset.defaultBaseURL
            let model = override(selection.model) ?? preset.defaultModel

            guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMFailure.provider(String(localized: "Для провайдера «\(preset.name)» не задан адрес API."))
            }
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMFailure.provider(String(localized: "Для провайдера «\(preset.name)» не задана модель."))
            }

            let endpoint = try endpoint(base: base)
            return Configuration(
                name: preset.name,
                endpoint: endpoint,
                model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                acceptsImages: preset.capabilities.acceptsImages,
                needsKey: preset.needsKey,
                tokenLimit: tokenLimit(for: endpoint)
            )
        }

        private static func override(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// Appends the path unless the user already typed it. Nothing else is
        /// guessed — notably no `/v1` is bolted on, because the family disagrees
        /// about it: DeepSeek documents a base without it, everyone else with it.
        private static func endpoint(base: String) throws -> URL {
            let path = "/chat/completions"
            var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix("/") { trimmed.removeLast() }

            let full = trimmed.hasSuffix(path) ? trimmed : trimmed + path
            guard let url = URL(string: full), url.scheme != nil, url.host != nil else {
                throw LLMFailure.provider(String(localized: "Адрес API «\(base)» не похож на адрес — проверьте настройки."))
            }
            return url
        }

        /// Keyed off the host rather than the preset id, so that pointing a
        /// hand-typed base URL at OpenAI still produces a request OpenAI accepts.
        private static func tokenLimit(for endpoint: URL) -> TokenLimitField {
            let host = endpoint.host?.lowercased() ?? ""
            let isOpenAI = host == "openai.com" || host.hasSuffix(".openai.com")
            return isOpenAI ? .maxCompletionTokens : .maxTokens
        }
    }

    let configuration: Configuration
    private let transport: any StreamingHTTPTransport
    private let apiKey: @Sendable () async -> String?

    var name: String { configuration.name }

    /// Declared honestly per provider, because `Solve on screen` is the primary
    /// mode of this scenario: DeepSeek takes no images, a local server's loaded
    /// model is anyone's guess, and a screenshot sent there fails the request
    /// rather than degrading it.
    var capabilities: ProviderCapabilities {
        ProviderCapabilities(acceptsImages: configuration.acceptsImages, streams: true)
    }

    /// - Parameter apiKey: Reads the key at the moment of the request. A closure
    ///   rather than a stored string so a key entered mid-call takes effect on
    ///   the next suggestion, and so nothing keeps a copy of it.
    init(
        configuration: Configuration,
        apiKey: @escaping @Sendable () async -> String?,
        transport: any StreamingHTTPTransport = URLSessionStreamingTransport()
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
    }

    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let cutoff as SuggestionCutoff {
                    // Passes straight through, as `LLMFailure` does: the session
                    // tells a cut-off answer from one that never happened by the
                    // type of the error, and wrapping this in `.provider` would
                    // erase the difference.
                    continuation.finish(throwing: cutoff)
                } catch let failure as LLMFailure {
                    continuation.finish(throwing: failure)
                } catch let error as URLError {
                    continuation.finish(
                        throwing: OpenAIWireFormat.failure(
                            transport: error,
                            endpoint: configuration.endpoint
                        )
                    )
                } catch {
                    continuation.finish(throwing: LLMFailure.provider(error.localizedDescription))
                }
            }
            // The consumer stopping — because it cancelled, or simply walked away
            // — is what abandons the request.
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func run(
        _ request: SuggestionRequest,
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let key = (await apiKey())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableKey = (key?.isEmpty == false) ? key : nil
        // Local servers authenticate nobody, so a missing key is normal there and
        // fatal everywhere else — cheaper to say so than to spend a round trip.
        if configuration.needsKey, usableKey == nil { throw LLMFailure.missingKey }

        let outgoing = try urlRequest(for: request, key: usableKey)
        let response = try await transport.send(outgoing)

        guard response.statusCode == 200 else {
            throw OpenAIWireFormat.failure(
                status: response.statusCode,
                body: await collect(response.lines)
            )
        }

        // Counts what actually reached the user. Falling out of the loop below
        // means the provider never closed the stream — a connection dropped
        // mid-sentence, which until now was indistinguishable from a model that
        // simply stopped talking. See `SuggestionCutoff`.
        var delivered = 0

        for try await line in response.lines {
            try Task.checkCancellation()
            for event in OpenAIWireFormat.decode(line: line) {
                switch event {
                case .text(let fragment):
                    delivered += fragment.count
                    continuation.yield(fragment)
                case .failure(let failure):
                    // A failure wipes the card — it draws the reason INSTEAD of
                    // the text. While the screen is empty that is right; but if
                    // the user is already reading the answer aloud, the sentence
                    // must not vanish from under their eyes, so a late failure
                    // becomes a cut-off instead.
                    throw delivered == 0 ? failure : SuggestionCutoff.stopped(failure.message)
                case .cut(let cutoff):
                    // The text stays: the consumer has already been handed every
                    // fragment, and half an answer beats none. Only the reason is
                    // thrown, and it arrives after the words it explains.
                    throw cutoff
                case .done:
                    // A stream that closes honestly but empty is also worth
                    // saying out loud: a reasoning model can spend the budget on
                    // invisible tokens and close the stream having said nothing.
                    if delivered == 0 { throw SuggestionCutoff.empty }
                    return
                }
            }
        }

        throw delivered == 0 ? SuggestionCutoff.empty : SuggestionCutoff.connection
    }

    private func urlRequest(for request: SuggestionRequest, key: String?) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if let key {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        urlRequest.httpBody = try OpenAIWireFormat.body(for: request, configuration: configuration)
        return urlRequest
    }

    /// Reads a non-streaming body — an error response — back into one string.
    private func collect(_ lines: AsyncThrowingStream<String, any Error>) async -> String {
        var collected: [String] = []
        do {
            for try await line in lines { collected.append(line) }
        } catch {
            // A body we could not finish reading still has to produce a failure:
            // degrade to whatever arrived rather than replacing the provider's
            // own wording with a transport error.
        }
        return collected.joined(separator: "\n")
    }
}
