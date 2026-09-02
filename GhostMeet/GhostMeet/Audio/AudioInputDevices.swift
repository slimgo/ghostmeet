//
//  AudioInputDevices.swift
//  GhostMeet
//

import CoreAudio
import Foundation

/// One microphone the system can offer.
nonisolated struct AudioInputDevice: Equatable, Sendable, Identifiable {

    /// Stable across replugs and reboots, unlike `AudioDeviceID`.
    ///
    /// The numeric id is assigned per boot and is reused, so a setting storing it
    /// would silently point at a different microphone after a restart — which is
    /// the failure this whole setting exists to prevent.
    let uid: String
    let name: String
    let deviceID: AudioDeviceID

    var id: String { uid }
}

/// The microphones on this machine, and which one capture is actually using.
///
/// **Exists because the app listened to the wrong one and never said so.** On a
/// live run the user talked into the MacBook's microphone while capture was bound
/// to a Fifine standing across the room: `AVAudioEngine.inputNode` binds to the
/// system default input, and until now nothing here chose otherwise or reported
/// what had been chosen.
nonisolated enum AudioInputDevices {

    /// Every device with at least one input channel.
    static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id)
            else { return nil }
            return AudioInputDevice(uid: uid, name: name, deviceID: id)
        }
    }

    /// What the system would pick if nobody chose.
    static func systemDefault() -> AudioInputDevice? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return nil }
        return all().first { $0.deviceID == id }
    }

    /// Resolves a stored choice against what is plugged in right now.
    ///
    /// A device that is gone resolves to `nil` rather than to something else: the
    /// caller falls back to the system default and says so, because silently
    /// listening to a different microphone is exactly the failure being fixed.
    static func device(uid: String?) -> AudioInputDevice? {
        guard let uid else { return nil }
        return all().first { $0.uid == uid }
    }

    // MARK: -

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// Input channels, which is what makes a device a microphone.
    ///
    /// Every Mac has output devices and aggregate devices in the same list; asking
    /// for the input stream configuration is the only way to tell them apart.
    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
