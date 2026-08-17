//
//  AppLanguage.swift
//  GhostMeet
//

import Foundation

/// The language the application speaks to its user.
///
/// **Not the language of the call, and not the language of a suggestion.** Those
/// follow the conversation and always have: recognition detects the language of
/// every turn on its own (`WhisperKitModelProvider` runs with `language: nil` and
/// `detectLanguage: true`), and every prompt says «Язык ответа — язык разговора».
/// A Russian interface on an English interview must still produce an English
/// suggestion — it is read aloud to the interviewer, not to the user. This type
/// has no say in that whatsoever.
enum AppLanguage: String, CaseIterable, Sendable, Identifiable {

    /// Whatever the system is set to. The default, and not «русский»: the app is
    /// handed over as a disk image, and somebody whose Mac speaks English should
    /// not have to find a switch before they can read the window.
    case system
    case russian
    case english

    var id: String { rawValue }

    /// The identifier written into `AppleLanguages`, or nil for "let the system
    /// decide".
    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .russian: "ru"
        case .english: "en"
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "Как в системе")
        case .russian: String(localized: "Русский")
        case .english: String(localized: "English")
        }
    }
}

extension AppLanguage {

    /// The key macOS itself reads to decide which localisation a bundle serves.
    static let appleLanguagesKey = "AppleLanguages"

    /// Where the user's *choice* is kept.
    ///
    /// **Separate from `AppleLanguages`, and it has to be.** That key answers
    /// «на каком языке рисовать», and it always has an answer — `UserDefaults`
    /// falls through to the global domain, where macOS keeps the system's own
    /// list. Read it back as a choice and «как в системе» comes out as «Русский»
    /// on a Russian Mac: the picker would show a language the user never picked,
    /// and choosing «как в системе» would look like it did nothing.
    ///
    /// So this key records what was chosen, `AppleLanguages` carries it out, and
    /// the direction is one-way — nothing reads the second to answer the first.
    /// Found by a test, which is the only reason it is not a bug in the picker.
    static let choiceKey = "settings.appLanguage"

    /// Puts the choice where the system will find it.
    ///
    /// **Through `AppleLanguages` and a restart, rather than through
    /// `Environment(\.locale)` and no restart.** The second is nicer to use and
    /// was rejected on a specific ground: it only reaches strings resolved inside
    /// a SwiftUI view. Half of what this app shows is a plain `String` produced by
    /// a model — the phase of the recognition model, the summary of a capture
    /// backend, the wording of a provider failure — and every one of those would
    /// have gone on answering in the old language, silently, until somebody
    /// noticed a Russian sentence on an English screen. There is no seam to forget
    /// here: the system reads one key and every string in the bundle follows.
    ///
    /// The cost is a restart, and it is stated next to the switch. Somebody whose
    /// choice appears not to have worked goes looking for a bug in the program.
    func apply(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.choiceKey)
        if let localeIdentifier {
            defaults.set([localeIdentifier], forKey: Self.appleLanguagesKey)
        } else {
            // Removing rather than writing the system's current list: the point of
            // «как в системе» is to keep following it, including after the user
            // changes it in System Settings. What remains after the removal is
            // the global domain's own value, which is exactly right.
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        }
    }

    /// What the user chose, or `.system` if they never did.
    static func stored(in defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: choiceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Which language the bundle will actually be drawn in.
    ///
    /// Not the same question as `stored(in:)`: under «как в системе» the choice is
    /// `.system` and the answer here is whatever macOS is set to. Separate because
    /// mixing them is precisely the mistake this pair exists to prevent.
    static func effective(in defaults: UserDefaults) -> AppLanguage? {
        guard let languages = defaults.array(forKey: appleLanguagesKey) as? [String],
              let first = languages.first else { return nil }
        // A stored value is a full identifier — «en», «ru», sometimes «ru-CY» —
        // and only its language part decides.
        let code = String(first.prefix(2))
        return allCases.first { $0.localeIdentifier == code }
    }
}
