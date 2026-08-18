//
//  MicCaptureService.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: its buffers travel from the
// realtime capture thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import Foundation

/// Microphone capture: the source of the `You` channel.
///
/// **Voice processing (VPIO) is never switched on here** (ADR-0009). It used to
/// be the defence against channel leak — `Them` coming out of the speakers and
/// caught by the microphone — and it worked; the trouble is who pays for it.
/// `setVoiceProcessingEnabled(true)` switches the mode of the *device*, not of
/// our stream, and in that mode **every other process** on the machine gets the
/// built-in microphone 28–32 dB quieter. The browser holding the call is one of
/// those processes, and it does not use system VPIO, so the interviewer simply
/// stops hearing the candidate — a failure nobody in this app can see. The leak
/// is ours to clean up instead.
///
/// What the leak costs and how it is cleaned is in ADR-0009; nothing about it
/// lives in this type, which now just captures.
nonisolated final class MicCaptureService: AudioSource, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case inputFormatUnavailable
        case converterUnavailable
        /// The engine refused to start, with whatever Core Audio said.
        ///
        /// Wrapped rather than passed through, because what Core Audio says is a
        /// bare number: the user saw «10868» in the window and it told them
        /// nothing at all. The codes worth naming are the ones a person can do
        /// something about.
        case engineRefused(code: Int)

        var errorDescription: String? {
            switch self {
            case .inputFormatUnavailable:
                return String(localized: "Микрофон не сообщил формат записи — устройство ещё переключается")
            case .converterUnavailable:
                return String(localized: "Не удалось подготовить преобразование звука микрофона")
            case .engineRefused(let code):
                return Self.engineExplanation(code)
            }
        }

        /// What a refusal to start actually means, in words.
        static func engineExplanation(_ code: Int) -> String {
            switch code {
            case -10868:
                // kAudioUnitErr_FormatNotSupported. Seen live when a headset was
                // plugged in mid-session: the engine had outlived its device.
                return String(localized: "Микрофон сменился, и запись под него не поднялась (\(String(code))). Выключите и включите прослушивание ещё раз; если наушники только что подключились, дайте им пару секунд")
            case -10851:
                // kAudioUnitErr_InvalidPropertyValue.
                return String(localized: "Микрофон отдаёт формат, который не удалось принять (\(String(code)))")
            case -10877:
                // No input device at all.
                return String(localized: "Устройство ввода не найдено (\(String(code))): проверьте микрофон в «Системных настройках»")
            default:
                return String(localized: "Не удалось запустить запись микрофона (\(String(code)))")
            }
        }
    }

    let channel: Channel = .you

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    /// Called whenever capture changes what it is doing, on an arbitrary thread.
    ///
    /// The same seam `ThemAudioSource` has, and for the same reason: a channel
    /// that has gone quiet must be able to say so inside the window. Without it
    /// the one failure the user cannot hear — their own microphone dying because
    /// another application switched the device — would be visible to us in the
    /// log and invisible to them.
    var onStatusChange: (@Sendable (MicCaptureStatus) -> Void)?

    /// The engine of the **current** capture, replaced on every open.
    ///
    /// A `let` here was a bug, and it cost the user three symptoms in a row:
    /// plugging a headset mid-session made the app stop hearing them, and every
    /// later `start()` failed with `-10868 kAudioUnitErr_FormatNotSupported`
    /// until the app was relaunched. `AVAudioEngine.inputNode` binds to the
    /// default input device and caches its format at the moment it is first
    /// touched; `stop()` does not unbind it and `start()` does not re-read it.
    /// So once the device underneath has changed, that engine object can never
    /// start again — the failure belongs to the object, not to the device, which
    /// is why stopping and starting by hand did not help either.
    ///
    /// Guarded by `lock`, because recovery runs on an arbitrary thread.
    private var engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var _isRunning = false
    /// Kept for the whole life of a capture, because a restart has to re-install
    /// the tap around the very same handler.
    private var onFrame: AudioFrameHandler?
    private var recovery: CaptureRecovery?
    private let restartDelays: [TimeInterval]

    /// Holds the converter for whatever format the tap turns out to deliver.
    ///
    /// Built on the first buffer instead of up front: the format an input node
    /// reports and the one it delivers are not always the same, and the buffer is
    /// the only source of truth. Rebuilt if the format ever changes under us —
    /// somebody else switching the input device's mode mid-call does that, and
    /// since ADR-0009 that somebody is never us.
    private final class ConverterBox: @unchecked Sendable {
        private var converter: AVAudioConverter?
        private var sourceFormat: AVAudioFormat?

        func converter(for source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
            if let converter, sourceFormat == source { return converter }
            guard let made = AVAudioConverter(from: source, to: target) else { return nil }
            converter = made
            sourceFormat = source
            return made
        }
    }

    /// - Parameter sampleRate: rate the frames are delivered at. 16 kHz mono is
    ///   what speech recognition wants, and it keeps the buffers small.
    ///
    /// There is deliberately **no** voice-processing knob. A flag that is always
    /// false is a promise that it might one day be true, and ADR-0009 closed that
    /// question by measurement rather than by taste: the cost is charged to other
    /// processes, so there is no configuration in which switching it on is right.
    /// - Parameter restartDelays: how long to wait before each attempt to bring
    ///   capture back after somebody else changed the device, and how many
    ///   attempts there are. A parameter so a test does not sit through them.
    init(
        sampleRate: Double = 16_000,
        restartDelays: [TimeInterval] = CaptureRecovery.defaultDelays
    ) {
        self.restartDelays = restartDelays
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Asks the system for microphone access, if it has not been decided yet.
    ///
    /// Returns whether capture is allowed. A refusal has to be shown inside the
    /// app window: system banners would show up on top of a shared screen.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start(onFrame: @escaping AudioFrameHandler) throws {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        self.onFrame = onFrame
        lock.unlock()

        do {
            try openTap()
        } catch {
            lock.lock()
            self.onFrame = nil
            lock.unlock()
            throw error
        }

        lock.lock()
        _isRunning = true
        lock.unlock()

        // Subscribed only while capture is running, and to this engine only.
        // Since ADR-0009 nobody in this app switches the device's mode, which
        // means the next switch comes from another process — and without this a
        // switched device leaves the tap running and every frame gone.
        let recovery = CaptureRecovery(
            delays: restartDelays,
            restart: { [weak self] in try self?.openTap() },
            report: { [weak self] status in self?.onStatusChange?(status) }
        )
        lock.lock()
        self.recovery = recovery
        let current = engine
        lock.unlock()
        recovery.watch(current)

        onStatusChange?(.capturing)
    }

    func stop() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        let recovery = self.recovery
        self.recovery = nil
        onFrame = nil
        lock.unlock()

        // Outside the lock: `stopWatching` takes a lock of its own, and a
        // restart running right now takes this one.
        recovery?.stopWatching()

        lock.lock()
        let current = engine
        lock.unlock()
        current.inputNode.removeTap(onBus: 0)
        current.stop()
        onStatusChange?(.idle)
    }

    /// Brings the engine up around the current input node — the first time, and
    /// again after the device has changed under us.
    ///
    /// Everything is re-read rather than remembered, because a configuration
    /// change is precisely the moment the old values stop being true: the node
    /// reports a different format, and the converter built for the previous one
    /// would either fail or, worse, quietly produce silence.
    private func openTap() throws {
        lock.lock()
        let handler = onFrame
        let previous = engine
        lock.unlock()
        guard let handler else { return }

        // The old engine is retired rather than restarted. See the note on
        // `engine`: an input node that has outlived its device answers with a
        // stale format for the rest of its life, and `start()` on it returns
        // -10868 forever. Building a new one is the only way back, and it is
        // cheap — an engine with nothing attached is a few objects.
        previous.inputNode.removeTap(onBus: 0)
        previous.stop()

        let fresh = AVAudioEngine()
        lock.lock()
        engine = fresh
        lock.unlock()

        let input = fresh.inputNode

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.inputFormatUnavailable
        }

        // The tap is installed with `nil` rather than with the format the node
        // reports. The reported format and the one the node actually delivers can
        // differ, and a tap pinned to the wrong one yields buffers of digital
        // silence — the microphone indicator lights up and every sample is zero.
        // `nil` means "whatever this node really produces", which is also why the
        // converter below is built from the buffer rather than from the reported
        // format. Switching voice processing off did **not** retire this: the
        // mismatch is a property of the input node, and another process can put
        // the device into a multi-channel mode at any moment (ADR-0009).
        let targetFormat = targetFormat
        let converterBox = ConverterBox()
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let mono = Self.firstChannel(of: buffer) else { return }
            guard let converter = converterBox.converter(for: mono.format, to: targetFormat) else {
                return
            }
            guard let frame = Self.makeFrame(
                from: mono,
                converter: converter,
                targetFormat: targetFormat
            ) else { return }
            handler(frame)
        }

        fresh.prepare()
        do {
            try fresh.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineRefused(code: (error as NSError).code)
        }

        // The subscription follows the engine it belongs to: the notification is
        // posted with the engine as its object, and a watcher left on the retired
        // one would never fire again.
        lock.lock()
        let recovery = self.recovery
        lock.unlock()
        recovery?.watch(fresh)
    }

    /// Takes channel 0 of a captured buffer as a mono buffer at the same rate.
    ///
    /// This exists because of a trap that costs a whole debugging session if you
    /// meet it blind: a multi-channel input handed straight to `AVAudioConverter`
    /// with a request for mono comes back as **silence** — the converter has no
    /// channel map for the fold, and it reports no error while doing so. The
    /// indicator lights up, buffers keep arriving, and every sample is zero.
    ///
    /// It was found with voice processing on, where the built-in microphone
    /// presents seven channels, and **it survives ADR-0009 unchanged**: a headset
    /// delivers two, and any other process may still put the built-in microphone
    /// into its multi-channel mode while we are recording. The rule that came out
    /// of it — never ask a converter to fold more than two channels — is not tied
    /// to who enabled what.
    /// Internal rather than private so the regression test can reach it.
    static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard buffer.frameLength > 0, !format.isInterleaved, let source = buffer.floatChannelData else {
            return nil
        }
        guard format.channelCount > 1 else { return buffer }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
           let destination = mono.floatChannelData else {
            return nil
        }

        mono.frameLength = buffer.frameLength
        destination[0].update(from: source[0], count: Int(buffer.frameLength))
        return mono
    }

    /// Resamples one captured buffer into a `You` frame.
    private static func makeFrame(
        from buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AudioFrame? {
        guard buffer.frameLength > 0 else { return nil }
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
        return AudioFrame(channel: .you, samples: samples, sampleRate: targetFormat.sampleRate)
    }
}
