//
//  TranscriptFormatter.swift
//  GhostMeet
//

import Foundation

/// Renders the transcript the way every prompt expects to see it — the shared
/// `formatTranscript(turns, limit)` of docs/GhostMeet-Prompts.md.
///
/// Each line is `Them: …` or `You: …`. The label comes from the turn's channel
/// and therefore from the source of its audio, never from what was said: this is
/// the only place where the two-channel guarantee becomes visible to the model.
///
/// Two things happen here that the stored transcript does not do, and both are
/// consequences of the hotkey (ADR-0008). Neighbouring turns of one channel are
/// **merged** into one line, because a question broken by a pause otherwise
/// reads as several people talking. And the window is bounded **by characters**
/// instead of by a count of turns, because the whole call now fits and the only
/// thing left to bound is the size of the request.
///
/// Storage is untouched by either. `SessionEngine` keeps every turn with its own
/// timestamp and duration; this is the prompt layer's view of that record, built
/// afresh for each request.
nonisolated enum TranscriptFormatter {

    /// Window value meaning "everything that was said" — the whole call.
    ///
    /// The default for every mode that reads the conversation at all. A
    /// 45-minute interview is around 30 000 characters of transcript with both
    /// sides in it, roughly 10–13 thousand tokens: that fits in one request
    /// whole, which is why the MVP has no Summarizer and why the modes stopped
    /// asking for the last twelve turns. What used to justify a small window was
    /// a background compressor that does not exist; what bounds the request now
    /// is `characterBudget`.
    static let wholeCall = 0

    /// Silence between two turns of one channel that still counts as one
    /// utterance.
    ///
    /// Deliberately larger than any pause a user can configure: the settings
    /// slider tops out at 2.0 s (`TurnSegmentationConfig.pauseThresholdRange`),
    /// so at every setting there is a band between "the segmenter cut here" and
    /// "these are two different thoughts" — otherwise merging would quietly
    /// become a no-op for whoever turned the threshold up. Three seconds is
    /// twice the default threshold and a third of the safety flush, so both the
    /// ordinary case (a speaker pausing to think) and the pathological one (a
    /// monologue chopped by the 10 s timer, gap ≈ 0) come back together.
    ///
    /// The upper bound is the interlocutor's own silence: if they say nothing
    /// for longer than this and then speak, the user has had time to answer —
    /// and if the user did answer, the turn of the other channel breaks the run
    /// anyway, whatever the gap.
    static let mergeGap: TimeInterval = 3

    /// Ceiling on the rendered transcript, in characters.
    ///
    /// The whole call fits under it: ~120 words per minute of interview speech,
    /// ~70 % of the wall clock actually spoken, ~6.5 characters per Russian word
    /// gives ≈ 27 000 characters for 45 minutes including the channel labels.
    /// 40 000 covers something over an hour, which is longer than the interview
    /// this MVP is built for, and caps the transcript at roughly 13–16 thousand
    /// tokens — affordable per press and comfortably inside the context of even
    /// a local 32k model.
    ///
    /// It is a ceiling and not a target: on a call short enough to fit, nothing
    /// here does anything at all.
    static let characterBudget = 40_000

    /// Said in place of the lines that did not fit.
    ///
    /// One line rather than silence: a transcript that simply starts in the
    /// middle of a sentence reads to the model as a call that began that way,
    /// and it will answer a question nobody asked. The `{{#if summary}}` slot of
    /// the prompt document is where the dropped part will eventually be
    /// summarised — until then this says plainly that it is gone.
    static let truncationNotice = "(начало разговора опущено — не поместилось)"

    /// The window handed to the model: the newest turns, oldest first, with
    /// neighbouring turns of one channel merged.
    ///
    /// - Parameters:
    ///   - limit: How many **lines** to keep after merging. `wholeCall` (0) means
    ///     all of them, bounded only by `budget`.
    ///   - budget: Ceiling in characters. The newest line is always kept, even
    ///     when it alone is over budget — a request with no conversation in it at
    ///     all would be worse than a long one.
    ///
    /// Turns with no recognised text are left out of the words. They exist in the
    /// transcript on purpose — a turn is kept even when recognition fails,
    /// because losing it would be worse — but a bare `Them:` in the prompt is
    /// noise. They still count as turns of their channel while merging, so a
    /// line the user said that came back empty still separates two questions.
    ///
    /// Turns marked as `Протечка канала` are left out **whole**, not merely
    /// silenced: as far as the conversation goes they never happened, so they do
    /// not break a run of `Them` either. This is where the mark that `LeakDedup`
    /// puts on a turn is spent — the model is not told that a line was dropped,
    /// because "the user said the interviewer's question back" is not a fact
    /// about the call, it is an artefact of the speakers.
    static func format(
        _ turns: [Turn],
        limit: Int,
        budget: Int = TranscriptFormatter.characterBudget
    ) -> String {
        let lines = merged(turns.filter { !$0.isLeak })
        let window = limit > 0 ? Array(lines.suffix(limit)) : lines
        return fitted(window, into: budget)
    }

    /// Whether the user has already started saying their answer out loud.
    ///
    /// **The short genre used to assert this unconditionally** — «Он **уже начал
    /// отвечать вслух**» — and the assertion is false in the case the app is
    /// actually built for: a press force-closes the open `Them` turn, which means
    /// the interviewer has only just stopped and the candidate has not opened
    /// their mouth yet. Both cases are real (the press also flushes `You`), so
    /// the app answers the question instead of guessing, and the prompt gets the
    /// sentence that is true.
    ///
    /// It is worth being told, and not only for tidiness: measured on the bench,
    /// a transcript ending in a half-finished `You` line makes models restate the
    /// words the candidate has already spoken — gpt-5.4-mini opened with a
    /// verbatim copy of the user's own line in both runs. Whatever the prompt
    /// says about it, it has to know which case it is in.
    ///
    /// Leaks do not count. A `You` turn marked by `LeakDedup` is the interviewer's
    /// voice coming back through the speakers, and treating it as the candidate
    /// speaking would assert the opposite of the truth precisely when the room is
    /// at its worst.
    static func hasStartedAnswering(_ turns: [Turn]) -> Bool {
        turns.last { !$0.isLeak && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .channel == .you
    }

    /// The question the press is about: the last thing the interlocutor said.
    ///
    /// **Named in the prompt because the transcript alone does not say which
    /// question is current, and a live run proved it.** Two `Them` lines in a row
    /// with nothing of the user's between them — which is what happens whenever
    /// they read a suggestion instead of answering aloud — leave the model to
    /// guess, and it answered the earlier one. With one question the last line is
    /// obviously the question; with two it is a coin toss the user pays for.
    ///
    /// Leaks and turns whose recognition came back empty are skipped: neither is
    /// something the interlocutor asked.
    static func currentQuestion(_ turns: [Turn]) -> String? {
        turns.last { $0.channel == .them && !$0.isLeak && $0.spokenText != nil }?.spokenText
    }

    /// The channel's name as the prompts spell it.
    static func label(for channel: Channel) -> String {
        switch channel {
        case .you: "You"
        case .them: "Them"
        }
    }

    // MARK: - Merging

    /// One rendered line per run of turns.
    ///
    /// A run continues while the channel stays the same **and** the gap between
    /// the end of what has been collected and the start of the next turn is at
    /// most `mergeGap`. Both conditions are load-bearing: the channel is what
    /// stops a question and its answer from becoming one line, and the gap is
    /// what stops two separate questions — asked ten minutes apart, with the user
    /// silent in between — from becoming one either.
    private static func merged(_ turns: [Turn]) -> [String] {
        var lines: [String] = []
        var run: (channel: Channel, endedAt: TimeInterval, parts: [String])?

        var closedByPress = false
        for turn in turns {
            let end = turn.timestamp + turn.duration
            if var current = run,
               current.channel == turn.channel,
               !closedByPress,
               turn.timestamp - current.endedAt <= mergeGap {
                current.endedAt = max(current.endedAt, end)
                if let text = turn.spokenText { current.parts.append(text) }
                run = current
            } else {
                if let finished = run { lines.append(contentsOf: line(of: finished)) }
                run = (turn.channel, end, turn.spokenText.map { [$0] } ?? [])
            }
            // A press closes the run: the next turn of the same channel is a
            // new thought however close it sits in time.
            closedByPress = turn.isBeforePress
        }
        if let finished = run { lines.append(contentsOf: line(of: finished)) }
        return lines
    }

    /// The run as one line, or nothing at all when not a word of it was
    /// recognised.
    private static func line(of run: (channel: Channel, endedAt: TimeInterval, parts: [String])) -> [String] {
        guard !run.parts.isEmpty else { return [] }
        return ["\(label(for: run.channel)): \(run.parts.joined(separator: " "))"]
    }

    // MARK: - The ceiling

    /// Keeps the newest lines that fit and says so when the rest were dropped.
    ///
    /// Counted from the end because the recent part of a conversation is the
    /// part being answered. The notice is added on top of the budget rather than
    /// inside it — a couple of dozen characters, and taking them out of the
    /// allowance would mean the number in the doc no longer matched the number
    /// in the code.
    private static func fitted(_ lines: [String], into budget: Int) -> String {
        guard budget > 0 else { return lines.joined(separator: "\n") }

        var kept: [String] = []
        var size = 0
        var dropped = false
        for line in lines.reversed() {
            let cost = line.count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty, size + cost > budget {
                dropped = true
                break
            }
            kept.append(line)
            size += cost
        }
        if dropped { kept.append(truncationNotice) }
        return kept.reversed().joined(separator: "\n")
    }
}

private extension Turn {
    /// What this turn contributes to a line, or `nil` when recognition gave
    /// nothing.
    nonisolated var spokenText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
