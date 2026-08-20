//
//  CLIProvider.swift
//  GhostMeet
//

import Foundation

/// A command-line tool behind `LLMProvider` (ADR-0001): prompt in on stdin,
/// answer out on stdout.
///
/// **Why this transport exists at all.** `claude`, `codex` and `kimi` are
/// already logged in on the user's machine and answer on the subscription the
/// user is already paying for. A cloud provider here would bill per interview
/// on top of that — and the BYOK promise means the user, not us, absorbs it. So
/// this is the option that costs nothing to run, at the price of no images and
/// of whatever startup time the tool needs.
///
/// Three things are load-bearing:
///
/// 1. **Streaming means reading stdout as it appears** — not waiting for the
///    process to exit and yielding the answer in one lump. There is no protocol
///    to parse; the fragments are simply the writes the tool makes.
/// 2. **Cancellation kills the process.** A new press cancels the
///    in-flight suggestion (ADR-0008): the consumer stops, the stream
///    terminates, the work task is cancelled, and `CLIProcess.terminate` signals
///    the tool. An orphan left writing an answer nobody reads is a leak and a
///    bill against the user's subscription.
/// 3. **A missing tool is a sentence, not a crash.** The user may simply not
///    have installed it, and a GUI app's `PATH` is narrower than the one they
///    see in Terminal — see `CLIExecutable`.
nonisolated struct CLIProvider: LLMProvider {

    nonisolated struct Configuration: Equatable, Sendable {

        /// Executable and its arguments, straight from the preset — e.g.
        /// `["claude", "-p"]`. All of them read the prompt from stdin when no
        /// prompt argument is given, which is what lets one implementation serve
        /// every tool in the catalogue.
        var command: [String]

        /// Where to look for the executable, and the `PATH` the tool itself
        /// inherits.
        var searchPaths: [String]

        init(command: [String], searchPaths: [String] = CLIExecutable.searchPaths()) {
            self.command = command
            self.searchPaths = searchPaths
        }
    }

    /// The preset's name — "Claude CLI", "Codex CLI" — so a failure names the
    /// tool the user picked rather than a generic "CLI".
    let name: String

    /// No images, and that is not a limitation we can engineer around: a
    /// one-shot prompt on stdin has nowhere to put a PNG. `Solve on screen`
    /// therefore degrades to reasoning over the OCR text, and the request
    /// builder drops the screenshot because of this flag rather than sending one
    /// and failing. Streaming, on the other hand, is real.
    let capabilities = ProviderCapabilities.textOnly

    private let configuration: Configuration

    init(name: String, configuration: Configuration) {
        self.name = name
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
                } catch let cutoff as SuggestionCutoff {
                    continuation.finish(throwing: cutoff)
                } catch let failure as LLMFailure {
                    continuation.finish(throwing: failure)
                } catch {
                    continuation.finish(throwing: LLMFailure.provider(error.localizedDescription))
                }
            }
            // Link one of the chain: whoever stops reading cancels the work task.
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func run(
        _ request: SuggestionRequest,
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        guard let executableName = configuration.command.first,
              !executableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LLMFailure.provider(String(localized: "Для «\(name)» не задана команда запуска."))
        }

        guard let executable = CLIExecutable.locate(
            executableName,
            in: configuration.searchPaths
        ) else {
            throw LLMFailure.provider(
                String(localized: "Не найден исполняемый файл «\(executableName)» для «\(name)». ")
                + String(localized: "Установите инструмент или укажите в настройках полный путь к нему.")
            )
        }

        let process = CLIProcess(
            executable: executable,
            arguments: Array(configuration.command.dropFirst()),
            environment: childEnvironment()
        )

        let stdout: AsyncStream<Data>
        do {
            stdout = try process.start(prompt: Self.prompt(for: request))
        } catch {
            throw LLMFailure.provider(
                String(localized: "Не удалось запустить «\(executableName)»: \(error.localizedDescription)")
            )
        }

        // Link two: cancelling this task signals the tool. Without it the
        // process would keep generating after the suggestion was abandoned.
        try await withTaskCancellationHandler {
            try await pump(stdout, of: process, into: continuation)
        } onCancel: {
            process.terminate()
        }
    }

    private func pump(
        _ stdout: AsyncStream<Data>,
        of process: CLIProcess,
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        var text = IncrementalUTF8Text()
        var delivered = 0

        for await chunk in stdout {
            try Task.checkCancellation()
            let fragment = text.append(chunk)
            if !fragment.isEmpty { delivered += fragment.count; continuation.yield(fragment) }
        }
        let tail = text.flush()
        if !tail.isEmpty { delivered += tail.count; continuation.yield(tail) }

        let status = await process.waitForExit()
        // A killed tool exits non-zero; that is the cancellation, not a failure
        // worth showing.
        try Task.checkCancellation()

        guard status == 0 else {
            let reason = failureMessage(status: status, from: process)
            // A tool killed by a signal mid-answer returns 15 or 9 — and before
            // this change the half of the answer the user was reading aloud
            // vanished from the screen, because on a failure the card draws the
            // reason INSTEAD of the text. While there is no text it is still a
            // failure.
            throw delivered == 0 ? LLMFailure.provider(reason) : SuggestionCutoff.stopped(reason)
        }
        // Exited cleanly and said nothing. Rarer than over HTTP but not
        // impossible — a tool that has lost its session prints its complaint to
        // stderr and returns zero — and an empty card explains none of it.
        if delivered == 0 { throw SuggestionCutoff.empty }
    }

    /// What the tool said on stderr — "not logged in", "quota exceeded" — is far
    /// more use than an exit code, so it is preferred whenever there is any.
    private func failureMessage(status: Int32, from process: CLIProcess) -> String {
        let reported = process.standardErrorText
        guard !reported.isEmpty else {
            return String(localized: "«\(name)» завершился с кодом \(String(status)).")
        }
        // The overlay is a small window over a video call, and some tools print
        // a stack trace: keep the head of it and drop the rest.
        let limit = 400
        guard reported.count > limit else { return reported }
        return String(reported.prefix(limit)) + "…"
    }

    /// The tool runs with the widened `PATH` we used to find it: `claude` is a
    /// Node script and has to be able to find `node`, which lives in the same
    /// directories launchd never mentions.
    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = configuration.searchPaths.joined(separator: ":")
        return environment
    }

    /// System prompt and context in one blob.
    ///
    /// A one-shot CLI run has no separate system channel, and inventing per-tool
    /// flags for it (`--append-system-prompt` and friends) would tie this
    /// provider to one tool's command line — the opposite of what the transport
    /// is for. The rule against dying on an empty transcript applies here too:
    /// an empty stdin makes most tools error out, so a placeholder goes instead.
    static func prompt(for request: SuggestionRequest) -> String {
        let system = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = request.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let joined = switch (system.isEmpty, user.isEmpty) {
        case (false, false): "\(system)\n\n---\n\n\(user)"
        case (false, true): system
        case (true, false): user
        case (true, true): ""
        }
        return joined.isEmpty ? String(localized: "(пусто)") : joined
    }
}
