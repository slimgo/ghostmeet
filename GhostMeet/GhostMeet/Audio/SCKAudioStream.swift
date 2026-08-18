//
//  SCKAudioStream.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: buffers travel from the
// capture thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

/// One application as ScreenCaptureKit offers it, reduced to the fields the
/// source picker's id is built from.
///
/// A separate type from `RunningApplication` because the two lists are not the
/// same list: Core Audio knows every process that opened an audio device,
/// ScreenCaptureKit knows every application that owns a window. Something can
/// easily be in one and not the other — a command-line player has audio and no
/// window — and pretending otherwise would hide exactly the case worth knowing
/// about.
nonisolated struct ShareableApplication: Hashable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String?
    /// Path of the binary behind the pid. The only handle on an application that
    /// has no bundle identifier.
    let executableURL: URL?

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        name: String? = nil,
        executableURL: URL? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier?.isEmpty == true ? nil : bundleIdentifier
        self.name = name
        self.executableURL = executableURL
    }

    var displayName: String {
        name ?? bundleIdentifier ?? executableURL?.lastPathComponent ?? "PID \(processIdentifier)"
    }

    /// Identity for an entry no running application was matched to.
    ///
    /// Deliberately the same shape, and the same order of preference, as
    /// `AudioProcess.fallbackIdentity`: the two backends offer two different
    /// lists, and a source picked while one of them was selected has to stay
    /// picked after switching to the other.
    var fallbackIdentity: String {
        if let bundle = executableURL?.enclosingApplicationBundle { return bundle.path }
        if let bundleIdentifier { return bundleIdentifier }
        if let executableURL { return executableURL.path }
        return "pid:\(processIdentifier)"
    }

    /// Whether this is one of the processes behind the application the user
    /// picked.
    ///
    /// The id was minted by the picker, which builds it out of Core Audio's view
    /// of the world (`RunningApplication.identity` / `AudioProcess.fallbackIdentity`):
    /// bundle identifier if there is one, otherwise the enclosing `.app`,
    /// otherwise the path of the executable. All three forms have to be
    /// recognised here or the same browser would be selectable and then
    /// unfindable.
    func matches(sourceApplicationID id: String) -> Bool {
        guard !id.isEmpty else { return false }

        if let bundleIdentifier {
            if bundleIdentifier == id { return true }
            // `com.google.Chrome` owns `com.google.Chrome.helper`, and the dot
            // is what keeps it from also owning `com.google.ChromeCanary`.
            if bundleIdentifier.hasPrefix(id + ".") { return true }
        }
        if let executableURL {
            if executableURL.path == id { return true }
            if let bundle = executableURL.enclosingApplicationBundle, bundle.path == id { return true }
        }
        return id == "pid:\(processIdentifier)"
    }
}

/// What ScreenCaptureKit is pointed at.
nonisolated enum SCKAudioScope: Hashable, Sendable {
    /// The processes of the chosen application, and nothing else.
    case applications(Set<pid_t>)
}

/// Where the list of applications ScreenCaptureKit is willing to capture comes
/// from.
///
/// Narrower than `ThemAudioStream` on purpose: the settings screen has to offer
/// that list while nothing is being captured, and giving the picker something
/// that can also start an `SCStream` would be handing it a loaded gun. It is
/// also the one call that fails outright when Screen Recording was never
/// granted, which is how the screen learns to say so.
nonisolated protocol ShareableApplicationLister: AnyObject, Sendable {
    /// Applications ScreenCaptureKit is willing to capture right now.
    func shareableApplications() async throws -> [ShareableApplication]
}

/// The ScreenCaptureKit side of the `Them` channel, behind a seam.
///
/// The seam exists for the same reason `AudioProcessLister` does: everything
/// above it — resolving the chosen application, the status the overlay shows,
/// the conversion to 16 kHz mono — has to be exercisable without a display
/// server, a permission grant, or a machine that is playing something.
nonisolated protocol ThemAudioStream: ShareableApplicationLister {
    /// Starts delivering audio of the given scope. Buffers arrive on an
    /// arbitrary thread, in whatever format the system produces.
    func start(
        scope: SCKAudioScope,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws
    func stop()
    /// Called when the system tears the stream down on its own — the display
    /// configuration changed, the permission was revoked mid-call.
    var onFailure: (@Sendable (Error) -> Void)? { get set }
}

/// `SCStream` with `capturesAudio`, and nothing else.
///
/// The counterpart of `ProcessTap`: it knows about ScreenCaptureKit and about
/// buffers, and it knows nothing about channels, turns or settings.
///
/// Video is captured because `SCStream` has no audio-only mode, not because
/// anything wants it: the configuration asks for the smallest frame at the
/// slowest rate the API accepts and no `.screen` output is ever attached, so the
/// frames are produced and dropped inside the framework.
nonisolated final class SCKAudioStream: NSObject, ThemAudioStream, SCStreamOutput, SCStreamDelegate,
                                        @unchecked Sendable {

    enum StreamError: LocalizedError {
        case contentUnavailable(Error)
        case noDisplay
        case noMatchingApplication
        case startFailed(Error)

        var errorDescription: String? {
            switch self {
            case .contentUnavailable:
                // The same sentence the settings screen shows: one situation,
                // one wording, and it names both ways out of it.
                return ThemCaptureBackend.screenRecordingHelp
            case .noDisplay:
                return String(localized: "Система не сообщила ни одного дисплея для захвата")
            case .noMatchingApplication:
                return String(localized: "Приложение-источник не показывается в списке ScreenCaptureKit")
            case .startFailed(let error):
                return String(localized: "Не удалось запустить захват через ScreenCaptureKit: \(error.localizedDescription)")
            }
        }
    }

    /// Called when the system stops the stream by itself.
    var onFailure: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.ghostmeet.sck-audio", qos: .userInitiated)
    private let lock = NSLock()

    private var stream: SCStream?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    override init() { super.init() }

    // MARK: - Content

    func shareableApplications() async throws -> [ShareableApplication] {
        try await Self.content().applications.map(ShareableApplication.init(_:))
    }

    /// Widest list the API offers: windows that are off screen count, because an
    /// application minimised behind the call is still an application whose sound
    /// the user may want.
    private static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw StreamError.contentUnavailable(error)
        }
    }

    // MARK: - Lifecycle

    func start(
        scope: SCKAudioScope,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        stop()

        let content = try await Self.content()
        guard let display = content.displays.first else { throw StreamError.noDisplay }

        let filter: SCContentFilter
        switch scope {
        case .applications(let pids):
            let applications = content.applications.filter { pids.contains($0.processID) }
            guard !applications.isEmpty else { throw StreamError.noMatchingApplication }
            filter = SCContentFilter(
                display: display,
                including: applications,
                exceptingWindows: []
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        // Our own overlay must never come back as `Them`: the model would end up
        // reading its own previous answer aloud.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // `SCStream` has no audio-only mode. Nothing subscribes to `.screen`, so
        // these numbers only decide how much work the framework throws away.
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        lock.lock()
        self.onBuffer = onBuffer
        self.stream = stream
        lock.unlock()

        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            stop()
            throw StreamError.startFailed(error)
        }
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        onBuffer = nil
        lock.unlock()

        guard let stream else { return }
        // Fire-and-forget: `stopCapture` is async and the caller may be tearing
        // the session down synchronously. The stream is already unreachable from
        // here, so nothing depends on when the system finishes.
        Task { try? await stream.stopCapture() }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let description = sampleBuffer.formatDescription,
              let asbd = description.audioStreamBasicDescription,
              asbd.mSampleRate > 0 else { return }

        lock.lock()
        let handler = onBuffer
        lock.unlock()
        guard let handler else { return }

        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let mono = PCMMixdown.mono(
                from: list.unsafePointer,
                sampleRate: asbd.mSampleRate
            ), mono.frameLength > 0 else { return }
            handler(mono)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let isCurrent = self.stream === stream
        lock.unlock()
        guard isCurrent else { return }
        stop()
        onFailure?(error)
    }
}

extension ShareableApplication {

    /// Reads what ScreenCaptureKit reports, plus the executable path it does not
    /// report — the only way to recognise an application that has no bundle
    /// identifier.
    init(_ application: SCRunningApplication) {
        self.init(
            processIdentifier: application.processID,
            bundleIdentifier: application.bundleIdentifier,
            name: application.applicationName,
            executableURL: Self.executableURL(pid: application.processID)
        )
    }

    private static func executableURL(pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
