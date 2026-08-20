//
//  SwitchableSpeechRecognizer.swift
//  GhostMeet
//

import Foundation

/// One recogniser handed downwards, either engine behind it.
///
/// `SessionEngine` is given a recogniser once, at launch, and keeps it for the
/// life of the app; without this the only way to change engines would be to tear
/// the session down. Same shape as `SwitchableThemSource` does for capture, and
/// for the same reason (ADR-0001): the seam is swappable, so swapping it must not
/// reach the layers above.
///
/// **A turn in flight keeps the engine it started on.** Recognition is never
/// cancelled in this app — those words belong in the transcript whichever answer
/// survives — so a swap takes effect on the turns that follow, not on the one
/// being transcribed.
actor SwitchableSpeechRecognizer {

    private var current: any SpeechRecognizer
    private(set) var engine: SpeechEngine

    init(engine: SpeechEngine, recognizer: any SpeechRecognizer) {
        self.engine = engine
        self.current = recognizer
    }

    /// Puts another engine behind the protocol.
    func swap(to engine: SpeechEngine, recognizer: any SpeechRecognizer) {
        self.engine = engine
        self.current = recognizer
    }
}

extension SwitchableSpeechRecognizer: SpeechRecognizer {

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        try await current.transcribe(audio)
    }
}
