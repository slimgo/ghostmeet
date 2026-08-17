//
//  SpeechModelPhase.swift
//  GhostMeet
//

import Foundation

/// What is happening with the recognition model right now.
///
/// The first use of a model pulls hundreds of megabytes over the network, so
/// "not ready yet" is a normal, long-lived state and not an error. It is
/// reported as its own phase so the interface can say *why* turns have no text
/// instead of showing an empty window.
///
/// Failures are surfaced through this type and shown inside the app window
/// only — a system notification banner would appear on top of a shared screen
/// and give GhostMeet away (ADR-0004).
nonisolated enum SpeechModelPhase: Equatable, Sendable {
    /// Nothing has been asked of the model yet.
    case idle
    /// Model files are coming over the network. `fraction` is `0...1`.
    case downloading(fraction: Double)
    /// Files are on disk and are being loaded into memory and specialised.
    case loading
    /// Recognition works.
    case ready
    /// The model could not be prepared. Carries a message for the window.
    case failed(String)

    /// Whether the model is on its way but not usable yet.
    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .idle, .ready, .failed: return false
        }
    }

    /// Whether turns handed over right now would get text.
    var isReady: Bool { self == .ready }

    /// Why listening cannot start yet, in words meant for the overlay.
    ///
    /// `nil` exactly when listening may start, so this doubles as the gate the
    /// window reads: the button is enabled iff this is `nil`.
    ///
    /// Deliberately a different text from `summary`. The settings screen states
    /// a fact about the model; the overlay has to answer the question the user
    /// is actually asking there — "why can't I press this?" — because a
    /// disabled button with no explanation reads as a broken app.
    var listeningBlockedReason: String? {
        switch self {
        case .idle:
            return String(localized: "Модель распознавания ещё не готова — подготовка вот-вот начнётся.")
        case .downloading(let fraction):
            return String(localized: "Скачивание модели — \(Self.percent(fraction))%. Прослушивание включится, когда она будет готова.")
        case .loading:
            return String(localized: "Модель загружается в память — несколько секунд.")
        case .ready:
            return nil
        case .failed(let reason):
            return String(localized: "Модель не загрузилась: \(reason). Прослушивание недоступно — загрузите модель заново в настройках.")
        }
    }

    /// One line for the settings screen, in the user's language.
    var summary: String {
        switch self {
        case .idle:
            return String(localized: "Модель ещё не загружена")
        case .downloading(let fraction):
            return String(localized: "Скачивание модели — \(Self.percent(fraction))%")
        case .loading:
            return String(localized: "Подготовка модели")
        case .ready:
            return String(localized: "Модель готова")
        case .failed(let reason):
            return String(localized: "Модель не загрузилась: \(reason)")
        }
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}
