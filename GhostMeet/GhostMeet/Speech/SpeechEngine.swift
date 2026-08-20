//
//  SpeechEngine.swift
//  GhostMeet
//

import Foundation

/// Which recogniser turns audio into words.
///
/// Two implementations behind one protocol, chosen in settings (ADR-0001), and
/// the choice is a real trade rather than a preference — see
/// [ADR-0013](../../../docs/adr/0013-native-recogniser-knows-russian-but-loses-the-terms.md).
/// Measured on the same audio: the system engine is two to four times faster and
/// invents nothing on silence; Whisper keeps technical terms, punctuates, and
/// works out the language by itself.
nonisolated enum SpeechEngine: String, CaseIterable, Codable, Sendable {
    /// WhisperKit on the Neural Engine. The default.
    case whisper
    /// The system's `SpeechAnalyzer`. macOS 26 and later only.
    case system

    /// Whether this machine can run it at all.
    ///
    /// The system engine does not exist below macOS 26 — not disabled, absent:
    /// an option that cannot be chosen reads as a broken app.
    var isAvailable: Bool {
        switch self {
        case .whisper: return true
        case .system:
            if #available(macOS 26, *) { return true }
            return false
        }
    }

    static var available: [SpeechEngine] { allCases.filter(\.isAvailable) }

    var displayName: String {
        switch self {
        case .whisper: return String(localized: "Whisper (на устройстве)")
        case .system: return String(localized: "Системный (macOS 26)")
        }
    }

    /// What the user is trading, in one line under the picker.
    ///
    /// Both halves are measured, not asserted, and both are said out loud: the
    /// transcript goes into the prompt whole, so a weaker transcript is a weaker
    /// answer that still reads as a confident one.
    var tradeOff: String {
        switch self {
        case .whisper:
            return String(localized: "Точнее на терминах, ставит знаки препинания и сам определяет язык. Медленнее и требует загрузки модели.")
        case .system:
            return String(localized: "Быстрее в два-четыре раза и ничего не выдумывает в паузах. На русском теряет термины и знаки препинания; язык звонка нужно выбрать заранее.")
        }
    }

    /// Whether the language of the call has to be named by hand.
    ///
    /// Whisper works it out from the audio. The system engine has to be told
    /// before it hears anything — and `ConversationLanguage` is read *from* the
    /// transcript the recogniser produces, so for this engine it is a circle only
    /// the user can break.
    var needsExplicitLanguage: Bool { self == .system }
}

/// Language handed to the system recogniser.
///
/// A short list rather than all fifty-four locales the API reports: this is the
/// language of an interview, and a picker with fifty-four rows makes the two that
/// matter harder to find. The full list is still what the engine is checked
/// against — an unsupported choice fails with the language named.
nonisolated enum SpeechLanguage: String, CaseIterable, Codable, Sendable {
    case russian
    case english

    var localeIdentifier: String {
        switch self {
        case .russian: return "ru-RU"
        case .english: return "en-US"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    var displayName: String {
        switch self {
        case .russian: return String(localized: "Русский")
        case .english: return String(localized: "Английский")
        }
    }
}
