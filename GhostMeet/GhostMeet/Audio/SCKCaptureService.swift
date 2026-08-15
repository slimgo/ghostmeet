//
//  SCKCaptureService.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: buffers travel from the
// capture thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The `Them` channel taken with ScreenCaptureKit — the second capture backend
/// of ADR-0001.
///
/// It was built when the tap and microphone echo cancellation were believed to
/// be incompatible (ADR-0005); they are not (ADR-0007), and echo cancellation is
/// gone from the app altogether (ADR-0009). What kept this backend is a
/// measurement rather than that story: on one and the same recording `SCStream`
/// delivers 1.5–2.5× more signal than the tap, and loudness is what recognition
/// quality hangs on — which is why it is the default (ADR-0006).
///
/// Everything else matches `ProcessTapCaptureService` on purpose: the same
/// stable-id resolution, the same statuses, the same 16 kHz mono frames, so that
/// swapping one for the other changes nothing above the seam.
nonisolated final class SCKCaptureService: ThemAudioSource, @unchecked Sendable {

    let channel: Channel = .them

    /// Called whenever the status changes, on an arbitrary thread.
    var onStatusChange: (@Sendable (ThemCaptureStatus) -> Void)?

    private let stream: any ThemAudioStream
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.ghostmeet.sck.changes")

    private var _isRunning = false
    private var _status: ThemCaptureStatus = .idle
    private var _sourceApplicationID: String?
    private var onFrame: AudioFrameHandler?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var lastKnownName: String?
    private var attachTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var listener: AudioObjectPropertyListenerBlock?

    /// How long to wait before each attempt to bring the stream back.
    private let retryDelays: [TimeInterval]
    /// Injected so the retry rule can be checked without waiting it out.
    private let pause: @Sendable (TimeInterval) async -> Void

    /// - Parameters:
    ///   - sourceApplicationID: stable id of the chosen application, or `nil`
    ///     while the user has not chosen one.
    ///   - sampleRate: rate the frames are delivered at. The same 16 kHz mono the
    ///     microphone produces, so that recognition sees one shape of audio and
    ///     not two.
    init(
        sourceApplicationID: String? = nil,
        stream: any ThemAudioStream = SCKAudioStream(),
        sampleRate: Double = 16_000,
        retryDelays: [TimeInterval] = CaptureRecovery.defaultDelays,
        pause: @escaping @Sendable (TimeInterval) async -> Void = SCKCaptureService.sleep
    ) {
        self._sourceApplicationID = sourceApplicationID
        self.stream = stream
        self.retryDelays = retryDelays.isEmpty ? CaptureRecovery.defaultDelays : retryDelays
        self.pause = pause
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        stream.onFailure = { [weak self] error in
            self?.recover(from: error)
        }
    }

    /// Default pause between attempts.
    static let sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }

    deinit { stream.stop() }

    // MARK: - State

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var status: ThemCaptureStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    var sourceApplicationID: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _sourceApplicationID
        }
        set {
            lock.lock()
            let changed = _sourceApplicationID != newValue
            _sourceApplicationID = newValue
            if changed { lastKnownName = nil }
            let running = _isRunning
            lock.unlock()

            guard changed, running else { return }
            scheduleAttach()
        }
    }

    // MARK: - AudioSource

    /// Starts listening to the chosen application.
    ///
    /// Like the process-tap backend, it does not throw for the two ordinary
    /// cases — nothing chosen yet, and the chosen application not being on
    /// offer. A session with a working microphone must not refuse to start
    /// because the browser is closed; both land in `status` instead.
    func start(onFrame: @escaping AudioFrameHandler) throws {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        self.onFrame = onFrame
        _isRunning = true
        lock.unlock()

        startObservingProcessList()
        scheduleAttach()
    }

    func stop() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        onFrame = nil
        let task = attachTask
        let recovery = recoveryTask
        attachTask = nil
        recoveryTask = nil
        converter = nil
        sourceFormat = nil
        lock.unlock()

        task?.cancel()
        // A recovery in flight has to die with the session, not outlive it: the
        // user left the call, and a channel that comes back afterwards would
        // start recording a room nobody asked it to record.
        recovery?.cancel()
        stopObservingProcessList()
        stream.stop()
        publish(.idle)
    }

    /// Waits for a recovery in flight, if any. The seam that lets a test drive
    /// the whole «поток оборвался и вернулся» scenario without sleeping.
    func waitForRecovery() async {
        lock.lock()
        let task = recoveryTask
        lock.unlock()
        await task?.value
    }

    /// Waits for the attach that is already in flight.
    ///
    /// ScreenCaptureKit is asynchronous all the way down — resolving the content
    /// and starting the stream are both `await` — so whoever needs to know how it
    /// ended has to be able to wait for it instead of sleeping. Mirrors
    /// `SessionController.waitForStart()`.
    func waitForAttach() async {
        lock.lock()
        let task = attachTask
        lock.unlock()
        await task?.value
    }

    // MARK: - Stream lifecycle

    /// Attaches after whatever attach is already running has finished.
    ///
    /// Serialised rather than cancelled-and-restarted: the source can be
    /// re-pointed twice in a row while the first resolution is still in flight,
    /// and two `SCStream`s starting over each other leave one of them orphaned.
    private func scheduleAttach() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        let previous = attachTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.attachNow()
        }
        attachTask = task
        lock.unlock()
    }

    private func attachNow() async {
        lock.lock()
        let id = _sourceApplicationID
        let handler = onFrame
        let running = _isRunning
        lock.unlock()

        guard running, let handler else { return }
        stream.stop()

        guard let id, !id.isEmpty else {
            publish(.idle)
            return
        }

        do {
            let matching = try await stream.shareableApplications()
                .filter { $0.matches(sourceApplicationID: id) }

            guard !matching.isEmpty else {
                lock.lock()
                let remembered = lastKnownName ?? id
                lock.unlock()
                publish(.waitingForSource(application: remembered))
                return
            }

            let scope = SCKAudioScope.applications(Set(matching.map(\.processIdentifier)))
            // The application itself names the entry, not one of its helpers: the
            // user picked «Google Chrome», not «Google Chrome Helper (Renderer)».
            let name = matching.first { $0.bundleIdentifier == id }?.displayName
                ?? matching[0].displayName
            lock.lock()
            lastKnownName = name
            lock.unlock()

            try await stream.start(scope: scope) { [weak self] buffer in
                guard let self, let frame = self.makeFrame(from: buffer) else { return }
                handler(frame)
            }
            publish(.capturing(application: name))
        } catch {
            publish(.failed(reason: error.localizedDescription))
        }
    }

    // MARK: - Восстановление после обрыва

    /// What a channel that never came back is called in the window.
    ///
    /// Says what happened and what to press, and deliberately **not** what it
    /// costs: the consequence — the interviewer being recorded as the user — is
    /// added by `SessionIndicators` for every dead `Them` during a call, whatever
    /// killed it, so that it is stated once and cannot be forgotten in one of the
    /// places a failure is published.
    static let lostMessage = """
        Звук собеседника оборвался и не вернулся. \
        Выключите и включите «Слушать» или выберите источник заново.
        """

    /// Takes one broken stream and tries to get the channel back.
    ///
    /// **This is the event the service used to only report.** Two other reasons
    /// to re-attach were already handled — the user re-pointing the source, and
    /// the process list moving when the browser restarts — and a stream that
    /// simply broke was not one of them. Measured live on 15 August 2026: the
    /// stream died 1.1 seconds after it started, Chrome stayed alive, the process
    /// list never moved, and the channel was silent for the remaining 37 minutes
    /// while the interviewer's voice went into `You` through the speakers. See
    /// `.scratch/them-recovery/spec.md`.
    ///
    /// One recovery at a time: a burst of failures is one broken stream, not
    /// three, and three races would leave two orphaned `SCStream`s behind.
    private func recover(from error: Error) {
        lock.lock()
        guard _isRunning, recoveryTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.retryAttach(after: error)
        }
        recoveryTask = task
        lock.unlock()
    }

    /// The retry rule itself.
    ///
    /// The delays are `CaptureRecovery.defaultDelays` — the microphone's, and
    /// deliberately not a second set of numbers about the same thing. The
    /// **mechanics** could not be shared: `CaptureRecovery` restarts an
    /// `AVAudioEngine` synchronously and learns there and then whether it
    /// worked, while attaching an `SCStream` is asynchronous from end to end and
    /// reports through `status`. Sharing the numbers and not the machinery is the
    /// honest half of that; do not try to merge the rest.
    ///
    /// Anything other than `.failed` ends the attempts, `.waitingForSource`
    /// included: a source that is closed right now is a channel waiting, not a
    /// channel broken, and the process-list observer is what wakes it.
    private func retryAttach(after error: Error) async {
        defer { finishRecovery() }

        for (index, delay) in retryDelays.enumerated() {
            guard isRunning, !Task.isCancelled else { return }
            publish(.restarting(attempt: index + 1))

            await pause(delay)
            guard isRunning, !Task.isCancelled else { return }

            scheduleAttach()
            await waitForAttach()
            guard isRunning, !Task.isCancelled else { return }

            if case .failed = status {} else { return }
        }

        publish(.failed(reason: Self.lostMessage))
    }

    private func finishRecovery() {
        lock.lock()
        recoveryTask = nil
        lock.unlock()
    }

    private func publish(_ status: ThemCaptureStatus) {
        lock.lock()
        let changed = _status != status
        _status = status
        let handler = onStatusChange
        lock.unlock()
        if changed { handler?(status) }
    }

    // MARK: - Recovery from a restart of the source application

    /// ScreenCaptureKit has no "the applications changed" notification, but Core
    /// Audio's process list moves whenever anything starts or stops using audio,
    /// which is the same event from a different angle: the browser was quit,
    /// restarted, or has just woken its audio helper up.
    private func startObservingProcessList() {
        let block = CoreAudioProcessLister.observeProcessList(on: listenerQueue) { [weak self] in
            self?.scheduleAttach()
        }
        lock.lock()
        listener = block
        lock.unlock()
    }

    private func stopObservingProcessList() {
        lock.lock()
        let block = listener
        listener = nil
        lock.unlock()
        guard let block else { return }
        CoreAudioProcessLister.stopObservingProcessList(block, on: listenerQueue)
    }

    // MARK: - Format

    /// Downmixes and resamples one captured buffer into a `Them` frame.
    ///
    /// ScreenCaptureKit delivers 48 kHz stereo while recognition wants 16 kHz
    /// mono. The conversion lives here so the choice of rate stays a property of
    /// capture and never leaks into `Speech`.
    private func makeFrame(from buffer: AVAudioPCMBuffer) -> AudioFrame? {
        guard buffer.frameLength > 0 else { return nil }

        lock.lock()
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            sourceFormat = buffer.format
        }
        let converter = converter
        lock.unlock()
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var alreadyFed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if alreadyFed {
                status.pointee = .noDataNow
                return nil
            }
            alreadyFed = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channelData = output.floatChannelData?[0] else { return nil }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(output.frameLength)))
        return AudioFrame(channel: .them, samples: samples, sampleRate: targetFormat.sampleRate)
    }
}
