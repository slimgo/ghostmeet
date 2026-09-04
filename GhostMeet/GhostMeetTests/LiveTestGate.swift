//
//  LiveTestGate.swift
//  GhostMeetTests
//

import Foundation

/// Whether a test that needs the real machine — screen, ScreenCaptureKit, seconds
/// of wall clock — should run.
///
/// **Two switches, because the first one stopped working.** The documented way
/// was an environment variable in front of `xcodebuild`; since the test action
/// set `shouldUseLaunchSchemeArgsEnv = NO` (0.5.1, to pin the host's language),
/// the shell's environment no longer reaches the host, and `GHOSTMEET_LIVE_SCREEN=1`
/// has been silently skipping its test ever since — «0 tests in 1 suite passed».
/// A file next to the project needs no cooperation from the scheme:
///
/// ```
/// touch .build/live-tests && xcodebuild ... test -only-testing:GhostMeetTests/<Suite>
/// ```
///
/// `.build/` is git-ignored, so the flag never ships; remove it to go back to
/// the fast suite.
enum LiveTestGate {

    static func isEnabled(_ variable: String) -> Bool {
        if ProcessInfo.processInfo.environment[variable] == "1" { return true }
        return FileManager.default.fileExists(atPath: flagPath)
    }

    /// `<repo>/.build/live-tests`, located from this file rather than from the
    /// working directory, which under xcodebuild is anywhere.
    private static var flagPath: String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // GhostMeetTests/
        return tests.deletingLastPathComponent().deletingLastPathComponent()      // repo root
            .appendingPathComponent(".build/live-tests").path
    }
}
