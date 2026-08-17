//
//  WhisperModel.swift
//  GhostMeet
//

import Foundation

/// A recognition model the user picks in settings.
///
/// Every entry here is **multilingual on purpose**, and that is the whole design
/// of the list: an interview switches between Russian and English inside one
/// call, sometimes inside one sentence. Whisper's `.en` variants cannot do
/// Russian at all, so offering them would create a setting the user has to
/// remember to flip mid-call. With a multilingual model the language is detected
/// per turn and nothing has to be switched by hand — see
/// `docs/adr/0002-stt-engine-choice.md`.
///
/// The raw value is what gets persisted; `variant` is the folder name in the
/// WhisperKit CoreML repo and may be re-pointed without invalidating a stored
/// preference.
nonisolated enum WhisperModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case tiny
    case base
    case small
    case largeV3Turbo
    case largeV3TurboFull

    /// Rate every Whisper model expects. Audio arriving at any other rate is
    /// resampled before recognition.
    static let requiredSampleRate: Double = 16_000

    /// What a fresh install starts with.
    ///
    /// The compressed turbo build of large-v3 is the only entry that is both
    /// fast enough to answer inside a sentence and good enough at Russian to be worth
    /// showing to the user. The smaller variants are kept for machines and
    /// networks that cannot take it, not as a recommendation.
    static let `default`: WhisperModel = .largeV3Turbo

    var id: String { rawValue }

    /// Folder name of the model in `argmaxinc/whisperkit-coreml`.
    var variant: String {
        switch self {
        case .tiny: return "openai_whisper-tiny"
        case .base: return "openai_whisper-base"
        case .small: return "openai_whisper-small"
        case .largeV3Turbo: return "openai_whisper-large-v3-v20240930_626MB"
        case .largeV3TurboFull: return "openai_whisper-large-v3-v20240930_turbo"
        }
    }

    var title: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largeV3Turbo: return String(localized: "Large v3 Turbo (сжатая)")
        case .largeV3TurboFull: return "Large v3 Turbo"
        }
    }

    /// Roughly how much has to be downloaded on first use. Shown next to the
    /// name because the download is the one thing that can take minutes.
    var approximateDownloadSize: String {
        switch self {
        case .tiny: return String(localized: "~75 МБ")
        case .base: return String(localized: "~145 МБ")
        case .small: return String(localized: "~480 МБ")
        case .largeV3Turbo: return String(localized: "~630 МБ")
        case .largeV3TurboFull: return String(localized: "~1,6 ГБ")
        }
    }

    /// One line of guidance for the settings screen.
    var summary: String {
        switch self {
        case .tiny:
            return String(localized: "Самая быстрая и самая неточная. Русский разбирает плохо — для проверки, что пайплайн вообще жив.")
        case .base:
            return String(localized: "Быстрая, но на русском часто путает термины.")
        case .small:
            return String(localized: "Компромисс для слабых машин: заметно точнее base и всё ещё небольшая.")
        case .largeV3Turbo:
            return String(localized: "Рекомендуемая: качество large-v3-turbo при вдвое меньшем размере.")
        case .largeV3TurboFull:
            return String(localized: "Максимальное качество. Дольше качается и заметнее греет машину.")
        }
    }
}
