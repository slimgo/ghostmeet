//
//  LeakDedup.swift
//  GhostMeet
//

import Foundation

/// Deduplication by text: the second layer against `Протечка канала`, and the
/// only one that works on words instead of on decibels.
///
/// A `Реплика` of `You` whose recognised text is the neighbouring `Реплика` of
/// `Them` said again is not the user speaking — it is the interlocutor coming
/// back out of the speakers. This layer is here because the first one, strict
/// mode, has a floor it cannot cross: it refuses to break a `Реплика` that was
/// already open, so a leak that opened one before the first loud `Them` frame
/// arrived lands in the transcript whole (see `.scratch/no-vpio/issues/03-strict-mode.md`).
/// Judging the words afterwards costs microseconds, depends on neither loudness
/// nor the microphone's AGC, and adds no dependency.
///
/// **The rule is two conditions, and they divide the work between them.**
///
/// *Time.* The leak is simultaneous with the speech it copies — that is what it
/// is. So a `Реплика` of `You` is only ever compared with the `Реплики` of
/// `Them` it overlaps in time, give or take `neighbourhood`. This is not merely
/// the "no match with half an hour ago" guard the ticket asks for: it is the
/// **only** thing that separates a leak from a candidate repeating a bare
/// fragment of the question, because by the words alone those two are the same
/// string. A candidate repeats after the interviewer stops; a leak cannot.
///
/// *Words.* Inside that window, how much of what `You` said is `Them` said
/// again, in the same order — `coverage`. Asymmetric on purpose: a leak that
/// only half reached recognition is still a leak, and demanding that `You`
/// cover `Them` too would lose exactly that case.
///
/// **Every number here was measured**, on real recogniser output rather than
/// chosen for looking round — the leak recordings of the ADR-0009 investigation
/// cut into `Реплики` by the app's own segmentation and transcribed by the model
/// the app ships with. See «Как подобран порог» in the ticket.
nonisolated enum LeakDedup {

    /// How much of a `Реплика` of `You` has to be the interlocutor's words for
    /// it to be their voice rather than the user's.
    ///
    /// **0.83, and the number was read out of a measured gap rather than
    /// chosen.** Over 9 leak `Реплики` recognised from the real recordings — 4
    /// whole, 5 cut into halves and tails so that recognition only got part of
    /// the phrase — coverage ran 0.857 to 1.00 for all but one. Over 12 honest
    /// ones spoken against the same question — the candidate repeating it back
    /// with a frame («правильно ли я понял, вы спрашиваете про…»), checking one
    /// clause, or simply answering — the highest was 0.80, and that was the
    /// near-verbatim «Вы спрашиваете, чем актор в свифте отличается от обычного
    /// класса?».
    ///
    /// So the gap is 0.80 … 0.857, and on this material every value inside it
    /// decides identically: 8 of 9 leaks caught, 0 of 12 honest turns touched.
    /// The middle of it is taken because that is the one choice that claims no
    /// knowledge the measurement does not contain — a threshold pushed to either
    /// edge is a bet on which way the next call's numbers will drift.
    ///
    /// The margins are one word wide on a short `Реплика` — 6 of 7 words is
    /// 0.857, 5 of 7 is 0.714 — which is why `minimumOverlap` exists and why the
    /// time window carries the cases this number cannot.
    static let coverageThreshold: Double = 0.83

    /// How many words have to be the same before the ratio means anything.
    ///
    /// **5.** With one to four words the coverage is not a measurement, it is a
    /// coincidence: «да», «понял», «секунду» share words with almost any question
    /// asked in Russian, and «Актор в свифте» is 3 words of pure agreement with
    /// the interviewer. Every leak measured except one had 6 or more words in
    /// common; the exception is a 2.7-second fragment that came back as
    /// «Расскажите, чем актер связан?», which is not recoverable by any threshold
    /// because two of its four words are wrong.
    static let minimumOverlap = 5

    /// Slack around the requirement that the two `Реплики` **overlap** in time.
    ///
    /// Not a neighbourhood in the ordinary sense, and the difference decides a
    /// real case. A leak is *simultaneous* with `Them` by construction: it is the
    /// same sound taking a different path. An honest repeat — «правильно ли я
    /// понял, вы спрашиваете про…» — comes *after* the interlocutor stopped, and
    /// the pause between two turns in conversation is around 0.2 s. So the two
    /// are told apart by overlap, not by proximity, and this number is only the
    /// tolerance for two capture paths whose buffers differ.
    ///
    /// It used to be 0.4 s, borrowed from `SessionEngine.echoTail`. That was
    /// wrong twice over: `echoTail` measures how long the room keeps ringing,
    /// which is a fact about the microphone and not about turn boundaries, and
    /// at 0.4 s the ordinary conversational pause fits inside the window — so
    /// the honest repeat, which is word-for-word what a leak looks like, was
    /// deleted from the user's own transcript more often than not.
    static let neighbourhood: TimeInterval = 0.15

    /// Re-decides the mark on one `Реплика` of `You`.
    ///
    /// Pure and recomputable on purpose: recognition of the two channels runs
    /// side by side and finishes in whatever order it finishes, so the words of
    /// `Them` that convict a `Реплика` of `You` routinely arrive after it. A
    /// verdict reached once and frozen would be a verdict reached before the
    /// evidence.
    static func isLeak(_ turn: Turn, among turns: [Turn]) -> Bool {
        guard turn.channel == .you else { return false }
        let mine = words(turn.text)
        guard !mine.isEmpty else { return false }

        let theirs = turns
            .filter { $0.channel == .them && overlap(turn, $0) }
            .sorted { $0.timestamp < $1.timestamp }
            .flatMap { words($0.text) }
        guard !theirs.isEmpty else { return false }

        let matched = commonSubsequenceLength(mine, theirs)
        guard matched >= minimumOverlap else { return false }
        return Double(matched) / Double(mine.count) >= coverageThreshold
    }

    /// Whether the two `Реплики` are close enough in time to be the same speech.
    ///
    /// Overlapping ones give a non-positive gap; `neighbourhood` is the slack for
    /// two capture paths with buffers of their own and for the room still ringing
    /// after the speaker has gone quiet.
    static func overlap(_ one: Turn, _ other: Turn) -> Bool {
        let gap = max(
            one.timestamp - (other.timestamp + other.duration),
            other.timestamp - (one.timestamp + one.duration)
        )
        return gap <= neighbourhood
    }

    /// How much of `said` the words of `heard` cover, in order — `0...1`.
    ///
    /// Exposed because it is the number the threshold is about, and a test that
    /// checks decisions only cannot say how close to the edge a case ran.
    static func coverage(of said: String, in heard: String) -> Double {
        let mine = words(said)
        guard !mine.isEmpty else { return 0 }
        return Double(commonSubsequenceLength(mine, words(heard))) / Double(mine.count)
    }

    // MARK: - Words

    /// The text as words that can be compared.
    ///
    /// Case, punctuation and `ё` go, because two passes of the same recogniser
    /// over the same phrase differ in exactly those and in nothing that matters.
    /// Nothing else is normalised, and a fuzzy word match — «обычных» ~
    /// «обычного», «актер» ~ «актор» above a normalised edit distance — was
    /// tried and dropped. It bought nothing where it was needed: the tightest
    /// leak in the set did not move at all (0.857 either way), while the honest
    /// repeats climbed by up to 0.13 and the second-highest of them went 0.667 →
    /// 0.750, i.e. from comfortable to one word off the threshold. Loosening the
    /// comparison helps whoever is already close to it, and that is the honest
    /// speech, not the leak.
    static func words(_ text: String) -> [String] {
        text
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Length of the longest common subsequence of two word sequences.
    ///
    /// A subsequence rather than a set: word order is what tells «требует await
    /// при обращении к свойствам» from an answer that happens to use the same
    /// vocabulary in a different arrangement. Two rows of the table are enough,
    /// and both sequences are one `Реплика` long.
    private static func commonSubsequenceLength(_ mine: [String], _ theirs: [String]) -> Int {
        guard !mine.isEmpty, !theirs.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: theirs.count + 1)
        var current = previous
        for word in mine {
            for (index, other) in theirs.enumerated() {
                current[index + 1] = word == other
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous[theirs.count]
    }
}
