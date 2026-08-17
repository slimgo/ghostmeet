//
//  SparkleUpdateInstaller.swift
//  GhostMeet
//

import AppKit
import Foundation
import Sparkle

/// The real update mechanism: Sparkle, with a user interface of our own.
///
/// **Sparkle rather than a downloader of our own** — not because of the volume of
/// work, but because of one place in it: verifying the signature of what was
/// downloaded. A mistake there opens code substitution in an application that
/// listens to a microphone and sees the screen, and that is a solved problem not
/// worth solving again (ADR-0012).
///
/// **Started explicitly, never on construction.** `SPUStandardUpdaterController`
/// brings the updater up inside its own initialiser — that is, before any
/// condition of ours could run, so `AppDefaults.isRunningTests()` would arrive too
/// late to stop it and every `xcodebuild test` would ask GitHub for a feed. The
/// updater is therefore built directly here and started only when `AppUpdater` has
/// decided it may exist at all.
@MainActor
final class SparkleUpdateInstaller: UpdateInstaller {

    private let updater: SPUUpdater
    private let driver: OverlayUpdateDriver

    /// - Parameters:
    ///   - status: what the driver writes into, and the overlay reads.
    ///   - installBlock: why the app may not quit and relaunch this second, or
    ///     nil. See `InstallBlock` — the two reasons are a call in progress and a
    ///     bundle nobody can write.
    init(status: UpdateStatus, installBlock: @escaping @MainActor () -> String? = { nil }) {
        driver = OverlayUpdateDriver(status: status, installBlock: installBlock)
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
    }

    /// Whether the machine's profile travels with the feed request.
    ///
    /// The app promises that what leaves it is an IP address and a version and
    /// nothing else. Sparkle can attach the model, the CPU, the OS version and the
    /// language as a query string on the feed URL; this is the switch that stops
    /// it, and it is the authoritative one — it writes into `UserDefaults`, which
    /// the framework consults before the bundle's own keys. `SUSendProfileInfo`
    /// and `SUEnableSystemProfiling` in Info.plist say the same thing from the
    /// other side, and `make-dmg.sh` checks that they still do.
    var sendsSystemProfile: Bool {
        get { updater.sendsSystemProfile }
        set { updater.sendsSystemProfile = newValue }
    }

    func start() {
        // A failure to start is silence, like every other failure of a request
        // the user did not ask for (ADR-0010). There is nothing here the user
        // could act on, and the app works exactly as it did without an updater.
        try? updater.start()
    }

    func check() {
        // `checkForUpdates()` rather than `checkForUpdatesInBackground()`, and
        // deliberately: the background variant is documented as belonging to
        // Sparkle's own scheduler, which is off here (`SUEnableAutomaticChecks`),
        // and calling it outside that cycle interferes with it. Which check is
        // "background" for our purposes — silent about what it did not find — is
        // ours to decide, and `UpdateStatus` decides it.
        updater.checkForUpdates()
    }
}

// MARK: - The user interface Sparkle is not allowed to have

/// Sparkle's user interface, redirected into the overlay window.
///
/// **This class exists because of ADR-0004.** Sparkle ships a perfectly good
/// interface, and every part of it is a window or a notification of its own —
/// which, in an app whose entire design is about not appearing on a shared
/// screen, is the exact failure it defends against. So every method below either
/// writes one line of state into `UpdateStatus`, which the overlay draws inside
/// itself, or does nothing at all.
///
/// **Two windows are still not ours, and honesty is cheaper than pretending.**
/// If the bundle cannot be written, Sparkle's installer escalates with a system
/// authorisation dialog — which is why `AppUpdater` refuses to start an install
/// in that case rather than letting it happen. And once the app has quit to be
/// replaced, Sparkle's installer agent shows a small progress window if the swap
/// takes longer than 0.7 s; that one is not suppressible from a custom driver
/// (`SPUUIBasedUpdateDriver` always installs `displayingUserInterface: YES`), and
/// it appears only after a deliberate press, with no call running, while this
/// app is not on screen at all.
@MainActor
final class OverlayUpdateDriver: NSObject, SPUUserDriver {

    private let status: UpdateStatus
    private let installBlock: @MainActor () -> String?

    init(status: UpdateStatus, installBlock: @escaping @MainActor () -> String?) {
        self.status = status
        self.installBlock = installBlock
    }

    // MARK: - Asking

    /// Never reached: `SUEnableAutomaticChecks` is set in Info.plist, and Sparkle
    /// only asks this when the key is absent. Answered conservatively anyway —
    /// the app's own switch is the consent, and there is not to be a second one.
    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // The line is already showing «Проверяю…» — `beginCheck` put it there.
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) async -> SPUUserUpdateChoice {
        let offered = OfferedUpdate(
            version: appcastItem.displayVersionString,
            notes: appcastItem.itemDescription
        )
        // Suspends until the user presses. That is the whole design: nothing is
        // downloaded and nothing is replaced until somebody decides to, and the
        // decision arrives through the overlay rather than through a window of
        // Sparkle's own.
        return await withCheckedContinuation { continuation in
            status.offer(offered) { [installBlock, status] choice in
                guard choice == .install else {
                    continuation.resume(returning: .dismiss)
                    return
                }
                // Checked here as well as at the moment of the swap, so that a
                // press which cannot possibly succeed says so instead of
                // spending four megabytes of somebody's network first.
                if let reason = installBlock() {
                    status.failed(reason)
                    continuation.resume(returning: .dismiss)
                    return
                }
                continuation.resume(returning: .install)
            }
        }
    }

    func showUpdateNotFoundWithError(_ error: any Error) async {
        status.foundNothing()
    }

    func showUpdaterError(_ error: any Error) async {
        status.failed(error.localizedDescription)
    }

    // MARK: - Fetching

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        status.downloadBegan()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        status.downloadExpects(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        status.downloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        status.preparingBegan()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        status.preparingProgress(progress)
    }

    /// Release notes are not fetched separately: they travel inside the feed as
    /// the item's description, put there from CHANGELOG by `release.sh`. Both
    /// methods are required by the protocol and have nothing to do.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    // MARK: - Replacing

    /// The moment the app quits and comes back, and the one an update must never
    /// take by surprise.
    ///
    /// Refusing here is not "postpone" — Sparkle drops the update and the
    /// downloaded copy is discarded. That is the correct trade: the alternative
    /// is an application that closes itself in the middle of an interview, and a
    /// new version half an hour later costs nothing.
    /// Checked a second time, and not out of caution: the first check happened at
    /// the press, and a four-megabyte download later the call the user was about
    /// to join may well have started.
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        if let reason = installBlock() {
            status.failed("\(reason). Обновление не установлено")
            return .dismiss
        }
        return .install
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        status.installingBegan()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        status.finished()
    }

    func dismissUpdateInstallation() {
        // Called whenever an update ends — installed, refused, or failed. The
        // pending question, if there still is one, is answered here: Sparkle
        // suspends on it, and a question never answered is an update that
        // neither installs nor goes away.
        status.finished()
    }
}

private extension UpdateChoice {
    var sparkleChoice: SPUUserUpdateChoice {
        switch self {
        case .install: .install
        case .dismiss: .dismiss
        }
    }
}
