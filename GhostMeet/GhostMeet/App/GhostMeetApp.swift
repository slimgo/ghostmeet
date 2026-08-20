//
//  GhostMeetApp.swift
//  GhostMeet
//

import AppKit
import SwiftUI

@main
struct GhostMeetApp: App {

    @NSApplicationDelegateAdaptor(GhostMeetAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Neither window of the app is a SwiftUI scene.
        //
        // The overlay cannot be one: a `WindowGroup` cannot express a non-activating
        // panel with `sharingType = .none`, so it is built in AppKit by
        // `OverlayWindowController` from the app delegate.
        //
        // The settings window is not one either: in accessory mode there is no menu
        // bar, so this `Settings` scene has no item to be opened from. It stays as an
        // empty placeholder — `SettingsWindowController` puts `SettingsView` on screen
        // when the user presses the gear in the overlay.
        Settings {
            EmptyView()
        }
    }
}

/// Brings the app up as an accessory: no Dock icon, no entry in the app switcher,
/// and — the part that matters during a call — GhostMeet never becomes the active
/// app, so the keyboard focus stays with the call or the editor.
final class GhostMeetAppDelegate: NSObject, NSApplicationDelegate {

    /// Where everything the app remembers is written.
    ///
    /// The user's own domain for an ordinary launch, a throwaway one when the
    /// process was started by the test runner — see `AppDefaults`. Every store
    /// below is built on this one value, which is what keeps a test run out of
    /// the user's window geometry and settings.
    private let defaults = AppDefaults.forCurrentProcess()

    /// The one settings store of the app: the profile, the thresholds and the
    /// presence of the provider key.
    private lazy var settings = SettingsStore(defaults: defaults)

    /// Model choice and download progress of the recogniser. Shared between the
    /// session, which transcribes with it, and the settings screen, which picks
    /// the model and shows how far its download has got.
    private lazy var recognition = SpeechModelStatus(store: settings)

    /// The one session: microphone in, transcript out.
    ///
    /// It is handed the model's phase, not just the recogniser: listening that
    /// starts before the model is loaded loses the first thing said, because a
    /// turn closed too early is refused outright rather than queued.
    private lazy var session = SessionController.dualChannel(
        settings: settings,
        recognizer: recognition.recognizer,
        isRecognitionReady: { [weak self] in self?.recognition.phase.isReady ?? false }
    )

    private lazy var settingsWindowController = SettingsWindowController(
        store: settings,
        recognition: recognition,
        // The switch alone means nothing until the next launch; the button
        // beside it is what makes turning updates on take effect now.
        checkForUpdates: { [weak self] in self?.updates.checkNow() },
        // A restart for the language is the same restart as for an update, and
        // they share one rule: nothing happens during a call.
        relaunchBlocked: { [weak self] in
            AppRelaunch.reason(isBusy: !(self?.session.canQuit ?? true))
        }
    )

    /// Whether a newer build has been published, and — since 0.4.0 — putting it
    /// in place (ADR-0012).
    ///
    /// Built here because the three participants live in three different places
    /// and this is the only one holding all of them: the switch that permits it
    /// is in the settings store, the line that shows it is in the overlay, and
    /// the reason an install may have to wait is in the session. The store is
    /// read at request time rather than copied, so turning the check off takes
    /// effect from the next launch on without anything having to be told.
    ///
    /// The installer is built by a closure rather than passed in, so that with
    /// the switch off it is never built at all — off has to mean "no request",
    /// not "a request whose answer is thrown away".
    private lazy var updates = AppUpdater(
        makeInstaller: { [weak self] status in
            SparkleUpdateInstaller(status: status) { [weak self] in
                // The one thing an update must never do is interrupt a call.
                // Same rule as `SessionController.canQuit`, and the same reason:
                // installing is a restart, only not asked for by a human.
                InstallBlock.reason(isBusy: !(self?.session.canQuit ?? true))
            }
        },
        isEnabled: { [weak self] in self?.settings.checksForUpdates ?? false }
    )

    /// The global chords and what they do.
    ///
    /// Built on Carbon's `RegisterEventHotKey`, which needs **no permission** —
    /// see `CarbonHotkeyRegistry`. The app already asks for four grants; a fifth
    /// (Accessibility, which `NSEvent`'s global monitor requires) is not a trade
    /// worth making — the more so now that the chords are the only way a request
    /// ever reaches the model (ADR-0008).
    private lazy var hotkeys = HotkeyCenter(store: settings)

    private lazy var overlayWindowController = OverlayWindowController(
        session: session,
        recognition: recognition,
        hotkeys: hotkeys,
        openSettings: { [weak self] section in self?.settingsWindowController.show(section) },
        // The readiness strip reads the same store the settings screen edits —
        // there is one, and the strip must not be able to disagree with it.
        settings: settings,
        updates: updates,
        stateStore: WindowStateStore(defaults: defaults)
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before the first window appears, otherwise the Dock icon flashes.
        //
        // NOTE: the same thing is normally declared as `LSUIElement` in Info.plist.
        // That key is not in the plist yet; adding it there would make the accessory
        // mode take effect from the very first frame of launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Thresholds edited in the settings window reach the engine on their own
        // from here on; nothing else has to know a change happened.
        session.followThresholds(of: settings)

        // Same for the provider: picking another model — or fixing its address —
        // takes effect on the next suggestion, without relaunching the app.
        session.followProviderSelection(of: settings)

        // Load the recognition model now rather than on the first turn.
        //
        // Preparation is lazy by default, and a turn closed before the model is
        // ready is rejected outright rather than queued — otherwise a pile of
        // stale suggestions would land once loading finished. Left alone, that
        // means the first thing said in every session is lost, which in an
        // interview is the opening question. The model is already on disk by
        // then, so this only pays for loading it into memory.
        // ...but not under tests, and that exception was paid for. The suite
        // hosts itself inside this app, so every `xcodebuild test` launched the
        // whole launch path — including a WhisperKit model being fetched and
        // loaded onto the Neural Engine. On a CI runner that is a download, a
        // few hundred megabytes of memory and minutes of work behind a test
        // process that is meanwhile expected to answer in milliseconds; the host
        // died mid-run and the suites that never got to start reported
        // «Test run with 0 tests», which reads like success.
        //
        // Nothing is lost by skipping it: no test asserts that a real model is
        // fetched at launch — `SpeechModelStatus` is exercised through
        // `FakeSpeechModelProvider`, which is the seam built for exactly this.
        if !AppDefaults.isRunningTests() {
            recognition.prepare()
        }

        // How far preparation has got is reported in the overlay and nowhere
        // else. GhostMeet posts no system notifications at all — macOS draws
        // banners on top of everything, including the window the user is
        // sharing, and one banner is all it takes to give the app away
        // (ADR-0004). That holds for good news as much as for failures.

        // Listening is not started here on purpose: the microphone prompt would
        // come up before the user has asked for anything, and the first thing
        // they see would be a permission dialog rather than the overlay.

        // Ask whether a newer build exists. Asynchronous inside, so a slow or
        // unreachable network costs the launch nothing and the window comes up
        // the same either way.
        //
        // The two refusals that used to be written here — not under tests, not
        // with the switch off — now live inside `AppUpdater`, because with
        // Sparkle they have to be refusals to *build* the mechanism rather than
        // to call it: the framework's standard controller starts its updater in
        // its own initialiser, and a condition on this line would arrive too
        // late. Nothing here can put a request on the wire.
        updates.startAtLaunch()

        // The settings window carries the same content protection as the overlay,
        // so it follows the same switch. Wired here because this is the only
        // place holding both windows — the overlay has no business knowing that
        // a settings window exists.
        overlayWindowController.onCaptureVisibilityChange = { [weak self] sharingType in
            self?.settingsWindowController.setSharingType(sharingType)
        }

        wireHotkeys()

        overlayWindowController.show()
    }

    /// Connects the chords to the things they drive, and registers them with the
    /// system.
    ///
    /// The composition root is the only place that knows all three participants:
    /// the window (panic), the session (listening, and every request to the
    /// model) and the conversation (clearing). `HotkeyCenter` deliberately knows
    /// none of them.
    private func wireHotkeys() {
        hotkeys.actions = HotkeyActions(
            // Hiding is only the window. Capture keeps running — see
            // `OverlayWindowController.toggleVisibility()`.
            toggleVisibility: { [weak self] in self?.overlayWindowController.toggleVisibility() },
            // `startWhenRecognitionIsReady()` and not `start()`: a chord pressed
            // while the model is still loading has to mean "listen to this call",
            // not "listen now, or silently do nothing". A turn closed before the
            // model is ready is refused outright, so the plain `start()` here
            // would cost the user the opening question of the interview.
            startListening: { [weak self] in self?.session.startWhenRecognitionIsReady() },
            stopListening: { [weak self] in self?.session.stop() },
            // The two genres: the only way a question ever reaches the model
            // (ADR-0008). Short is the default press — the user is already
            // answering and is missing one thing.
            suggestBriefly: { [weak self] in self?.session.suggestBriefly() },
            suggestInDetail: { [weak self] in self?.session.suggestInDetail() },
            // Wanted with the hands on someone else's editor rather than on this
            // window — see `HotkeyAction`.
            solveOnScreen: { [weak self] in self?.session.solveOnScreen() },
            clearContext: { [weak self] in self?.session.clearContext() }
        )
        hotkeys.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding the overlay (panic hotkey, ticket 10) must not quit the app —
        // capture keeps running while the window is off screen.
        false
    }
}
