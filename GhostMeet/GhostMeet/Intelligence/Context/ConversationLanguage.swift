//
//  ConversationLanguage.swift
//  GhostMeet
//

import Foundation

/// Which language the call is being conducted in, as far as the prompt needs to
/// know.
///
/// **Not the language of the interface** (`AppLanguage`) and not a setting. A
/// suggestion is read aloud to the interviewer, so it follows the conversation —
/// that is what every prompt has always said. What is new is that one rule inside
/// the prompt has to follow it too.
///
/// **The rule in question is the pronunciation bracket.** It tells the model to
/// put a Russian pronunciation after every Latin term — `nginx (энджин-икс)` —
/// because the user reads the answer aloud and cannot read Latin aloud inside a
/// Russian sentence. In an English interview the answer is English, everything in
/// it is Latin, and the reader pronounces it natively; a Cyrillic gloss in the
/// middle of a spoken English sentence is not a nuance, it is unreadable.
///
/// **Decided by the script of the transcript, not by asking the model.** The
/// alternative — leaving the rule in and adding «только когда ответ по-русски» —
/// was rejected without measuring it, and deliberately: this project has already
/// recorded that a prohibition gets obeyed to the letter while examples get
/// executed, and the rule carries nine Cyrillic examples against one caveat. A
/// rule that is physically absent from the prompt cannot be half-obeyed.
enum ConversationLanguage: Sendable, Equatable {
    case russian
    case english

    /// The default when there is nothing to judge by.
    ///
    /// Russian, because that is what the prompts are written in and what the
    /// project's own scenario is. An empty transcript means the user pressed
    /// before anybody said anything — the rule costs an English answer nothing at
    /// that point, because there is no answer yet.
    static let `default` = ConversationLanguage.russian

    /// Reads the language off the transcript.
    ///
    /// By script rather than by words: Cyrillic against Latin is a signal that
    /// needs no dictionary, no model and no per-turn language tag from the
    /// recogniser. Technical speech in Russian is full of Latin terms — «поднял
    /// Kubernetes через Helm» — so the threshold is deliberately not «any Latin
    /// at all»: a call counts as English only when Latin clearly dominates.
    static func detected(in turns: [Turn]) -> ConversationLanguage {
        let text = turns.map(\.text).joined(separator: " ")
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0410...0x044F, 0x0401, 0x0451: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: break
            }
        }
        // Too little to judge is not English — see `default`.
        guard cyrillic + latin >= 20 else { return .default }
        // Four to one. A Russian technical turn can be a third Latin without
        // being an English turn; an actual English call is almost entirely Latin.
        return latin > cyrillic * 4 ? .english : .russian
    }
}
