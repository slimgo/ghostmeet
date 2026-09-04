//
//  AudioInputDeviceCatalog.swift
//  GhostMeet
//

import CoreAudio
import Foundation
import Observation

/// The microphones on this machine, kept current as they come and go.
///
/// A settings screen that reads `AudioInputDevices.all()` once shows the list
/// as it was when the screen opened: headphones connected a minute later are
/// not in it until something else redraws the view. Bluetooth headphones are
/// exactly the device that appears mid-session — and the one whose 16 kHz format
/// broke capture — so the list has to follow the hardware, not the redraw.
@MainActor
@Observable
final class AudioInputDeviceCatalog {

    private(set) var devices: [AudioInputDevice] = []

    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        devices = AudioInputDevices.all()

        // Core Audio calls this on its own queue; the list is main-actor state.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.listener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        )
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
        }
    }

    func refresh() {
        let current = AudioInputDevices.all()
        if current != devices { devices = current }
    }
}
