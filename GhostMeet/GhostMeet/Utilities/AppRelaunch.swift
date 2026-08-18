//
//  AppRelaunch.swift
//  GhostMeet
//

import AppKit
import Foundation

/// Closing the application and opening it again, by its own hand.
///
/// Exists for exactly one setting: the interface language. It is carried out
/// through `AppleLanguages`, which macOS reads once when the bundle is loaded, so
/// a change takes effect on the next launch and not before — see `AppLanguage`
/// for why that path was chosen over one that needs no restart.
///
/// **The restart was already honest; what was missing was a way to do it.** The
/// screen said «применяется после перезапуска» and left the user to close and
/// reopen the app by hand — in an application that restarts itself to install an
/// update. One press is the same thing, minus the errand.
enum AppRelaunch {

    /// Why the app may not restart itself this second, or nil.
    ///
    /// **The same rule as an update, and for the same reason** — restarting during
    /// a call ends the call, and it makes no difference to the user whether the
    /// restart was for a new version or for a new language. `SessionController`
    /// already refuses to *quit* while listening; this is that refusal, worded for
    /// the language picker.
    static func reason(isBusy: Bool) -> String? {
        isBusy ? String(localized: "идёт прослушивание") : nil
    }

    /// Starts a second copy and terminates this one.
    ///
    /// `open -n` rather than `NSWorkspace.launchApplication`: the running instance
    /// has not exited yet at the moment the new one is asked for, and without
    /// `-n` LaunchServices answers by activating the copy that is already there
    /// instead of starting a new one. The short delay is the same story from the
    /// other side — the new process must not race the old one for the same
    /// `UserDefaults`.
    static func now(bundle: Bundle = .main, terminate: @escaping () -> Void = { NSApp.terminate(nil) }) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundle.bundleURL.path]
        do {
            try task.run()
        } catch {
            // A failed relaunch is not silence: the user pressed, and the outcome
            // of a press is always spoken (ADR-0012). Here the app simply stays
            // open in the old language, which is visible on its own — there is
            // nothing to say that the screen does not already show.
            return
        }
        terminate()
    }
}
