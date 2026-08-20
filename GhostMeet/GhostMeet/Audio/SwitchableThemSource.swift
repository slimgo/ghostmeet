//
//  SwitchableThemSource.swift
//  GhostMeet
//

import Foundation
import Observation

/// The `Them` channel as one source, whichever backend is behind it right now.
///
/// `SessionEngine` takes its sources once, at construction, and must not learn
/// that there are two ways to capture `Them` (ADR-0001). Yet the choice between
/// them is a setting, and a setting that needs the app restarted to take effect
/// is a setting the user will get wrong once and never touch again — the two
/// backends fail on different machines, and finding out which one works here is
/// exactly what the picker is for.
///
/// So the swap happens below the engine: this type is the source the engine
/// holds forever, and the real backend behind it is replaced in place. Capture
/// stops on the old one and starts on the new one with the same frame handler,
/// the same chosen application and the same status stream, so nothing above
/// notices anything except that the channel went quiet for an instant.
nonisolated final class SwitchableThemSource: ThemAudioSource, @unchecked Sendable {

    let channel: Channel = .them

    /// Called whenever the status changes, on an arbitrary thread. Statuses of
    /// whichever backend is current arrive here unchanged.
    var onStatusChange: (@Sendable (ThemCaptureStatus) -> Void)?

    /// Builds a backend. Injected so a test can swap in something that neither
    /// touches Core Audio nor asks for Screen Recording.
    private let make: @Sendable (ThemCaptureBackend) -> any ThemAudioSource
    private let lock = NSLock()

    private var _backend: ThemCaptureBackend
    private var _source: any ThemAudioSource
    private var _sourceApplicationID: String?
    private var _isRunning = false
    private var _lastPublished: ThemCaptureStatus = .idle
    /// Whether the current backend was picked by hand and has yet to work once.
    ///
    /// While that holds, the fallback does **not** fire: the user has just made a
    /// choice, and a failure of their choice is theirs to see. Quietly putting
    /// them back on the previous backend argues with them without saying so, and
    /// they conclude the switch is broken.
    private var _awaitingManualChoice = false

    /// Whether the emergency move to the other backend has already happened.
    ///
    /// Exactly once per run. A second `failed` in a row means the backend is not
    /// the problem — the microphone is taken, the source application is the wrong
    /// one, permission is missing everywhere — and flapping between two dead
    /// captures is noise where a diagnosis is wanted.
    private var _didFallBack = false
    private var onFrame: AudioFrameHandler?

    init(
        backend: ThemCaptureBackend = .default,
        sourceApplicationID: String? = nil,
        make: @escaping @Sendable (ThemCaptureBackend) -> any ThemAudioSource = SwitchableThemSource.backend
    ) {
        self.make = make
        self._backend = backend
        self._sourceApplicationID = sourceApplicationID
        self._source = make(backend)
        _source.sourceApplicationID = sourceApplicationID
        _source.onStatusChange = { [weak self] status in self?.publish(status) }
    }

    deinit { _source.stop() }

    /// The real thing: the two backends of ADR-0001.
    static let backend: @Sendable (ThemCaptureBackend) -> any ThemAudioSource = { backend in
        switch backend {
        case .processTap: ProcessTapCaptureService()
        case .screenCaptureKit: SCKCaptureService()
        }
    }

    // MARK: - State

    /// Which backend is feeding the channel. Setting it while listening tears
    /// the old one down and brings the new one up — no restart of the session,
    /// let alone of the app.
    var backend: ThemCaptureBackend {
        get {
            lock.lock(); defer { lock.unlock() }
            return _backend
        }
        set { swap(to: newValue) }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    /// The status of the backend that is current at this instant.
    var status: ThemCaptureStatus {
        lock.lock()
        let source = _source
        lock.unlock()
        return source.status
    }

    var sourceApplicationID: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _sourceApplicationID
        }
        set {
            lock.lock()
            _sourceApplicationID = newValue
            let source = _source
            lock.unlock()
            source.sourceApplicationID = newValue
        }
    }

    // MARK: - AudioSource

    func start(onFrame: @escaping AudioFrameHandler) throws {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        _isRunning = true
        self.onFrame = onFrame
        let source = _source
        lock.unlock()

        do {
            try source.start(onFrame: onFrame)
        } catch {
            lock.lock()
            _isRunning = false
            self.onFrame = nil
            lock.unlock()
            throw error
        }
    }

    func stop() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        onFrame = nil
        let source = _source
        lock.unlock()

        source.stop()
    }

    // MARK: - Swapping the backend

    /// Replaces the backend, carrying the session across.
    ///
    /// The old one is unsubscribed *before* it is stopped: its parting `.idle`
    /// would otherwise arrive after the new backend has already said what it is
    /// doing, and the window would show the wrong thing until the next status
    /// change — which, on a machine where the new backend cannot start at all,
    /// is never.
    private func swap(to backend: ThemCaptureBackend, isFallback: Bool = false) {
        lock.lock()
        guard backend != _backend else { lock.unlock(); return }
        _backend = backend
        if isFallback { _didFallBack = true } else { _awaitingManualChoice = true }
        let previous = _source
        let handler = onFrame
        let running = _isRunning
        let id = _sourceApplicationID
        let next = make(backend)
        _source = next
        lock.unlock()

        previous.onStatusChange = nil
        previous.stop()

        next.sourceApplicationID = id
        next.onStatusChange = { [weak self] status in self?.publish(status) }

        guard running, let handler else {
            publish(.idle)
            return
        }

        do {
            try next.start(onFrame: handler)
        } catch {
            // Capture failures of the `Them` channel never throw upward: the
            // session has a working microphone and must keep running. The reason
            // travels as a status, which the window shows and a system banner
            // never does (ADR-0004).
            publish(.failed(reason: error.localizedDescription))
        }
    }

    private func publish(_ status: ThemCaptureStatus) {
        lock.lock()
        let changed = _lastPublished != status
        _lastPublished = status
        let handler = onStatusChange
        // The fallback is decided here and nowhere else: this is the only place
        // "it broke and will not fix itself" arrives, and the only one that knows
        // about both backends at once (ADR-0001 — nothing above may know).
        // A successful capture clears "picked by hand": the user's choice has
        // happened, so a later failure is about a breakage rather than about
        // their decision.
        if case .capturing = status { _awaitingManualChoice = false }
        let shouldFallBack = status.isFailure && !_didFallBack && !_awaitingManualChoice && _isRunning
        let from = _backend
        lock.unlock()

        if shouldFallBack {
            fallBack(from: from, because: status)
            return
        }
        if changed { handler?(status) }
    }

    /// Moves the channel to the other backend because this one declared itself dead.
    ///
    /// **Leaves the stored setting alone.** The choice of backend belongs to the
    /// user and this is an emergency measure for one run: a setting rewritten in
    /// silence would leave somebody on a backend they never chose, with no account
    /// of where it came from. On the next launch the app tries their choice again —
    /// the permission may have appeared since.
    ///
    /// **Staying quiet here is not allowed.** The backends have different blind
    /// spots: SCK sees only applications with windows, the tap sees any process
    /// making sound but arrives quieter. Somebody switched over in silence will
    /// look for the cause in the wrong place.
    private func fallBack(from failed: ThemCaptureBackend, because status: ThemCaptureStatus) {
        let next = failed.other
        onStatusChange?(.switchingBackend(from: failed, to: next, reason: status.message))
        swap(to: next, isFallback: true)
    }
}

@MainActor
extension SwitchableThemSource {

    /// Keeps the backend equal to what the settings screen shows.
    ///
    /// The same mechanism as `followSourceSelection(of:)` and
    /// `SessionController.followThresholds(of:)`: the store is observable, so
    /// re-reading it after every change is the whole thing — no notification, no
    /// restart of the session, no Apply button.
    func followCaptureBackend(of settings: SettingsStore) {
        withObservationTracking {
            backend = settings.themCaptureBackend
        } onChange: { [weak self] in
            // `onChange` fires *before* the new value is stored, so re-reading
            // has to wait for the next turn of the main actor.
            Task { @MainActor [weak self] in
                self?.followCaptureBackend(of: settings)
            }
        }
    }
}
