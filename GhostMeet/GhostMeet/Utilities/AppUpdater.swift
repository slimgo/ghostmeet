//
//  AppUpdater.swift
//  GhostMeet
//

import Foundation
import Observation

/// What the app needs of an update mechanism, and nothing more.
///
/// A protocol for the same reason capture, speech and the model layer have one
/// (ADR-0001): the only real implementation talks to the network and ends by
/// replacing the running application, and none of the rules worth testing here —
/// off means no request, tests make none at all, the profile is never sent — are
/// about how a feed was fetched.
@MainActor
protocol UpdateInstaller: AnyObject {

    /// Whether the machine's profile travels with the feed request.
    ///
    /// Part of the seam rather than a detail of the implementation because it is
    /// a promise the app makes out loud — see `SparkleUpdateInstaller`.
    var sendsSystemProfile: Bool { get set }

    /// Brings the mechanism up. Nothing reaches the network before this.
    func start()

    /// Asks the feed once.
    ///
    /// Takes no argument on purpose: whether a check is one the user asked for is
    /// a question about what to *show*, and the answer to it lives in
    /// `UpdateStatus` where the window can read it. The mechanism only fetches.
    func check()
}

/// Why an update cannot be installed this second, in words the user can act on.
///
/// Both answers are refusals to *start*, and that is the whole point: this is the
/// riskiest code in the app — a failed update breaks not a suggestion but the
/// ability to launch — and the cheapest way to leave a working application behind
/// is to not begin.
enum InstallBlock {

    /// The reason, or nil when it may go ahead.
    ///
    /// - Parameters:
    ///   - isBusy: whether a call is running. `SessionController.canQuit` already
    ///     refuses to quit while listening; installing is the same restart, only
    ///     not asked for by a human, so it obeys the same rule. Refusing here
    ///     costs a new version half an hour, and not refusing costs an interview.
    ///   - bundle: the application being replaced.
    static func reason(
        isBusy: Bool,
        bundle: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> String? {
        if isBusy {
            return "идёт прослушивание"
        }
        // Sparkle would handle this by itself, and that is exactly the problem:
        // it escalates with a system authorisation dialog — «GhostMeet wants
        // permission to update», asking for an admin password. A window of
        // somebody else's on top of a shared screen is the failure this app is
        // built to avoid (ADR-0004), so the same condition is tested here first,
        // with the same two paths Sparkle tests, and refused in our own line.
        let container = bundle.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: bundle.path),
              fileManager.isWritableFile(atPath: container.path) else {
            return "нет прав на запись в \(container.path) — обновите вручную"
        }
        return nil
    }
}

/// Whether a newer GhostMeet exists, and — since 0.4.0 — putting it in place.
///
/// **The switch is the whole of the user's consent, and off means silent in the
/// strong sense**: with `checksForUpdates` off nothing is constructed, nothing is
/// started, and no request is made. Not a request whose answer is ignored — the
/// difference matters to somebody who turned it off precisely so their machine
/// would stop talking to GitHub.
///
/// **Never under tests.** The suite hosts itself inside the app, so every
/// `xcodebuild test` would otherwise put a feed request on the wire — noise on a
/// developer's machine and a rate limit waiting to happen on a runner where
/// hundreds of jobs share one address. Worse here than for the old check: this
/// mechanism can download and replace the application it is running inside.
@MainActor
@Observable
final class AppUpdater {

    /// The state the overlay reads. Lives here so it exists whether or not the
    /// mechanism was ever started — the window asks it the same question either
    /// way, and gets `.idle` when updating is off.
    let status: UpdateStatus

    @ObservationIgnored private let makeInstaller: (UpdateStatus) -> any UpdateInstaller
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let isRunningTests: Bool

    /// Nil until `start()` decides the mechanism may exist at all. That is the
    /// point: an updater that was never built cannot ask for anything.
    @ObservationIgnored private var installer: (any UpdateInstaller)?

    init(
        isRunningTests: Bool = AppDefaults.isRunningTests(),
        makeInstaller: @escaping (UpdateStatus) -> any UpdateInstaller,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.status = UpdateStatus()
        self.isRunningTests = isRunningTests
        self.makeInstaller = makeInstaller
        self.isEnabled = isEnabled
    }

    /// Brings the updater up and asks once. Called at launch and nowhere else:
    /// the app is opened for a call and closed after it, so a timer would only
    /// spend somebody's network on an answer that cannot have changed.
    func startAtLaunch() {
        guard let installer = startIfPermitted() else { return }
        status.checkBegan(userInitiated: false)
        installer.check()
    }

    /// Asks now because somebody pressed. Unlike the launch check, this one says
    /// what it found — including that it found nothing, and including failure.
    func checkNow() {
        guard let installer = startIfPermitted() else { return }
        status.checkBegan(userInitiated: true)
        installer.check()
    }

    /// Builds and starts the mechanism the first time it is allowed to exist.
    ///
    /// Both refusals are absolute rather than "start it and stay quiet": under
    /// tests and with the switch off there is to be no updater at all.
    @discardableResult
    private func startIfPermitted() -> (any UpdateInstaller)? {
        if let installer { return installer }
        guard !isRunningTests else { return nil }
        // Read at call time rather than at construction: the switch may have been
        // turned off in an earlier session, and it is the whole of the consent.
        guard isEnabled() else { return nil }

        let installer = makeInstaller(status)
        // The promise is «наружу уходит IP и версия и больше ничего», so the
        // optional profile is turned off here as well as in Info.plist. This is
        // the half that wins: it is written into UserDefaults, which the
        // framework reads before the bundle's keys.
        installer.sendsSystemProfile = false
        installer.start()
        self.installer = installer
        return installer
    }
}
