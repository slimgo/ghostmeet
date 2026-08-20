//
//  NativeSpeechRecognizer.swift
//  GhostMeet
//

import AVFoundation
import Foundation
import Speech

/// Recognition backed by the system's own `SpeechAnalyzer` (macOS 26).
///
/// Second engine behind `SpeechRecognizer` (ADR-0001): nothing above it learns
/// which engine turned audio into words. It exists because on this machine it
/// runs an order of magnitude faster than real time and needs no download of
/// ours — and it is not the default because the words it returns are weaker on
/// technical speech than Whisper's.
///
/// **`DictationTranscriber`, not `SpeechTranscriber`, and that is the whole
/// reason Russian works here.** ADR-0002 rules the native path out for Russian
/// on the grounds that `SpeechTranscriber` offers thirty locales with no
/// Cyrillic among them — still true, re-checked. But `DictationTranscriber` is
/// the other transcriber in the same API and carries fifty-four, `ru-RU`
/// included. Which of the two is better *where both have the locale* is not
/// decided here: it is a measurement, and it is what `.scratch/speech-analyzer/`
/// ticket 02 exists for.
///
/// One analyser per turn, deliberately. Turns are independent — the segmenter
/// has already cut them — so carrying an analyser's context across them would
/// let one turn's words colour the next. The measured cost of building a fresh
/// one is 0.12–0.18 s for turns of one to three seconds, well under the
/// threshold where anybody notices.
@available(macOS 26, *)
actor NativeSpeechRecognizer {

    /// Why a turn came back without words.
    enum RecognitionError: LocalizedError, Equatable {
        /// The language assets are not in place yet; the phase says how far along.
        case assetsNotReady(SpeechModelPhase)
        /// The system has no recogniser for this language at all.
        case localeUnsupported(String)
        /// The turn carried no usable samples.
        case emptyAudio
        /// Audio could not be put into the shape the engine asked for.
        case audioNotConvertible

        var errorDescription: String? {
            switch self {
            case .assetsNotReady(let phase): return phase.summary
            case .localeUnsupported(let identifier):
                return String(localized: "Системный распознаватель не знает языка \(identifier)")
            case .emptyAudio: return String(localized: "В реплике не оказалось звука")
            case .audioNotConvertible:
                return String(localized: "Звук не удалось привести к формату системного распознавателя")
            }
        }
    }

    /// Language the engine is asked to recognise.
    private(set) var locale: Locale

    /// Where preparation has got to. Mirrored to the interface.
    private(set) var phase: SpeechModelPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            phaseContinuation?.yield(phase)
        }
    }

    private let assets: any SpeechAssetInstaller
    private var preparation: Task<Void, Never>?
    private var phaseContinuation: AsyncStream<SpeechModelPhase>.Continuation?

    init(
        locale: Locale = Locale(identifier: "ru-RU"),
        assets: any SpeechAssetInstaller = SystemSpeechAssets()
    ) {
        self.locale = locale
        self.assets = assets
    }

    deinit {
        preparation?.cancel()
        phaseContinuation?.finish()
    }

    /// Locales the system can recognise at all.
    ///
    /// Read from the API rather than listed here: the set grows with system
    /// updates, and a list written down in code would be wrong within a release.
    static var supportedLocales: [Locale] {
        get async { await DictationTranscriber.supportedLocales }
    }

    // MARK: - Progress for the interface

    /// Phases as they happen, starting with the current one.
    ///
    /// Single-consumer, exactly like the Whisper engine's: asking again replaces
    /// the previous stream.
    func phaseUpdates() -> AsyncStream<SpeechModelPhase> {
        phaseContinuation?.finish()
        let (stream, continuation) = AsyncStream<SpeechModelPhase>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        continuation.yield(phase)
        phaseContinuation = continuation
        return stream
    }

    /// Switches to another language. Takes effect on the turns that follow.
    func use(_ locale: Locale) {
        guard locale != self.locale else { return }
        preparation?.cancel()
        preparation = nil
        self.locale = locale
        phase = .idle
    }

    /// Installs the language assets if they are missing. Idempotent.
    ///
    /// Called by the settings screen so a download happens before the call
    /// rather than during it, and by `transcribe` when a turn arrives first.
    func prepare() {
        guard phase != .ready, preparation == nil else { return }
        let locale = locale

        preparation = Task {
            defer { preparation = nil }
            do {
                guard await assets.supports(locale) else {
                    phase = .failed(RecognitionError.localeUnsupported(locale.identifier(.bcp47))
                        .localizedDescription)
                    return
                }
                phase = .downloading(fraction: 0)
                try await assets.install(locale)
                try Task.checkCancellation()
                guard locale == self.locale else { return }
                phase = .ready
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Waits for the preparation currently in flight, if any.
    func prepared() async {
        await preparation?.value
    }

    // MARK: -

    static func transcriber(for locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [],
            // Passed even though a Russian run showed no punctuation coming
            // back: other locales may honour it, and silently withholding an
            // option is worse than an option that does nothing.
            transcriptionOptions: [.punctuation],
            reportingOptions: [],
            attributeOptions: []
        )
    }
}

@available(macOS 26, *)
extension NativeSpeechRecognizer: SpeechRecognizer {

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        guard !audio.samples.isEmpty else { throw RecognitionError.emptyAudio }
        guard phase.isReady else {
            // Same bargain the Whisper engine strikes: the turn that triggers
            // the install gets no text and stays in the transcript without any,
            // rather than being queued and arriving as a stale suggestion.
            prepare()
            throw RecognitionError.assetsNotReady(phase)
        }

        // The order matters: **until the assets are installed
        // `bestAvailableAudioFormat` answers nil** — measured on en-US, where no
        // format existed before the install and one appeared after it. So
        // readiness is checked above rather than inferred from a missing format;
        // otherwise "this language is not downloaded" would reach the user as
        // "the audio is the wrong shape".
        let module = Self.transcriber(for: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]),
              let buffer = Self.buffer(from: audio, in: format)
        else { throw RecognitionError.audioNotConvertible }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])

        let collected = Task {
            var text = ""
            for try await result in module.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collected.cancel()
            throw error
        }

        let text = try await collected.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts the turn into the exact format the engine asked for.
    ///
    /// **The conversion is not optional and not a formality.** The engine here
    /// asks for 16 kHz *Int16* while the pipeline carries Float32; handing over
    /// the samples as they are would not fail, it would produce silence — the
    /// failure mode `docs/audio-traps.md` is written about. So the format comes
    /// from `bestAvailableAudioFormat` and the samples are converted into it,
    /// rather than being declared compatible.
    static func buffer(from audio: SpeechAudio, in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.samples.count)),
        let channel = input.floatChannelData
        else { return nil }

        input.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }

        if source.sampleRate == format.sampleRate, source.commonFormat == format.commonFormat {
            return input
        }

        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(audio.samples.count) * ratio) + 4096
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
