//
//  GeminiProvider.swift
//  GhostMeet
//

import Foundation

/// Google Gemini behind `LLMProvider` (ADR-0001).
///
/// Structurally a twin of `ClaudeProvider` — same streaming shape, same
/// cancellation chain — because those two properties are what the product
/// depends on, not the vendor:
///
/// 1. **Streaming.** Fragments are yielded the moment they arrive, so the
///    suggestion starts appearing while the model is still writing it.
/// 2. **Real cancellation.** A new press supersedes the suggestion in flight
///    (ADR-0008). Cancelling the consuming task terminates the stream, which
///    cancels the work task, which tears down the HTTP request.
///
/// Everything that differs from Claude — the URL, the header the key rides in,
/// the request tree, the chunk shape — lives in `GeminiWireFormat`.
///
/// The key is read per request and dropped again; it is never held in a
/// property, so a provider instance is safe to keep around.
nonisolated struct GeminiProvider: LLMProvider {

    /// Model and generation settings. Both the address and the model stay
    /// configurable: the settings screen lets the user retarget the provider at
    /// a gateway that speaks the same dialect.
    nonisolated struct Configuration: Equatable, Sendable {

        /// Current stable Gemini, multimodal and fast. Flash rather than Pro on
        /// purpose: this scenario pays for latency in seconds of silence on
        /// camera, and the Pro tier is preview-only besides.
        var model: String = "gemini-3.6-flash"

        /// Version-bearing prefix; the method name is appended per request.
        var baseURL: String = "https://generativelanguage.googleapis.com/v1beta"

        /// `low`, for the same reason Claude runs with thinking off: thinking
        /// tokens land *before* any answer text, and on screen that reads as a
        /// long pause — precisely what the overlay exists to avoid. `low` rather
        /// than `minimal` because it is the one level every model from 2.5
        /// upwards accepts, so a user who retypes the model does not get a 400.
        /// Set to nil for a model old enough not to know the field at all.
        var thinkingLevel: String? = "low"

        static let `default` = Configuration()

        /// What the user picked, with the overrides they typed applied.
        ///
        /// A blank field means "keep the preset", not "send an empty address" —
        /// which is why this is a resolution step and not a plain assignment.
        static func resolve(
            preset: ProviderPreset,
            selection: ProviderSelection
        ) throws -> Configuration {
            let base = override(selection.baseURL) ?? preset.defaultBaseURL
            let model = override(selection.model) ?? preset.defaultModel

            guard override(base) != nil else {
                throw LLMFailure.provider(String(localized: "Для провайдера «\(preset.name)» не задан адрес API."))
            }
            guard override(model) != nil else {
                throw LLMFailure.provider(String(localized: "Для провайдера «\(preset.name)» не задана модель."))
            }
            return Configuration(model: model, baseURL: base)
        }

        private static func override(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    let name = "Gemini"

    /// Gemini takes images and streams, so `Solve on screen` works at full
    /// strength.
    let capabilities = ProviderCapabilities.multimodal

    private let configuration: Configuration
    private let transport: any StreamingHTTPTransport
    private let apiKey: @Sendable () async -> String?

    /// - Parameter apiKey: Reads the key at the moment of the request. A closure
    ///   rather than a stored string so a key entered mid-call takes effect on
    ///   the next suggestion, and so nothing keeps a copy of it.
    init(
        apiKey: @escaping @Sendable () async -> String?,
        transport: any StreamingHTTPTransport = URLSessionStreamingTransport(),
        configuration: Configuration = .default
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.configuration = configuration
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
        guard let key, !key.isEmpty else { throw LLMFailure.missingKey }

        let outgoing = try urlRequest(for: request, key: key)
        let response = try await transport.send(outgoing)

        guard response.statusCode == 200 else {
            throw GeminiWireFormat.failure(
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
            for event in GeminiWireFormat.decode(line: line) {
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

    private func urlRequest(for request: SuggestionRequest, key: String) throws -> URLRequest {
        let endpoint = try GeminiWireFormat.endpoint(
            baseURL: configuration.baseURL,
            model: configuration.model
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // In a header, never in `?key=`: a secret in a URL ends up in logs.
        urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try GeminiWireFormat.body(for: request, configuration: configuration)
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

