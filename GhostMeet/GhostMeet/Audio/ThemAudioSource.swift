//
//  ThemAudioSource.swift
//  GhostMeet
//

import Foundation
import Observation

/// Which backend feeds the `Them` channel.
///
/// Two, deliberately (ADR-0001), and the choice is not cosmetic: measured on one
/// and the same recording, ScreenCaptureKit delivers a signal **1.5–2.5 times
/// louder** than the tap (peak RMS 0.095–0.127 against 0.051–0.081). The cause
/// is the microphone's echo cancellation, which ducks system audio while it
/// runs and hits the tap harder than it hits `SCStream`. Loudness is what
/// recognition quality hangs on, so the louder backend is the default and the
/// quieter one is what remains when Screen Recording is out of the question.
nonisolated enum ThemCaptureBackend: String, Codable, CaseIterable, Sendable {
    /// `SCStream` with `capturesAudio`, filtered to the source application.
    /// The default — louder signal, at the price of a permission and of only
    /// seeing applications that own a window.
    case screenCaptureKit
    /// Core Audio process tap over an aggregate device. Reaches any process that
    /// opened an output device and needs no Screen Recording grant.
    case processTap

    /// What ships when nothing has been chosen and when a stored value makes no
    /// sense any more.
    static let `default`: ThemCaptureBackend = .screenCaptureKit

    var displayName: String {
        switch self {
        case .processTap: "Core Audio Process Tap"
        case .screenCaptureKit: "ScreenCaptureKit"
        }
    }

    /// What the choice actually costs, in measurements rather than in adjectives.
    ///
    /// Shown next to the picker: both backends work, they fail differently, and
    /// the user is the only one who knows whether Screen Recording is available
    /// on this machine.
    var summary: String {
        switch self {
        case .screenCaptureKit:
            String(localized: "Сигнал громче в 1.5–2.5 раза, чем у тапа, — распознавание заметно лучше. Требует разрешения на запись экрана. Видит только приложения с окнами.")
        case .processTap:
            String(localized: "Видит любой процесс со звуком, даже без окна, и не требует записи экрана. Сигнал тише: эхоподавление микрофона пригибает громкость системы, и по тапу это бьёт сильнее.")
        }
    }

    /// Whether the backend simply does not start without the Screen Recording
    /// grant. The tap does not need it; `SCStream` does, and it is the default.
    var requiresScreenRecording: Bool {
        switch self {
        case .screenCaptureKit: true
        case .processTap: false
        }
    }

    /// The other one. There are two, and the fallback needs to name the one it
    /// is not on — see `SwitchableThemSource`.
    var other: ThemCaptureBackend {
        switch self {
        case .screenCaptureKit: .processTap
        case .processTap: .screenCaptureKit
        }
    }

    /// What a machine without the Screen Recording grant has to be told.
    ///
    /// One text, used both by the capture status the window shows and by the
    /// settings screen, because it is one situation: the default backend cannot
    /// run at all, and there are exactly two ways out of it. Never a system
    /// notification — a banner would be drawn over the shared screen (ADR-0004).
    static let screenRecordingHelp = String(localized: """
        Нет разрешения на запись экрана: ScreenCaptureKit не увидит ни одного приложения, и канал Them будет молчать. \
        Откройте «Системные настройки» → «Конфиденциальность и безопасность» → «Запись экрана и звука системы», \
        включите GhostMeet и перезапустите приложение — либо переключитесь на Core Audio Process Tap, ему это разрешение не нужно.
        """)
}

/// The `Them` channel as everything above capture sees it, whichever backend is
/// providing it.
///
/// `AudioSource` is all `SessionEngine` needs; this adds the two things that are
/// specific to `Them` and are consumed one level up, by the controller and the
/// overlay: which application is being listened to, and what capture is doing
/// about it right now.
nonisolated protocol ThemAudioSource: AudioSource {
    /// What capture is doing, in words meant for the user.
    var status: ThemCaptureStatus { get }
    /// Called whenever the status changes, on an arbitrary thread.
    var onStatusChange: (@Sendable (ThemCaptureStatus) -> Void)? { get set }
    /// Which application feeds `Them`. Setting it while listening re-points
    /// capture without restarting the session — the user picks the browser
    /// after the overlay is already up.
    var sourceApplicationID: String? { get set }
}

@MainActor
extension ThemAudioSource {

    /// Keeps the captured application equal to what the settings screen shows.
    ///
    /// The same mechanism `SessionController` uses for the segmentation
    /// thresholds: the store is observable, so re-reading it after every change
    /// is the whole thing — no notification, no restart of the session, no Apply
    /// button. Picking a browser mid-call re-points capture on the spot.
    func followSourceSelection(of settings: SettingsStore) {
        withObservationTracking {
            sourceApplicationID = settings.themSourceApplicationID
        } onChange: { [weak self] in
            // `onChange` fires *before* the new value is stored, so re-reading
            // has to wait for the next turn of the main actor.
            Task { @MainActor [weak self] in
                self?.followSourceSelection(of: settings)
            }
        }
    }
}
