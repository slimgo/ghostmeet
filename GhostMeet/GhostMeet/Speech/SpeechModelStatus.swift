//
//  SpeechModelStatus.swift
//  GhostMeet
//

import Foundation
import Observation
import os

/// What the interface knows and can do about the recognition model.
///
/// The recogniser is an actor and the settings screen is a SwiftUI view; this is
/// the one place where those two meet. It owns nothing of its own: the choice of
/// model lives in `SettingsStore` (so it survives a restart) and the phase lives
/// in the recogniser (so it is true even when no window is open). This type
/// mirrors the phase onto the main actor and writes the choice through.
///
/// Its `recognizer` is what the app hands to `SessionController.dualChannel`;
/// from there down everything sees `SpeechRecognizer` and nothing else.
@MainActor
@Observable
final class SpeechModelStatus {

    /// Shared instance over the shared settings.
    static let shared = SpeechModelStatus(store: .shared)

    /// Where preparation of the selected model has got to.
    private(set) var phase: SpeechModelPhase = .idle

    /// Selected model. Writing it persists the choice and tells the recogniser.
    var model: WhisperModel {
        get { store.speechModel }
        set {
            guard newValue != store.speechModel else { return }
            store.speechModel = newValue
            let whisper = whisperRecognizer
            Task { await whisper.use(newValue) }
        }
    }

    /// Selected engine. Writing it persists the choice and swaps what is behind
    /// the protocol, without tearing the session down.
    var engine: SpeechEngine {
        get { store.speechEngine }
        set {
            guard newValue != store.speechEngine, newValue.isAvailable else { return }
            store.speechEngine = newValue
            activate(newValue)
        }
    }

    /// The interview's language. Reaches the system engine; Whisper ignores it.
    var language: InterviewLanguage {
        get { store.interviewLanguage }
        set {
            guard newValue != store.interviewLanguage else { return }
            store.interviewLanguage = newValue
            guard store.speechEngine == .system, #available(macOS 26, *),
                  let native = nativeRecognizer else { return }
            Task {
                await native.use(newValue.spoken.locale)
                await native.prepare()
            }
        }
    }

    /// The recogniser to hand to `SessionEngine`.
    ///
    /// Deliberately the switchable wrapper and not either engine: the engine is
    /// handed downwards once at launch, so without the wrapper changing it would
    /// mean rebuilding the session.
    let recognizer: SwitchableSpeechRecognizer

    /// Whisper is built at launch either way — it is the fallback whenever the
    /// system engine is unavailable, and building it downloads nothing.
    ///
    /// Visible to tests rather than private: which model reached Whisper is not
    /// observable through the wrapper, and it is exactly what a test about the
    /// model picker has to check.
    @ObservationIgnored let whisperRecognizer: WhisperSpeechRecognizer

    /// Built on first use, and only where it exists.
    @ObservationIgnored private var nativeStorage: AnyObject?

    @ObservationIgnored private let store: SettingsStore

    /// Every phase change goes to the system log as well as to the window.
    ///
    /// Preparation takes seconds even for a model already on disk, and the
    /// overlay is excluded from screen capture — so when the app misbehaves on
    /// someone else's machine, this log is the only way to tell "the model was
    /// still loading" apart from "recognition is broken".
    @ObservationIgnored private static let log = Logger(
        subsystem: "Mixxy.GhostMeet",
        category: "speech"
    )

    @ObservationIgnored private var observation: Task<Void, Never>?

    init(
        store: SettingsStore,
        provider: any SpeechModelProvider = WhisperKitModelProvider()
    ) {
        self.store = store
        let whisper = WhisperSpeechRecognizer(model: store.speechModel, provider: provider)
        self.whisperRecognizer = whisper
        self.recognizer = SwitchableSpeechRecognizer(engine: .whisper, recognizer: whisper)

        activate(store.speechEngine)
    }

    /// Puts the chosen engine behind the protocol and follows its phase.
    private func activate(_ engine: SpeechEngine) {
        observation?.cancel()

        guard engine == .system, #available(macOS 26, *) else {
            let whisper = whisperRecognizer
            let recognizer = recognizer
            Task { await recognizer.swap(to: .whisper, recognizer: whisper) }
            follow { await whisper.phaseUpdates() }
            return
        }

        let native: NativeSpeechRecognizer
        if let existing = nativeRecognizer {
            native = existing
        } else {
            native = NativeSpeechRecognizer(locale: store.interviewLanguage.spoken.locale)
            nativeStorage = native
        }
        let recognizer = recognizer
        Task { await recognizer.swap(to: .system, recognizer: native) }
        follow { await native.phaseUpdates() }
    }

    @available(macOS 26, *)
    private var nativeRecognizer: NativeSpeechRecognizer? {
        nativeStorage as? NativeSpeechRecognizer
    }

    /// Mirrors one engine's phases onto the main actor.
    ///
    /// The window shows the phase of the engine actually behind the protocol;
    /// following the other one would say "ready" while turns come back empty.
    private func follow(_ phases: @escaping @Sendable () async -> AsyncStream<SpeechModelPhase>) {
        observation = Task { [weak self] in
            for await phase in await phases() {
                Self.log.info("РАСПОЗНАВАНИЕ: \(phase.summary, privacy: .public)")
                self?.phase = phase
            }
        }
    }

    deinit {
        observation?.cancel()
    }

    /// Downloads and loads the selected model now.
    ///
    /// Nothing calls this automatically: a model is fetched either from the
    /// settings screen, deliberately, or by the first turn of a call. Starting a
    /// gigabyte-sized download because a window opened would be a surprise.
    func prepare() {
        if store.speechEngine == .system, #available(macOS 26, *), let native = nativeRecognizer {
            Task { await native.prepare() }
            return
        }
        let whisper = whisperRecognizer
        Task { await whisper.prepare() }
    }
}
