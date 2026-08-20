//
//  ClaudeProvider.swift
//  GhostMeet
//

import Foundation

/// The MVP cloud backend, behind `LLMProvider` (ADR-0001).
///
/// Two properties are load-bearing rather than nice to have:
///
/// 1. **Streaming.** A suggestion has to start appearing while the model is
///    still writing it, so fragments are yielded the moment they arrive.
/// 2. **Real cancellation.** A new press supersedes the suggestion in flight
///    (ADR-0008). Cancelling the consuming task terminates the stream, which
///    cancels the work task, which tears down the HTTP request — the answer to
///    the previous question is never paid for or finished in the background.
///
/// The key is read from the keychain per request and dropped again; it is never
/// held in a property, so a provider instance is safe to keep around.
nonisolated struct ClaudeProvider: LLMProvider {

    /// Model and generation settings, in one place so the latency/quality
    /// trade-off is visible rather than scattered through the request builder.
    nonisolated struct Configuration: Equatable, Sendable {

        /// Anthropic's current top model. Kept explicit — the MVP has one
        /// provider and no router, so there is nothing to negotiate at runtime.
        var model: String = "claude-opus-5"

        /// `low` on purpose. The user presses while already speaking and waits
        /// with their mouth open; the model only starts after the tail of the
        /// question is recognised and the screen is grabbed, and higher effort
        /// spends its budget before the first visible character.
        var effort: String = "low"

        /// Off on purpose, for the same reason: on this model thinking is on by
        /// default and its tokens land *before* any answer text, which reads on
        /// screen as a long pause — precisely what the overlay exists to avoid.
        /// The system prompt carries the guard against internal tags leaking
        /// into the answer that turning thinking off calls for.
        var thinkingEnabled: Bool = false

        var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

        var apiVersion: String = "2023-06-01"

        static let `default` = Configuration()
    }

    let name = "Claude"

    /// Anthropic takes images and streams, so `Solve on screen` works at full
    /// strength here — which is why it stays the default for this scenario.
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
            throw ClaudeWireFormat.failure(
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
            for event in ClaudeWireFormat.decode(line: line) {
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
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try ClaudeWireFormat.body(for: request, configuration: configuration)
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

extension ClaudeProvider {
}
