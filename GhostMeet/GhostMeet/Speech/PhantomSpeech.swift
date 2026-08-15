//
//  PhantomSpeech.swift
//  GhostMeet
//

import Foundation

/// Фантомная реплика: words the recogniser produced where nobody spoke.
///
/// A known Whisper behaviour rather than a broken capture. Handed a stretch of
/// audio with no speech in it — a breath, a keystroke, room noise, a headset
/// click — the model still has to emit something, and what it emits is a phrase
/// frequent in its training material. The set is recognisable and stable: the
/// closing lines of subtitled videos. `Thank you.`, `Thanks for watching`,
/// `Продолжение следует...`, `Спасибо за просмотр`, a bare `you`.
///
/// **Four of them in one 37-minute call**, in both channels — `Thank you.` at
/// 04:23 and 33:28, `you` at 22:24, `Продолжение следует...` at 24:10. The last
/// one is the reason this exists at all: a second interviewer had just joined
/// and asked about liveness and readiness probes, and that phrase took the
/// question's place in the transcript. A `Реплика` of `Them` that never happened
/// does not merely add a lie — it **displaces** what was really said, and the
/// answer that follows is coherent, on topic, and about something else. The user
/// cannot tell that from "the model misunderstood the question".
///
/// **This is not the RMS gate's business.** The gate decides whether a stretch of
/// audio is worth writing down, and here it decided correctly: there *was* sound.
/// What was untrue were the words. Raising the gate until a breath stops opening
/// a `Реплика` would lose quiet speech and fix none of this.
///
/// **Dropped, not marked — а deliberate departure from `Протечка канала`.** A
/// leak is marked and kept because its verdict is recomputable: the words of
/// `Them` that convict a `Реплика` of `You` routinely arrive after it, so
/// deleting on the spot would be deciding before the evidence. A phantom has
/// exactly one piece of evidence — its own text — and it is there immediately.
/// There is nothing to reconsider it on later. The `Реплика` itself stays in the
/// transcript without words, which is already the ordinary state of one whose
/// recognition failed.
///
/// ## Признак по звуку: что искали и чего не нашлось
///
/// A phrase list has to be topped up forever and is blind to whatever the next
/// model invents. A measure computed from the audio — Whisper's own
/// `no_speech_prob` — would depend on neither the language nor the list, and the
/// ticket asks for it to be the primary test if it can be had. **It cannot, in
/// the WhisperKit the app ships with.**
///
/// - `noSpeechProb` **is in the API and is always zero**: `TranscriptionSegment`
///   and `DecodingResult` both carry the field, and `TextDecoder.swift` fills it
///   with the literal `0` under `// TODO: implement no speech prob`
///   (argmax-oss-swift 1.0.0, revision `25c6299`). Anything thresholding it would
///   silently never fire. Re-check this line before believing the field on a
///   later version.
/// - `avgLogprob` **is** computed for real, and so is `compressionRatio`. Neither
///   reaches this layer: `SpeechModelSession` hands back a `String` and no
///   segments, deliberately (`SpeechModelProvider.swift`). Widening it is cheap;
///   what is missing is the material. Every threshold in this project is read out
///   of a measured gap between two sets, and there is no gap to read — the call
///   audio is never written to disk, so the phantoms are known only as text.
///
/// So the list below is the whole mechanism today, not the fallback it was meant
/// to be. When a set of recordings with phantoms in them exists, widen the seam,
/// measure the gap, and this list goes back to being insurance.
nonisolated enum PhantomSpeech {

    /// Фразы, which are never a `Реплика` of their own.
    ///
    /// **The rule for adding one is narrow, and it is the whole safety of this
    /// filter:** only a phrase a human in this scenario does not utter as an
    /// entire turn. Not "rarely says" — does not say *alone*, with nothing else
    /// in the turn. The cost of a mistake here is the cost of a false leak
    /// verdict, with a different victim: real speech deleted from the transcript
    /// and never seen by anybody.
    ///
    /// **`Спасибо.` is not on this list and must not be added.** It is said
    /// constantly in a Russian-language interview — as a whole turn, at that.
    /// `Thank you.` in the same interview is not: that is exactly why the English
    /// twin of a word said every other minute can be here at all.
    ///
    /// Four entries were seen in the recorded call; the other two are the same
    /// family of subtitle sign-offs, named in the spec. Others exist — `Субтитры
    /// сделал …` and its relatives end in a subtitler's name that varies, and a
    /// whole-string match cannot be built on a varying tail without material
    /// showing which tails actually occur. Top this up from transcripts, not from
    /// memory.
    static let phrases: [String] = [
        "Thank you.",              // 04:23 и 33:28 разобранного звонка
        "you",                     // 22:24 — одинокое местоимение, речью не бывает
        "Продолжение следует...",  // 24:10 — на месте вопроса про пробы живости
        "Thanks for watching",
        "Thank you for watching",
        "Спасибо за просмотр",
    ]

    /// Whether these words are a phantom rather than speech.
    ///
    /// **Whole-string, never containment.** «Thanks, я понял, а если
    /// шардировать» is speech; cutting a word out of it would damage the
    /// `Реплика` instead of dropping it, and dropping the whole turn over one
    /// matching word would lose a question outright.
    ///
    /// Normalisation is `LeakDedup.words` itself rather than a copy of it: case,
    /// punctuation and `ё` are exactly what two passes of one recogniser differ
    /// in, and two implementations of that would drift apart within a month.
    static func isPhantom(_ text: String) -> Bool {
        let words = LeakDedup.words(text)
        guard !words.isEmpty else { return false }
        return normalizedPhrases.contains(words.joined(separator: " "))
    }

    /// `phrases` put through the comparison's own normalisation.
    ///
    /// Kept apart from `phrases` so the list above reads the way the phrase
    /// arrives from recognition — with its capital letter and its full stop, the
    /// way it appeared in the transcript the user was staring at.
    private static let normalizedPhrases: Set<String> = Set(
        phrases.map { LeakDedup.words($0).joined(separator: " ") }
    )
}
