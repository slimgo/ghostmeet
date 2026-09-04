//
//  MicCaptureService.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: its buffers travel from the
// realtime capture thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

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

    /// Only failures, and only once per tap: a per-frame line here would write
    /// the conversation to disk.
    private static let log = Logger(subsystem: "Mixxy.GhostMeet", category: "capture")

    /// Which microphone to bind to, asked afresh every time a tap is opened.
    ///
    /// A closure rather than a stored value because the choice lives in settings
    /// and may change between two starts — and because a device that was unplugged
    /// has to resolve to the system default at the moment of use, not at the
    /// moment of construction.
    private let preferredDevice: @Sendable () -> AudioInputDevice?

    /// The device the last successful tap actually bound to.
    ///
    /// Reported, not just remembered: the failure this exists for is listening to
    /// the wrong microphone without knowing it.
    private var _activeDevice: AudioInputDevice?

    var activeDevice: AudioInputDevice? {
        lock.lock()
        defer { lock.unlock() }
        return _activeDevice
    }

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
        restartDelays: [TimeInterval] = CaptureRecovery.defaultDelays,
        preferredDevice: @escaping @Sendable () -> AudioInputDevice? = { nil }
    ) {
        self.restartDelays = restartDelays
        self.preferredDevice = preferredDevice
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

        // **Bound before the format is read, and that order is the whole trick.**
        // `inputNode` latches onto the system default input and caches its format
        // the first time it is touched; setting the device afterwards leaves the
        // engine describing one microphone and recording another. That is the
        // same class of failure as the format traps in `docs/audio-traps.md` —
        // no error code, just sound from the wrong place.
        let chosen = preferredDevice()
        if let chosen, let unit = input.audioUnit {
            // Our own announcement is not news. Binding posts a configuration
            // change, and acting on it would restart the tap, which would bind
            // again — the loop that reached the transcript as a stream of
            // 0.08-second turns.
            lock.lock()
            let recovery = self.recovery
            lock.unlock()
            recovery?.suppressChanges()

            var deviceID = chosen.deviceID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Self.log.error("МИКРОФОН НЕ ВЫБРАН устройство=\(chosen.name, privacy: .public) код=\(String(status), privacy: .public)")
            }
        }
        lock.lock()
        // What was asked for, or what the system will hand over instead. Reported
        // either way: «слушаю не тот микрофон» has to be visible, not deduced.
        _activeDevice = chosen ?? AudioInputDevices.systemDefault()
        lock.unlock()

        // **The node's reported format is stale once a device has been bound to
        // it, and starting on it is -10868.** `inputNode` latches the default
        // device's format the moment it is created; binding another device
        // afterwards changes what the node records and not what it reports. With
        // the default at 48 kHz that never showed — every device here ran at
        // 48 kHz — and with Bluetooth headphones as the default (16 kHz) the
        // chosen 48 kHz microphone failed to start every time.
        //
        // Measured, four ways: tap on `nil` → -10868; `engine.reset()` first →
        // -10868; a tap pinned to an explicit 48 kHz format → starts and delivers
        // **zero frames**, the silent failure `docs/audio-traps.md` is about; a tap
        // pinned to the format read back from the AudioUnit *after* binding →
        // starts and delivers. So the format comes from the unit, not the node.
        let boundFormat: AVAudioFormat? = chosen == nil ? nil : Self.unitFormat(of: input)

        let inputFormat = boundFormat ?? input.outputFormat(forBus: 0)
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
        // `nil` for the default device — see above; the bound device's own
        // format when one was chosen, because `nil` there means the stale one.
        input.installTap(onBus: 0, bufferSize: 4096, format: boundFormat) { buffer, _ in
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

    /// The format the input unit will actually deliver for the device bound to it.
    ///
    /// Read from the AudioUnit's input scope rather than from the node: the node
    /// answers with the format it cached at creation, which is the default
    /// device's, and that is exactly the number that has to be wrong here.
    private static func unitFormat(of input: AVAudioInputNode) -> AVAudioFormat? {
        guard let unit = input.audioUnit else { return nil }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &description,
            &size
        )
        guard status == noErr, description.mSampleRate > 0, description.mChannelsPerFrame > 0 else {
            return nil
        }
        return AVAudioFormat(streamDescription: &description)
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
    ///
    /// **Interleaved and integer buffers are taken too, since 0.7.3.** A tap pinned
    /// to the format read back from the AudioUnit — the only pinning that starts
    /// on a bound device, see `openTap` — delivers whatever the unit's native
    /// layout is, and on this machine that is interleaved. The first version of
    /// this function returned `nil` for interleaved input, which would have turned
    /// the -10868 fix into a capture that starts and delivers nothing: every frame
    /// dropped here, no error anywhere. Caught by reading, not by the probe — the
    /// probe bypassed this function, which is the lesson.
    static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        // The common case, unchanged: planar float, one channel — nothing to do.
        if !format.isInterleaved, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 {
            return buffer
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
           let destination = mono.floatChannelData?[0] else {
            return nil
        }
        mono.frameLength = buffer.frameLength

        // Interleaved: channel 0 is every `channelCount`-th sample of plane 0.
        // Planar: channel 0 is plane 0 whole. Same loop, different stride.
        let channels = Int(format.channelCount)
        let stride = format.isInterleaved ? channels : 1

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let source = buffer.floatChannelData?[0] else { return nil }
            for i in 0..<frames { destination[i] = source[i * stride] }
        case .pcmFormatInt16:
            guard let source = buffer.int16ChannelData?[0] else { return nil }
            for i in 0..<frames { destination[i] = Float(source[i * stride]) / 32_768 }
        case .pcmFormatInt32:
            guard let source = buffer.int32ChannelData?[0] else { return nil }
            for i in 0..<frames { destination[i] = Float(source[i * stride]) / 2_147_483_648 }
        default:
            return nil
        }
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
