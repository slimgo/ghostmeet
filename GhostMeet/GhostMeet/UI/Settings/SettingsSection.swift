//
//  SettingsSection.swift
//  GhostMeet
//

import Foundation

/// A section of the settings screen, named so that somewhere else in the app can
/// point at it.
///
/// The readiness strip states a fact and offers to change it; without this the
/// offer lands the user in a form of nine sections and leaves them to find the
/// one that was just mentioned. These are the anchors, in the order they are
/// drawn — see `SettingsTab` for which page each one is drawn on.
enum SettingsSection: String, CaseIterable, Sendable {
    case profile
    case interviewContext
    case captureBackend
    case sourceApplication
    case recognition
    case provider
    case providerKey
    case segmentation
    case language
    case updates

    /// The page this section lives on. Total, and deliberately so: a section
    /// with no tab would be a control the readiness strip offers and the window
    /// cannot show.
    var tab: SettingsTab {
        switch self {
        case .profile, .interviewContext: .profile
        case .captureBackend, .sourceApplication, .segmentation: .sound
        case .recognition: .recognition
        case .provider, .providerKey: .model
        case .language, .updates: .about
        }
    }
}

/// A page of the settings window.
///
/// Nine sections in one scroll was the complaint, and nine tabs would be the
/// same pile stood on its side. These group by the question the user came to
/// answer rather than by the layer of code the setting belongs to — which is why
/// the turn-segmentation thresholds sit under `sound` and not on a page of their
/// own: they are reached for together with the capture backend, when the
/// complaint is «собеседника не слышно».
enum SettingsTab: String, CaseIterable, Sendable, Identifiable {
    case profile
    case sound
    case recognition
    case model
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: String(localized: "Профиль")
        case .sound: String(localized: "Звук")
        case .recognition: String(localized: "Распознавание")
        case .model: String(localized: "Модель")
        case .about: String(localized: "О программе")
        }
    }

    var symbol: String {
        switch self {
        case .profile: "person.crop.rectangle"
        case .sound: "waveform"
        case .recognition: "text.bubble"
        case .model: "sparkles"
        case .about: "info.circle"
        }
    }
}

/// Opening the settings window, optionally at a section.
///
/// `nil` means "just open it": the gear in the overlay header is a way in, not a
/// way to a particular control.
typealias OpenSettings = (SettingsSection?) -> Void

/// Which section the settings screen has been asked to show.
///
/// A request rather than a value, because the same section can be asked for
/// twice in a row — press the provider field, scroll away, press it again — and
/// a plain `SettingsSection?` would look unchanged the second time and scroll
/// nowhere. The token is what makes the second press a new request.
@Observable
final class SettingsNavigation {

    struct Request: Equatable, Sendable {
        let section: SettingsSection
        /// Increments with every request; see the type's note.
        let token: Int
    }

    private(set) var request: Request?

    private var issued = 0

    func reveal(_ section: SettingsSection) {
        issued += 1
        request = Request(section: section, token: issued)
    }
}
