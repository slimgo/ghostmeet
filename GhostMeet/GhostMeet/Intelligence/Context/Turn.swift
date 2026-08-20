//
//  Turn.swift
//  GhostMeet
//

import Foundation

/// One of the two independent speech channels of a call.
///
/// A channel is decided by the source the audio came from and never by what was
/// said: everything the microphone picks up is `you`, even when the user reads
/// somebody else's question out loud; everything taken from the source app is `them`.
nonisolated enum Channel: String, Hashable, Sendable, CaseIterable {
    /// The user's own speech, captured from the microphone.
    case you
    /// Everyone else on the call, captured from the source app.
    case them
}

/// A turn: one continuous stretch of speech of a single channel, closed by a pause.
///
/// A turn always belongs to exactly one channel — there is no such thing as a
/// shared turn. The ordered sequence of turns is the transcript, the only
/// representation of the conversation the model ever sees.
nonisolated struct Turn: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Channel this turn belongs to, taken from the source of its audio.
    let channel: Channel
    /// Recognised text. Empty while recognition has not produced anything for
    /// this turn yet — and empty by design as long as recognition is stubbed.
    var text: String
    /// Session-clock time the speech started at.
    let timestamp: TimeInterval
    /// Length of the speech in seconds, pauses inside the turn included.
    let duration: TimeInterval
    /// Whether this is `Протечка канала` rather than speech of its own: a turn of
    /// `You` whose words are the neighbouring turn of `Them` said again, that is
    /// the interlocutor coming back out of the speakers.
    ///
    /// **Marked and kept, not deleted**, and the reason is the same one that
    /// makes the decision recomputable at all: the two channels are recognised
    /// side by side, so the words of `Them` that convict a turn of `You` usually
    /// arrive after it. Deleting on the spot would mean deciding before the
    /// evidence, with nothing left to decide again on. What the prompt layer does
    /// with the mark is a separate question, and `TranscriptFormatter` answers it
    /// by leaving the line out altogether — the model is never told that a turn
    /// was dropped, so there is nothing to explain to it.
    ///
    /// Set by `LeakDedup` through `SessionEngine`; nothing in the audio layer
    /// touches it.
    var isLeak: Bool

    /// A press happened **after** this turn: everything up to and including it
    /// has already gone to the model.
    ///
    /// A boundary rather than a property of the turn itself, and it exists
    /// because of a real failure. Merging joins consecutive turns of one channel
    /// because people ask questions with pauses in them — but «один вопрос,
    /// разрезанный паузой» cannot be told from «два разных вопроса, между
    /// которыми никто не ответил» by sound: from the outside they are the same
    /// thing. The press is what tells them apart: the user pressed, so they have
    /// already dealt with the previous question.
    ///
    /// Without this, two questions in a row reached the model as one line — while
    /// the prompt says of a `Them:` line that it is one person and one thought —
    /// and the model answered the start of the merge, that is, the previous
    /// question.
    var isBeforePress: Bool = false

    init(
        id: UUID = UUID(),
        channel: Channel,
        text: String = "",
        timestamp: TimeInterval,
        duration: TimeInterval,
        isLeak: Bool = false
    ) {
        self.id = id
        self.channel = channel
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.isLeak = isLeak
    }
}
