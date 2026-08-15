//
//  RecognitionFixture.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// A call whose turns actually get recognised.
///
/// Same shape as `CallFixture`, but with the real `WhisperSpeechRecognizer`
/// behind the protocol and a made-up model behind that: a scenario runs the whole
/// path from a frame of audio to a word in the transcript without a byte leaving
/// the machine — and through every step the real recogniser takes on the way,
/// which is what lets `Фантомная реплика` be tested where it is actually dropped.
@MainActor
struct RecognitionFixture {
    let engine: SessionEngine
    let recognizer: WhisperSpeechRecognizer

    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(provider: FakeSpeechModelProvider, model: WhisperModel = .default) {
        let clock = ManualClock()
        let recognizer = WhisperSpeechRecognizer(model: model, provider: provider)
        self.clock = clock
        self.recognizer = recognizer
        self.engine = SessionEngine(recognizer: recognizer, clock: clock)
    }

    var transcript: [Turn] { engine.transcript }

    /// Someone speaks into `channel` and then stops long enough to close the turn.
    func saysSomething(lasting seconds: TimeInterval, on channel: Channel = .you) {
        speaks(for: seconds, on: channel)
        staysQuiet(for: TurnSegmentationConfig.default.pauseThreshold + 0.2, on: channel)
    }

    func speaks(for seconds: TimeInterval, on channel: Channel = .you) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
    }

    func staysQuiet(for seconds: TimeInterval, on channel: Channel = .you) {
        feed(seconds: seconds) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    private func feed(seconds: TimeInterval, frame: () -> AudioFrame) {
        let frames = Int((seconds / frameLength).rounded())
        for _ in 0..<frames {
            clock.advance(by: frameLength)
            engine.ingest(frame())
        }
    }
}
