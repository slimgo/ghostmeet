//
//  InterviewLanguage.swift
//  GhostMeet
//

import Foundation

/// The language this interview is conducted in, as the user declares it.
///
/// **Not the interface language** (`AppLanguage`), and not a second setting
/// beside the recogniser's: it is one language, so it is one choice. It decides
/// what the model is told to answer in and which locale the system recogniser is
/// given.
///
/// **Why a declaration and not only detection.** `ConversationLanguage` reads the
/// script of the transcript, which is enough to decide one prompt rule and turned
/// out not to be enough to decide the answer's language. Measured on the assembled
/// prompt: the system prompt is 1328 words and 96 % Cyrillic, the profile and the
/// preparation notes are Russian, and an interviewer's question is around thirty
/// words — Russian text outweighs the English question 43 to 1. On a live English
/// interview the model answered in English once and spent the rest of the call
/// answering in the language of its instructions.
///
/// Detection stays as the default because it works on a Russian call, and a
/// Russian call is the scenario this product is built for.
nonisolated enum InterviewLanguage: String, CaseIterable, Codable, Sendable {
    /// Decide from the transcript, as the app always has.
    case automatic
    case russian
    case english

    /// The language handed to the system recogniser, which cannot work it out.
    ///
    /// Under `automatic` there is nothing declared to hand over, so the interface
    /// language stands in — the best guess available before a single word has
    /// been heard.
    var spoken: SpeechLanguage {
        switch self {
        case .russian: .russian
        case .english: .english
        case .automatic:
            // What the window is showing right now: `AppLanguage` has a «как в
            // системе» option, while the system recogniser needs a concrete
            // language.
            Locale.current.language.languageCode?.identifier == "ru" ? .russian : .english
        }
    }

    /// What the prompt layer should use, given what has been said so far.
    ///
    /// Only `automatic` looks at the transcript; a declared language wins over
    /// the script every time, including on a transcript that has not a single
    /// word in it yet.
    func conversation(given transcript: [Turn]) -> ConversationLanguage {
        switch self {
        case .russian: .russian
        case .english: .english
        case .automatic: ConversationLanguage.detected(in: transcript)
        }
    }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Авто")
        case .russian: String(localized: "Русский")
        case .english: String(localized: "Английский")
        }
    }

    /// One line saying what this choice does, for the menu that offers it.
    var explanation: String {
        switch self {
        case .automatic:
            String(localized: "Язык определяется по разговору. Системному распознавателю при этом достаётся язык интерфейса.")
        case .russian:
            String(localized: "Подсказки на русском, со скобками произношения за латиницей.")
        case .english:
            String(localized: "Подсказки на английском. Скобок с произношением нет — вслух они читаются как мусор.")
        }
    }
}
