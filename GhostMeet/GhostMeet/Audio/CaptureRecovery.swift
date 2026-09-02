//
//  CaptureRecovery.swift
//  GhostMeet
//

@preconcurrency import AVFoundation
import Foundation

/// What microphone capture is doing, in words meant for the user.
///
/// Mirrors `ThemCaptureStatus` on purpose: the two channels fail differently but
/// are reported the same way — inside the window, never as a system banner,
/// which would be drawn over the shared screen (ADR-0004).
nonisolated enum MicCaptureStatus: Equatable, Sendable {
    /// Not listening.
    case idle
    /// Frames are arriving.
    case capturing
    /// Somebody else changed the input device under us and capture is being
    /// brought back. `attempt` counts from 1.
    case restarting(attempt: Int)
    /// Capture is not coming back on its own.
    case lost(reason: String)

    var message: String {
        switch self {
        case .idle:
            String(localized: "Микрофон не слушает.")
        case .capturing:
            String(localized: "Микрофон слушает — ваша речь пишется в канал You.")
        case .restarting(let attempt):
            String(localized: "Звуковое устройство сменилось — восстанавливаю микрофон (попытка \(attempt)).")
        case .lost(let reason):
            reason
        }
    }

    /// Whether the user has to be told about this and act on it.
    var isFailure: Bool {
        if case .lost = self { return true }
        return false
    }
}

/// Brings capture back after somebody else has changed the input device.
///
/// This is not a nicety, it is the price of ADR-0009. While we were the ones
/// switching the device into voice-processing mode, nothing could surprise us;
/// now Phone, WhatsApp, Teams — anything that turns on voice processing of its
/// own — flips the mode of the built-in microphone under us. Measured on the
/// bench: a consumer without this subscription gets **zero frames** from that
/// moment on and does not come back even after the culprit quits. The same
/// failure is on record in somebody else's tracker on the very machine this app
/// targets (Muesli issue #381, MacBook Air M5).
///
/// It knows nothing about `AVAudioEngine` beyond the name of the notification:
/// it is handed «try to bring capture back» and «say what is happening», which
/// is what makes the retry rule checkable without a microphone.
nonisolated final class CaptureRecovery: @unchecked Sendable {

    /// Runs a block after a delay. Injected so the retry rule can be tested
    /// without waiting out the delays in real time.
    typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// How long to wait before each attempt; the count is how many attempts
    /// capture gets.
    ///
    /// The first delay is not zero, and that is the important one: at the
    /// instant the notification arrives the device is still mid-switch, and an
    /// immediate restart fails on a device that is about to be perfectly fine.
    /// The later ones grow so that a device genuinely on its way back — a
    /// headset finishing its handshake — still fits inside the budget, while a
    /// device that has gone for good is declared lost rather than retried for
    /// the rest of the call.
    ///
    /// **The budget was ~2 s and that was too short**, chosen by reasoning where
    /// the rest of this work was measured. Plugging in a Bluetooth headset makes
    /// macOS renegotiate the profile before the microphone exists at all, and the
    /// user hit exactly that: the app stopped hearing them. Six seconds is the
    /// same shape of guess, but on the safe side of it — the cost of waiting too
    /// long is a few seconds of a silent `You` channel with the reason on screen,
    /// while the cost of giving up too early is a microphone declared dead while
    /// the session still calls itself live.
    static let defaultDelays: [TimeInterval] = [0.15, 0.4, 1.0, 2.0, 2.5]

    /// What a device that never came back is called in the window.
    ///
    /// The distinction between «микрофон переключился» and «микрофон отвалился»
    /// is not readable from any error code — a device mid-switch and a device
    /// unplugged fail identically. So it is decided by behaviour instead: what
    /// survives the whole retry budget is a switch, what does not is a loss.
    static let lostMessage = String(localized: """
        Микрофон замолчал после того, как звуковое устройство сменилось, и не вернулся. \
        Обычно это делает другое приложение, включившее у себя обработку голоса. \
        Выключите и включите «Слушать» — или проверьте устройство ввода в «Системных настройках» → «Звук».
        """)

    private let delays: [TimeInterval]
    private let schedule: Scheduler
    private let restart: @Sendable () throws -> Void
    private let report: @Sendable (MicCaptureStatus) -> Void

    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    /// Bumped by every `stopWatching()` and by every fresh recovery, so a retry
    /// scheduled by an older one finds itself stale and does nothing.
    private var generation = 0
    private var isRecovering = false
    /// Until when our own configuration changes are ignored.
    private var suppressedUntil: TimeInterval = 0

    init(
        delays: [TimeInterval] = CaptureRecovery.defaultDelays,
        schedule: @escaping Scheduler = CaptureRecovery.afterDelay,
        restart: @escaping @Sendable () throws -> Void,
        report: @escaping @Sendable (MicCaptureStatus) -> Void
    ) {
        self.delays = delays.isEmpty ? CaptureRecovery.defaultDelays : delays
        self.schedule = schedule
        self.restart = restart
        self.report = report
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Default scheduler: a background queue, because a restart takes a device
    /// round trip and the main actor is drawing the overlay.
    static let afterDelay: Scheduler = { delay, work in
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { work() }
    }

    /// Starts listening for configuration changes of one engine.
    func watch(_ engine: AnyObject, on center: NotificationCenter = .default) {
        stopWatching(on: center)
        let observer = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.configurationChanged()
        }
        lock.lock()
        self.observer = observer
        lock.unlock()
    }

    func stopWatching(on center: NotificationCenter = .default) {
        lock.lock()
        let observer = self.observer
        self.observer = nil
        generation += 1
        isRecovering = false
        lock.unlock()
        if let observer { center.removeObserver(observer) }
    }

    /// Ignores configuration changes for a moment, because we caused them.
    ///
    /// **Binding the input node to a chosen device is itself a configuration
    /// change** — measured: exactly one `AVAudioEngineConfigurationChange` per
    /// bind. It arrives after the restart has finished and cleared `isRecovering`,
    /// so the restart announced itself, the announcement started another
    /// recovery, and that one announced itself in turn. The loop closed the open
    /// `Реплика` through `sourceInterrupted` on every lap, which reached the
    /// transcript as a stream of 0.08-second turns with no words in them.
    ///
    /// A window rather than a counter: a missed notification here is at worst one
    /// delayed recovery — a real device switch keeps producing them — while a
    /// stuck counter would deafen the channel for the rest of the call.
    func suppressChanges(for interval: TimeInterval = 1) {
        lock.lock()
        suppressedUntil = Date().timeIntervalSinceReferenceDate + interval
        lock.unlock()
    }

    /// Takes one configuration change.
    ///
    /// A single switch of the input device produces a burst of these; only the
    /// first one starts a recovery, or three notifications would become three
    /// competing restarts of the same engine.
    func configurationChanged() {
        lock.lock()
        guard Date().timeIntervalSinceReferenceDate >= suppressedUntil else {
            lock.unlock()
            return
        }
        guard !isRecovering else { lock.unlock(); return }
        isRecovering = true
        generation += 1
        let generation = self.generation
        lock.unlock()

        attempt(1, generation: generation)
    }

    private func attempt(_ number: Int, generation: Int) {
        guard isCurrent(generation) else { return }
        report(.restarting(attempt: number))
        let delay = delays[min(number - 1, delays.count - 1)]
        schedule(delay) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            do {
                try self.restart()
                self.finish(generation)
                self.report(.capturing)
            } catch {
                if number < self.delays.count {
                    self.attempt(number + 1, generation: generation)
                } else {
                    self.finish(generation)
                    self.report(.lost(reason: Self.lostMessage))
                }
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && isRecovering
    }

    private func finish(_ generation: Int) {
        lock.lock()
        if self.generation == generation { isRecovering = false }
        lock.unlock()
    }
}
