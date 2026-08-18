//
//  ProcessTap.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: buffers travel from the
// realtime IO thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The Core Audio side of the `Them` channel, and nothing else.
///
/// Four objects have to be built in order and torn down in reverse: a process
/// tap over the chosen processes, an aggregate device that contains the tap, an
/// IOProc on that device, and the device itself started. Everything above this
/// type sees buffers.
///
/// Requires macOS 14.4, which is why the project's deployment target may not be
/// raised or lowered.
nonisolated final class ProcessTap: @unchecked Sendable {

    enum TapError: LocalizedError {
        case noProcesses
        case tapCreationFailed(OSStatus)
        case formatUnavailable
        case noOutputDevice
        case aggregateDeviceFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case deviceStartFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noProcesses:
                return String(localized: "Приложение-источник не выдаёт звук — его нечего слушать")
            case .tapCreationFailed(let status):
                return String(localized: "Не удалось создать тап на приложение-источник (код \(String(status)))")
            case .formatUnavailable:
                return String(localized: "Тап не сообщил формат звука")
            case .noOutputDevice:
                return String(localized: "Система не сообщила устройство вывода звука")
            case .aggregateDeviceFailed(let status):
                return String(localized: "Не удалось собрать агрегатное устройство для захвата (код \(String(status)))")
            case .ioProcFailed(let status):
                return String(localized: "Не удалось подключиться к потоку захвата (код \(String(status)))")
            case .deviceStartFailed(let status):
                return String(localized: "Не удалось запустить захват звука приложения-источника (код \(String(status)))")
            }
        }
    }

    /// Called on the realtime IO thread with the tap's own format. The consumer
    /// hops to its own isolation.
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private let queue = DispatchQueue(label: "com.ghostmeet.process-tap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Format the tap actually delivers — whatever the source application runs
    /// at, typically 48 kHz stereo. Known only after `start`.
    private(set) var format: AVAudioFormat?

    private(set) var isRunning = false
    /// Processes the running tap was built over. Compared against a fresh
    /// resolution to notice that the source application has been restarted.
    private(set) var tappedProcessObjectIDs: [AudioObjectID] = []

    /// Derives the format the tap actually delivers from the buffer list it
    /// hands over, and remembers it.
    ///
    /// A process tap reports its format up front, but the report is about the
    /// stream, not about how the samples are laid out in memory. Chrome's tap
    /// reports interleaved stereo and then delivers two separate channel
    /// buffers. Building an `AVAudioPCMBuffer` over a mismatched layout returns
    /// nil — silently — so every frame disappears with the IOProc running
    /// perfectly. The buffer list is the only honest source.
    private final class DeliveryFormat: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: AVAudioFormat?

        func format(matching list: UnsafePointer<AudioBufferList>, sampleRate: Double) -> AVAudioFormat? {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }

            let planar = list.pointee.mNumberBuffers > 1
            let channels = planar
                ? list.pointee.mNumberBuffers
                : list.pointee.mBuffers.mNumberChannels
            guard channels > 0 else { return nil }

            cached = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: !planar
            )
            return cached
        }
    }

    private let delivery = DeliveryFormat()

    init() {}

    deinit { stop() }

    /// Builds the tap over the given process objects and starts delivering audio.
    ///
    /// Every process of the application goes in at once — the main one and its
    /// helpers — because which of them carries the call's sound is not stable
    /// and changes when the application is restarted.
    func start(processObjectIDs: [AudioObjectID], onBuffer: @escaping BufferHandler) throws {
        guard !isRunning else { return }
        guard !processObjectIDs.isEmpty else { throw TapError.noProcesses }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "GhostMeet Them"
        description.uuid = UUID()
        description.isPrivate = true
        // Never `.muted`: the user has to keep hearing the call they are on.
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        self.tapID = tapID

        guard var streamDescription = Self.tapFormat(of: tapID),
              let format = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw TapError.formatUnavailable
        }
        self.format = format

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            stop()
            throw TapError.noOutputDevice
        }

        // The aggregate device is what an IOProc can be attached to; the output
        // device rides along as the clock source. Private, so it never shows up
        // in the user's sound settings.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GhostMeet Them Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard aggregateStatus == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            stop()
            throw TapError.aggregateDeviceFailed(aggregateStatus)
        }
        self.aggregateID = aggregateID

        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateID,
            queue
        ) { [delivery] _, inputData, _, _, _ in
            // The format the tap *reports* and the layout it *delivers* do not
            // have to agree, and when they disagree nothing says so: the buffer
            // simply fails to be built and the frame vanishes. Chrome's tap
            // reports interleaved stereo and hands over two separate channel
            // buffers, so the format is derived from the buffer list itself.
            guard let deliveredFormat = delivery.format(
                matching: inputData,
                sampleRate: format.sampleRate
            ) else { return }

            guard let buffer = Self.monoBuffer(
                from: inputData,
                sampleRate: deliveredFormat.sampleRate
            ), buffer.frameLength > 0 else { return }
            onBuffer(buffer)
        }
        guard ioStatus == noErr, let ioProcID else {
            stop()
            throw TapError.ioProcFailed(ioStatus)
        }
        self.ioProcID = ioProcID

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            stop()
            throw TapError.deviceStartFailed(startStatus)
        }

        tappedProcessObjectIDs = processObjectIDs
        isRunning = true
    }


    /// Copies the buffer list into a mono buffer we own.
    ///
    /// The trap it steps around — a capture whose reported format and delivered
    /// layout disagree, with nil returned and no error — is the same one the
    /// ScreenCaptureKit backend meets, so the fold itself lives in `PCMMixdown`.
    private static func monoBuffer(
        from list: UnsafePointer<AudioBufferList>,
        sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        PCMMixdown.mono(from: list, sampleRate: sampleRate)
    }

    /// Tears everything down in the reverse order it was built.
    ///
    /// Safe to call at any point of a failed `start`, which is what the error
    /// paths above rely on: each of them leaves exactly the objects it managed
    /// to create, and this removes precisely those.
    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        format = nil
        tappedProcessObjectIDs = []
        isRunning = false
    }

    // MARK: - Core Audio queries

    private static func tapFormat(of tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description) == noErr,
              description.mSampleRate > 0 else { return nil }
        return description
    }

    private static func defaultOutputDeviceUID() -> String? {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            systemObject,
            &deviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        ) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }
}
