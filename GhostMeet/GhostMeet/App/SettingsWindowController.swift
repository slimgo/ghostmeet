//
//  SettingsWindowController.swift
//  GhostMeet
//

import AppKit
import SwiftUI

/// Owns the settings window.
///
/// GhostMeet runs as an accessory app, so it has no menu bar of its own: the
/// standard «Настройки…» item does not exist and SwiftUI's `Settings` scene is
/// unreachable. The only way in is the button in the overlay, which calls this.
///
/// Unlike the overlay this is an ordinary window and the opposite rules apply:
/// it is meant to be typed into, so it activates the app and takes the keyboard
/// focus. What it keeps from the overlay is `sharingType = .none` — the profile
/// and the state of the provider key have no business turning up in a shared
/// window either.
///
/// The window lives on the file-system-synchronised `App/` group rather than
/// `UI/Settings/` because it is window plumbing, not the settings screen itself;
/// `SettingsView` is what it hosts and knows nothing about windows.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private static let frameAutosaveName = "GhostMeet.settings.window"

    private let store: SettingsStore

    /// Model choice and download progress — live state of the recogniser rather
    /// than a setting, which is why it arrives beside the store and not inside it.
    private let recognition: SpeechModelStatus

    /// Which section the screen is asked to show. Owned here because the window
    /// outlives every request made to it: the view is built once and then only
    /// re-shown.
    private let navigation = SettingsNavigation()

    private var window: NSWindow?

    /// Whether this window is kept out of screen capture. Owned by the overlay's
    /// switch — see `OverlayWindowController.onCaptureVisibilityChange` — and
    /// stored here so a window built *after* the switch was flipped is born with
    /// the right value instead of the shipped default.
    private var sharingType: NSWindow.SharingType = .none

    /// Follows the app-wide switch. Applies to the window if it already exists.
    func setSharingType(_ type: NSWindow.SharingType) {
        sharingType = type
        window?.sharingType = type
    }

    /// - Parameter checkForUpdates: asks the feed now, for the button in the
    ///   updates section. A closure rather than the updater, because this window
    ///   only asks — the answer belongs on the overlay's one update line.
    /// Asks the feed now — see the initialiser.
    private let checkForUpdates: () -> Void

    init(
        store: SettingsStore,
        recognition: SpeechModelStatus,
        checkForUpdates: @escaping () -> Void = {}
    ) {
        self.store = store
        self.recognition = recognition
        self.checkForUpdates = checkForUpdates
        super.init()
    }

    /// Puts the settings window up, focused and in front — at `section` when the
    /// caller named one.
    ///
    /// The request is made **before** the window is loaded, so that the very
    /// first press on the readiness strip, which is also what builds the window,
    /// still arrives at the right section.
    func show(_ section: SettingsSection? = nil) {
        if let section { navigation.reveal(section) }
        let window = loadedWindow()
        // Cooperative activation may refuse an accessory app that the user never
        // clicked in the Dock — and the click that got us here landed in a
        // non-activating panel. `orderFrontRegardless` is what guarantees the
        // window is on screen even then.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Whether the window is currently on screen.
    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Window construction

    private func loadedWindow() -> NSWindow {
        if let window { return window }
        let created = makeWindow()
        window = created
        return created
    }

    private func makeWindow() -> NSWindow {
        let content = SettingsView(
            store: store,
            recognition: recognition,
            navigation: navigation,
            checkForUpdates: checkForUpdates
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Настройки GhostMeet"

        // Same content protection as the overlay, and it follows the same switch:
        // otherwise the settings screen stays unrecordable while the overlay is
        // deliberately visible, and «приложение невидимо» stops being true of the
        // application and becomes true of one window.
        window.sharingType = sharingType

        // Closing the window must not destroy it, and must not quit the app:
        // capture keeps running while settings are out of sight.
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.center()
        if window.setFrameAutosaveName(Self.frameAutosaveName) {
            _ = window.setFrameUsingName(Self.frameAutosaveName)
        }
        return window
    }
}
