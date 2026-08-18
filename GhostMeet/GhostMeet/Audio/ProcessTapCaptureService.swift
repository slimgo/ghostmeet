//
//  ProcessTapCaptureService.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: buffers travel from the
// realtime IO thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Observation

/// What the `Them` capture is doing, in words meant for the user.
///
/// Surfaced inside the app's own windows and nowhere else: a system notification
/// banner would be drawn on top of whatever the user is sharing and hand the app
/// over (ADR-0004).
nonisolated enum ThemCaptureStatus: Equatable, Sendable {
    /// No source application has been chosen yet.
    case idle
    /// Audio of the named application is arriving.
    case capturing(application: String)
    /// The application was chosen but is not running — quit, restarted, or not
    /// started yet. Capture resumes on its own as soon as it comes back.
    case waitingForSource(application: String)
    /// The stream broke under us and is being brought back. `attempt` counts
    /// from 1. Mirrors `MicCaptureStatus.restarting`: the two channels break
    /// differently and are reported the same way.
    case restarting(attempt: Int)
    /// Capture broke and will not recover by itself.
    case failed(reason: String)

    var message: String {
        switch self {
        case .idle:
            String(localized: "Приложение-источник не выбрано — канал Them молчит.")
        case .capturing(let application):
            String(localized: "Слушаем «\(application)».")
        case .waitingForSource(let application):
            String(localized: "«\(application)» сейчас не выдаёт звук. Захват включится сам, как только приложение вернётся.")
        case .restarting(let attempt):
            String(localized: "Звук собеседника оборвался — восстанавливаю канал Them (попытка \(attempt)).")
        case .failed(let reason):
            reason
        }
    }

    /// Whether the user has to be told about this and act on it.
    ///
    /// Same question `MicCaptureStatus.isFailure` answers, and the answer here
    /// costs more: a microphone that stopped means «меня не слышно» and gives
    /// itself away in seconds, while a `Them` that stopped means a transcript
    /// that goes on looking right while recording the interviewer's words as the
    /// user's own.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The `Them` channel: sound of the source application, taken with a Core Audio
/// process tap.
///
/// `SessionEngine` sees this through `AudioSource` and learns nothing about taps
/// or aggregate devices (ADR-0001). No longer the default — ScreenCaptureKit is
/// (ADR-0006), because it delivers a signal 1.5–2.5 times louder. This one stays
/// as the second backend for what `SCStream` cannot reach at all: a process that
/// makes sound and owns no window.
///
/// The source application is held by a **stable id**, never by a process: a
/// browser plays its sound from a helper process whose PID and Core Audio object
/// change every time the browser is restarted. The service re-resolves that id
/// whenever the process list moves, which is what turns a restart of the source
/// application from a dead channel into a pause.
nonisolated final class ProcessTapCaptureService: ThemAudioSource, @unchecked Sendable {

    let channel: Channel = .them

    /// Called whenever the status changes, on an arbitrary thread.
    var onStatusChange: (@Sendable (ThemCaptureStatus) -> Void)?

    private let lister: AudioProcessLister
    private let tap = ProcessTap()
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.ghostmeet.process-tap.changes")

    private var _isRunning = false
    private var _status: ThemCaptureStatus = .idle
    private var _sourceApplicationID: String?
    private var onFrame: AudioFrameHandler?
    private var converter: AVAudioConverter?
    private var lastKnownName: String?
    private var listener: AudioObjectPropertyListenerBlock?

    /// - Parameters:
    ///   - sourceApplicationID: stable id of the chosen application, or `nil`
    ///     while the user has not chosen one.
    ///   - sampleRate: rate the frames are delivered at. The same 16 kHz mono the
    ///     microphone produces, so that recognition sees one shape of audio and
    ///     not two.
    init(
        sourceApplicationID: String? = nil,
        lister: AudioProcessLister = CoreAudioProcessLister(),
        sampleRate: Double = 16_000
    ) {
        self._sourceApplicationID = sourceApplicationID
        self.lister = lister
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    deinit { tap.stop() }

    // MARK: - State

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    /// What capture is doing right now, for the window to show.
    var status: ThemCaptureStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    /// Which application feeds `Them`. Setting it while listening re-points the
    /// tap without restarting the session — the user picks the browser after the
    /// overlay is already up.
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
            detachTap()
            attachTap()
        }
    }

    // MARK: - AudioSource

    /// Starts listening to the chosen application.
    ///
    /// Deliberately does not throw for the two ordinary cases — nothing chosen
    /// yet, and the chosen application not running. `Them` is one of two
    /// channels, and a session with a working microphone must not refuse to
    /// start because the browser is closed. Both land in `status` instead.
    func start(onFrame: @escaping AudioFrameHandler) throws {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        self.onFrame = onFrame
        _isRunning = true
        lock.unlock()

        startObservingProcessList()
        attachTap()
    }

    func stop() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        onFrame = nil
        lock.unlock()

        stopObservingProcessList()
        detachTap()
        publish(.idle)
    }

    // MARK: - Tap lifecycle

    /// Resolves the chosen id to the processes that exist *right now* and builds
    /// the tap over all of them at once.
    private func attachTap() {
        guard let id = sourceApplicationID else {
            publish(.idle)
            return
        }
        guard let application = lister.resolveSourceApplication(id: id) else {
            // The application is gone. Its name is remembered from the last time
            // the id resolved, so the message stays about the thing the user
            // picked rather than about a bundle identifier.
            lock.lock()
            let name = lastKnownName ?? id
            lock.unlock()
            publish(.waitingForSource(application: name))
            return
        }

        lock.lock()
        lastKnownName = application.name
        let handler = onFrame
        lock.unlock()

        do {
            try tap.start(processObjectIDs: application.processObjectIDs) { [weak self] buffer in
                guard let self, let handler, let frame = self.makeFrame(from: buffer) else { return }
                handler(frame)
            }
            publish(.capturing(application: application.name))
        } catch ProcessTap.TapError.noProcesses {
            publish(.waitingForSource(application: application.name))
        } catch {
            publish(.failed(reason: error.localizedDescription))
        }
    }

    private func detachTap() {
        tap.stop()
        lock.lock()
        converter = nil
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

    /// The process list changes whenever anything starts or stops using audio.
    /// That is the signal that the source application was quit, restarted, or
    /// simply woke its audio helper up for the first time.
    private func startObservingProcessList() {
        let block = CoreAudioProcessLister.observeProcessList(on: listenerQueue) { [weak self] in
            self?.processListChanged()
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

    private func processListChanged() {
        guard isRunning, let id = sourceApplicationID else { return }

        guard let resolved = lister.resolveSourceApplication(id: id) else {
            guard tap.isRunning else { return }
            detachTap()
            lock.lock()
            let name = lastKnownName ?? id
            lock.unlock()
            publish(.waitingForSource(application: name))
            return
        }

        // Rebuilding only pays off when the set of processes actually moved: a
        // restarted application comes back under new Core Audio objects, and a
        // tap over the old ones would stay silent for the rest of the call.
        guard resolved.processObjectIDs != tap.tappedProcessObjectIDs else { return }
        detachTap()
        attachTap()
    }

    // MARK: - Format

    /// Downmixes and resamples one tapped buffer into a `Them` frame.
    ///
    /// The tap reports whatever the source application runs at — 48 kHz stereo
    /// as a rule — while recognition wants 16 kHz mono. The conversion lives
    /// here so the choice of rate stays a property of capture and never leaks
    /// into `Speech`.
    private func makeFrame(from buffer: AVAudioPCMBuffer) -> AudioFrame? {
        guard buffer.frameLength > 0 else { return nil }

        lock.lock()
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
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

