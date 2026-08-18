//
//  WhisperSpeechRecognizer.swift
//  GhostMeet
//

import Foundation

/// Recognition backed by a local Whisper model.
///
/// It sits behind `SpeechRecognizer` and nothing above it — `SessionEngine`
/// least of all — learns that Whisper is what turns audio into words (ADR-0001).
/// Which model, whether it is downloaded, and what to say while it is not, are
/// all this type's business.
///
/// Two decisions shape it:
///
/// 1. **Never block on the model.** The first use of a model pulls hundreds of
///    megabytes. A turn that arrives before the model is ready is refused right
///    away rather than queued: `SessionEngine` keeps such a turn in the
///    transcript without text, which is a visible, honest "not recognised", and
///    the call keeps moving. Queueing instead would produce a burst of stale
///    suggestions minutes later, which is worse.
/// 2. **Channels do not wait for each other.** Being an actor serialises the
///    bookkeeping only; `session.transcribe` is awaited, so a `You` pass and a
///    `Them` pass run side by side, exactly as WhisperKit itself runs its
///    batches on one loaded model.
actor WhisperSpeechRecognizer: SpeechRecognizer {

    /// Why a turn came back without words.
    enum RecognitionError: LocalizedError, Equatable {
        /// The model is not usable yet; the phase says how far along it is.
        case modelNotReady(SpeechModelPhase)
        /// The turn carried no usable samples.
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .modelNotReady(let phase): return phase.summary
            case .emptyAudio: return String(localized: "В реплике не оказалось звука")
            }
        }
    }

    /// Model currently selected. Changing it invalidates whatever is loaded.
    private(set) var model: WhisperModel

    /// Where preparation has got to. Mirrored to the UI through `phaseUpdates()`.
    private(set) var phase: SpeechModelPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            phaseContinuation?.yield(phase)
        }
    }

    private let provider: any SpeechModelProvider
    private var session: (any SpeechModelSession)?
    private var preparation: Task<Void, Never>?
    private var phaseContinuation: AsyncStream<SpeechModelPhase>.Continuation?

    init(
        model: WhisperModel = .default,
        provider: any SpeechModelProvider = WhisperKitModelProvider()
    ) {
        self.model = model
        self.provider = provider
    }

    deinit {
        preparation?.cancel()
        phaseContinuation?.finish()
    }

    // MARK: - Progress for the interface

    /// Phases as they happen, starting with the current one.
    ///
    /// Single-consumer: asking again replaces the previous stream, which is what
    /// the one settings screen needs and keeps the bookkeeping to one line.
    func phaseUpdates() -> AsyncStream<SpeechModelPhase> {
        phaseContinuation?.finish()
        let (stream, continuation) = AsyncStream<SpeechModelPhase>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        continuation.yield(phase)
        phaseContinuation = continuation
        return stream
    }

    // MARK: - The model

    /// Switches to another model.
    ///
    /// Takes effect on the turns that follow: whatever is loaded is dropped, and
    /// the new model is fetched on the next turn or when `prepare()` is called.
    func use(_ model: WhisperModel) {
        guard model != self.model else { return }
        preparation?.cancel()
        preparation = nil
        session = nil
        self.model = model
        phase = .idle
    }

    /// Starts fetching and loading the selected model. Idempotent.
    ///
    /// Called by the settings screen so the download can happen before the call
    /// rather than during it, and by `transcribe` when a turn arrives and nothing
    /// is loaded yet.
    func prepare() {
        guard session == nil, preparation == nil else { return }
        let model = model
        let provider = provider

        preparation = Task {
            defer { preparation = nil }
            phase = .downloading(fraction: 0)
            do {
                let folder = try await provider.fetch(model) { [weak self] fraction in
                    Task { await self?.reportDownload(fraction, of: model) }
                }
                try Task.checkCancellation()
                guard model == self.model else { return }

                phase = .loading
                let session = try await provider.load(model, from: folder)
                try Task.checkCancellation()
                guard model == self.model else { return }

                self.session = session
                phase = .ready
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Waits for the preparation currently in flight, if any.
    ///
    /// The seam that lets a test drive the whole "model shows up" scenario
    /// without sleeping.
    func prepared() async {
        await preparation?.value
    }

    private func reportDownload(_ fraction: Double, of model: WhisperModel) {
        guard model == self.model, case .downloading = phase else { return }
        phase = .downloading(fraction: min(max(fraction, 0), 1))
    }

    // MARK: - Recognition

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        guard let session else {
            // The first turn of a call is what triggers the download when the
            // user never opened settings. That turn itself gets no text — it
            // stays in the transcript as unrecognised — and the ones after it do.
            prepare()
            throw RecognitionError.modelNotReady(phase)
        }

        let samples = audio.resampled(to: WhisperModel.requiredSampleRate)
        guard !samples.isEmpty else { throw RecognitionError.emptyAudio }

        let text = try await session.transcribe(samples)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A `Фантомная реплика` is dropped here and not further up, because this
        // is the layer that knows Whisper is behind it: inventing a subtitle
        // sign-off on a stretch of silence is a behaviour of this model family,
        // and the second engine ADR-0002 promises does not share it. Returning no
        // words leaves the turn in the transcript without any — the same state a
        // failed pass leaves it in, and the prompt layer already skips it.
        return PhantomSpeech.isPhantom(text) ? "" : text
    }
}
