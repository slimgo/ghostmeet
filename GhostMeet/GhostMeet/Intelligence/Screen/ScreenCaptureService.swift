//
//  ScreenCaptureService.swift
//  GhostMeet
//

import AppKit
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

/// One frame of the display, plus the words on it.
///
/// ScreenCaptureKit rather than `CGWindowListCreateImage`: the latter is
/// deprecated on this deployment target, and only `SCContentFilter` is honest
/// about what it is showing.
///
/// **The overlay is not in the picture.** Not because this filter excludes it —
/// it does not name a single window — but because the panel carries
/// `sharingType = .none`, which takes it out of every capture the window server
/// serves (`OverlayWindowConfiguration.overlay`, ADR-0004). That is the
/// whole mechanism, and it is load-bearing: were the overlay in the frame, every
/// suggestion would show the model its own previous answer and the loop would
/// start answering itself. `ScreenCaptureTests.overlayStaysOutOfTheScreenshot`
/// is the check that this still holds.
nonisolated final class ScreenCaptureService: ScreenCapturer {

    /// Timing of the capture, and nothing that was on the screen.
    ///
    /// The one number this ticket has to defend is latency: the screenshot rides
    /// in front of the first token of every suggestion, so how long it takes has
    /// to be measurable on a real machine rather than argued about. Nothing that
    /// was read off the screen is ever written here.
    private static let log = Logger(subsystem: "Mixxy.GhostMeet", category: "screen")

    /// Which display is grabbed.
    private let displayID: CGDirectDisplayID?

    /// - Parameter displayID: the display to capture. `nil` means the main one —
    ///   the one with the menu bar, which is where a shared window sits unless
    ///   the user deliberately moved it.
    init(displayID: CGDirectDisplayID? = nil) {
        self.displayID = displayID
    }

    func capture() async -> ScreenContext {
        let startedAt = ContinuousClock.now

        // The turn this capture belongs to was superseded before the frame was
        // even asked for.
        guard !Task.isCancelled else { return .none }

        let frame: CGImage
        do {
            frame = try await grab()
        } catch {
            let reason = Self.reason(for: error)
            Self.log.error("СНИМОК ЭКРАНА НЕ СДЕЛАН причина=\(reason, privacy: .public)")  // не переводится: журнал
            return .failed(reason)
        }

        let captured = ContinuousClock.now

        // The user pressed again while the frame was being taken, so what is left
        // of this capture is its expensive half — text recognition over a
        // full-resolution screen — spent on an answer nobody is waiting for any
        // more (ADR-0008). Dropped rather than reported: a superseded capture is
        // not a failure the user has anything to do about.
        guard !Task.isCancelled else {
            Self.log.notice(
                "СНИМОК ЭКРАНА ОТМЕНЁН снимок_мс=\(Self.milliseconds(startedAt, captured), privacy: .public)"  // не переводится: журнал
            )
            return .none
        }

        // Text first, from the full-resolution frame: it is the half that has to
        // be exact, and shrinking the picture is what would blur it.
        let text = await Self.recognizeText(in: frame)
        let recognised = ContinuousClock.now

        let png = ScreenImage.png(from: frame)
        let encoded = ContinuousClock.now

        Self.log.notice(
            """
            СНИМОК ЭКРАНА пиксели=\(frame.width, privacy: .public)x\(frame.height, privacy: .public) \
            снимок_мс=\(Self.milliseconds(startedAt, captured), privacy: .public) \
            ocr_мс=\(Self.milliseconds(captured, recognised), privacy: .public) \
            сжатие_мс=\(Self.milliseconds(recognised, encoded), privacy: .public) \
            итого_мс=\(Self.milliseconds(startedAt, encoded), privacy: .public) \
            кб=\(((png?.count ?? 0) + 512) / 1024, privacy: .public) \
            символов=\(text.count, privacy: .public)
            """
        )

        // An image that could not be encoded is not worth a message to the user:
        // the text still went, and there is nothing they could do about it.
        return ScreenContext(image: png, text: text)
    }

    // MARK: - Vision

    /// Vision's own queue.
    ///
    /// Recognition is the expensive half — hundreds of milliseconds on a full
    /// screen — and it is synchronous. Left on the cooperative pool it would
    /// block one of its few threads at exactly the moment speech recognition is
    /// running beside it, which is the one moment the app cannot afford to
    /// starve.
    private static let visionQueue = DispatchQueue(
        label: "com.ghostmeet.screen-ocr",
        qos: .userInitiated
    )

    private static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            visionQueue.async {
                continuation.resume(returning: ScreenTextRecognizer.text(in: image))
            }
        }
    }

    // MARK: - ScreenCaptureKit

    private func grab() async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.contentUnavailable(error)
        }

        guard let display = pickDisplay(from: content.displays) else {
            throw CaptureError.noDisplay
        }

        // Everything on the display, no window named either way. What keeps the
        // overlay out is its own `sharingType`, enforced by the window server —
        // see the note on the type.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        let scale = Self.pixelScale(of: display.displayID)
        configuration.width = Int(Double(display.width) * scale)
        configuration.height = Int(Double(display.height) * scale)
        configuration.captureResolution = .best
        // The pointer is not part of the question and only adds noise for OCR.
        configuration.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw CaptureError.screenshotFailed(error)
        }
    }

    private func pickDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        if let displayID, let match = displays.first(where: { $0.displayID == displayID }) {
            return match
        }
        let main = CGMainDisplayID()
        return displays.first { $0.displayID == main } ?? displays.first
    }

    /// Backing scale of the display, so the frame comes back at native
    /// resolution rather than in points.
    ///
    /// Retina detail is not for the model — the image is shrunk before it is
    /// sent — it is for Vision, which reads small text far better at 2×.
    private static func pixelScale(of displayID: CGDirectDisplayID) -> Double {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return Double(screen?.backingScaleFactor ?? 1)
    }

    // MARK: - Failures

    private enum CaptureError: Error {
        case contentUnavailable(any Error)
        case noDisplay
        case screenshotFailed(any Error)
    }

    /// The failure in words meant for the user, shown inside the overlay window
    /// and nowhere else (ADR-0004).
    private static func reason(for error: any Error) -> String {
        switch error {
        case CaptureError.contentUnavailable:
            return Self.permissionHelp
        case CaptureError.noDisplay:
            return String(localized: "Система не сообщила ни одного дисплея — подсказка идёт без снимка экрана.")
        case CaptureError.screenshotFailed(let underlying):
            return String(localized: "Не удалось снять экран: \(underlying.localizedDescription). Подсказка идёт без снимка.")
        default:
            return String(localized: "Не удалось снять экран: \(error.localizedDescription). Подсказка идёт без снимка.")
        }
    }

    /// Same situation as the `Them` channel's, different consequence: there the
    /// channel goes silent, here the suggestion merely goes blind. Worth its own
    /// sentence so the user is not sent hunting for a setting that is already on.
    static let permissionHelp = String(localized: """
        Нет разрешения на запись экрана — подсказка идёт без снимка. \
        Откройте «Системные настройки» → «Конфиденциальность и безопасность» → «Запись экрана и звука системы», \
        включите GhostMeet и перезапустите приложение.
        """)

    private static func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Int {
        let components = (to - from).components
        return Int(components.seconds) * 1_000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
