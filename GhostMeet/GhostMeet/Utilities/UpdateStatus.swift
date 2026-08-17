//
//  UpdateStatus.swift
//  GhostMeet
//

import Foundation
import Observation

/// A published release, as much of it as the window needs to show.
struct OfferedUpdate: Equatable, Sendable {
    /// The human version — `0.4.0`. A string and not `AppVersion` because it
    /// comes from the feed as written there, and the app shows it rather than
    /// compares it: the comparison has already been made by then.
    let version: String
    /// What changed, as the release notes were written in CHANGELOG.
    let notes: String?
}

/// What the user answered to an offered update.
///
/// Ours rather than Sparkle's, so that everything above the Sparkle seam —
/// the window, this file, and every test — can be exercised without it.
enum UpdateChoice: Equatable, Sendable {
    case install
    case dismiss
}

/// Where the app is in an update, and therefore what the window says.
enum UpdatePhase: Equatable, Sendable {
    /// Nothing to say. Covers up to date, never checked, checked and failed in
    /// the background, and dismissed.
    case idle
    /// A check the user asked for is in flight. Never entered for the check at
    /// launch — that one is silent whatever it finds.
    case checking
    /// There is a newer build, and nothing has been downloaded yet.
    case available(OfferedUpdate)
    /// Downloading. Nil while the size is not yet known.
    case downloading(fraction: Double?)
    /// Unpacking, verifying, preparing to swap.
    case preparing
    /// Replacing the bundle. The app is about to quit and come back.
    case installing
    /// The user asked and the answer was no news. Only ever reached by a press —
    /// the launch check says nothing when it finds nothing.
    case upToDate
    /// Something went wrong **in front of the user**, after they pressed.
    case failed(String)
}

extension UpdatePhase {

    /// Whether the overlay shows its update line at all.
    ///
    /// **Nothing about updating is visible during a call**, and since 0.4.0 that
    /// is a stronger statement than it used to be: the line is no longer only
    /// news, it carries the button that replaces the application. Hiding it while
    /// listening removes the button from a window that sits a hand's width from
    /// chords pressed without looking (ADR-0010, ADR-0012).
    ///
    /// Nothing is lost by hiding it. A verdict survives the call — `finished()`
    /// keeps `.failed` and `.upToDate` — so «поставить не вышло, шёл звонок»
    /// is read afterwards rather than missed.
    func isVisible(whileListening isListening: Bool) -> Bool {
        guard self != .idle else { return false }
        return !isListening
    }
}

/// The state of updating, and the only thing the overlay reads.
///
/// **Deliberately knows nothing about Sparkle.** Everything here is driven from
/// outside — by `SparkleUpdateInstaller`'s user driver in the app, by a test
/// directly — which is what lets the whole of the visible behaviour be exercised
/// without a network, a feed, or a framework that wants to relaunch the process.
///
/// **The silence rule is not uniform, and the boundary is the point.** ADR-0010
/// says a request the user did not ask for keeps quiet about its failures, and
/// that still holds: no network, no feed, a signature that does not verify during
/// the check at launch all end in `.idle` with nothing on screen. But the outcome
/// of something the user *pressed* is never silent. A failed install that says
/// nothing leaves somebody certain they have updated, walking into an interview
/// on the old build — which is the one thing this feature exists to prevent.
/// `isUserInitiated` is what tells the two apart.
@MainActor
@Observable
final class UpdateStatus {

    private(set) var phase: UpdatePhase = .idle

    /// Whether what is happening now was asked for by a press.
    ///
    /// Set by whoever starts a check, read by every reporting method below to
    /// decide between saying so and saying nothing.
    private(set) var isUserInitiated = false

    /// How the pending question gets its answer. Held while the window shows the
    /// offer, called exactly once when the user decides.
    @ObservationIgnored private var answer: ((UpdateChoice) -> Void)?

    /// Bytes expected and received, for the one phase that has a percentage.
    @ObservationIgnored private var expectedBytes: UInt64?
    @ObservationIgnored private var receivedBytes: UInt64 = 0

    // MARK: - Driven from the outside

    /// A check has begun. `userInitiated` decides whether anything is shown now
    /// and whether its failure will be shown later.
    func checkBegan(userInitiated: Bool) {
        isUserInitiated = userInitiated
        phase = userInitiated ? .checking : .idle
    }

    /// There is a newer build. The window shows it; `answer` is called once the
    /// user presses, and until then the update sits waiting.
    func offer(_ update: OfferedUpdate, answer: @escaping (UpdateChoice) -> Void) {
        // A second offer while one is outstanding would strand the first
        // question unanswered, and the framework asking it would wait forever.
        resolve(.dismiss)
        self.answer = answer
        phase = .available(update)
    }

    /// Nothing newer exists. Said out loud only if the user asked.
    func foundNothing() {
        phase = isUserInitiated ? .upToDate : .idle
    }

    /// It did not work. Said out loud only if the user asked — see the type's
    /// note on why this rule is not uniform.
    func failed(_ reason: String) {
        resolve(.dismiss)
        phase = isUserInitiated ? .failed(reason) : .idle
    }

    func downloadBegan() {
        expectedBytes = nil
        receivedBytes = 0
        phase = .downloading(fraction: nil)
    }

    func downloadExpects(_ total: UInt64) {
        expectedBytes = total
        phase = .downloading(fraction: fraction)
    }

    func downloadReceived(_ bytes: UInt64) {
        receivedBytes += bytes
        phase = .downloading(fraction: fraction)
    }

    func preparingBegan() {
        phase = .preparing
    }

    func preparingProgress(_ value: Double) {
        // Extraction reports its own 0…1, and it is a different bar from the
        // download's. One line and one percentage is enough for the window.
        phase = .downloading(fraction: min(max(value, 0), 1))
    }

    func installingBegan() {
        phase = .installing
    }

    /// The update is over, one way or another.
    ///
    /// **A verdict outlives the session that produced it.** Sparkle ends every
    /// update this way, including the ones that ended badly and the ones that
    /// found nothing — so clearing the phase unconditionally here would wipe the
    /// failure a moment after it was set, and a failed install that says nothing
    /// leaves somebody certain they have updated. `.failed` and `.upToDate`
    /// therefore stay until the user puts them away; everything else was progress
    /// and has nothing left to report.
    func finished() {
        resolve(.dismiss)
        expectedBytes = nil
        receivedBytes = 0
        isUserInitiated = false
        switch phase {
        case .failed, .upToDate: break
        case .idle, .checking, .available, .downloading, .preparing, .installing: phase = .idle
        }
    }

    // MARK: - Driven by the user

    /// «Обновить». Also marks everything that follows as user-initiated, because
    /// from here on failures have to be spoken: they are the outcome of a press.
    func install() {
        isUserInitiated = true
        resolve(.install)
    }

    /// «Не сейчас» — puts the line away for this launch and lets the update go.
    ///
    /// Not remembered on disk, and that is the cheap answer to what "dismissed"
    /// means: it lasts as long as the window does. Somebody dismissing this is
    /// saying «не сейчас, я иду на звонок», not «не говори мне об этой версии
    /// больше никогда».
    func dismiss() {
        resolve(.dismiss)
        isUserInitiated = false
        phase = .idle
    }

    // MARK: -

    private var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(Double(receivedBytes) / Double(expectedBytes), 1)
    }

    /// Answers the outstanding question, if there is one, and never twice.
    ///
    /// Called from every path that ends an update, including the ones that end it
    /// badly: the framework suspends waiting for this, and an answer that never
    /// comes is an update that neither installs nor goes away.
    private func resolve(_ choice: UpdateChoice) {
        guard let answer else { return }
        self.answer = nil
        answer(choice)
    }
}
