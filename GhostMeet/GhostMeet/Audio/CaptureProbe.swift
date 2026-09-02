//
//  CaptureProbe.swift
//  GhostMeet
//

import Foundation

/// What actually arrived in one channel while a check was running.
///
/// **Three states, not two, and the third is the point.** A channel that received
/// no frames at all is broken; a channel that received frames with nothing in them
/// is the failure `docs/audio-traps.md` is written about — macOS reporting one
/// audio format and delivering another has never once produced an error code, only
/// silence. And a channel that is simply quiet because nobody spoke looks exactly
/// like the second case, so the check cannot call it a pass either: it asks the
/// user to say something and look again.
nonisolated struct ChannelProbe: Equatable, Sendable {

    /// Frames handed over during the window.
    private(set) var frames = 0
    /// Samples in them — a frame count alone hides a source delivering empty buffers.
    private(set) var samples = 0
    /// Loudest sample seen, `0...1`.
    private(set) var peak: Float = 0

    mutating func take(_ frame: AudioFrame) {
        frames += 1
        samples += frame.samples.count
        for sample in frame.samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
    }

    /// How this channel is doing, in the words the window will use.
    enum Verdict: Equatable, Sendable {
        /// Nothing arrived: the capture path is dead.
        case noFrames
        /// Frames arrived carrying no signal — dead tract, or nobody spoke.
        case silent
        /// Sound is coming through.
        case sound(peak: Float)
    }

    /// The threshold below which a channel counts as silent.
    ///
    /// Deliberately low. This separates «есть сигнал» from «строго нули и шум
    /// разрядности», not loud speech from quiet speech: a microphone that hears a
    /// person across the room sits far above it, while a dead tract sits at zero.
    static let silenceFloor: Float = 0.002

    var verdict: Verdict {
        guard frames > 0, samples > 0 else { return .noFrames }
        return peak > Self.silenceFloor ? .sound(peak: peak) : .silent
    }
}

/// Frame accounting for both channels, alive only while a check runs.
///
/// **It exists on request and not otherwise.** The audio investigation ended with
/// every level probe removed from this app — no diagnostics object, no per-frame
/// measurement — and bringing them back permanently would undo that. This one is
/// created when the user presses the button and dropped when the check ends.
nonisolated struct CaptureProbe: Equatable, Sendable {

    private(set) var you = ChannelProbe()
    private(set) var them = ChannelProbe()

    mutating func take(_ frame: AudioFrame) {
        switch frame.channel {
        case .you: you.take(frame)
        case .them: them.take(frame)
        }
    }

    subscript(channel: Channel) -> ChannelProbe {
        switch channel {
        case .you: you
        case .them: them
        }
    }
}
