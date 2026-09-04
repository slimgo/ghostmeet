//
//  SCKIdleStreamLiveTests.swift
//  GhostMeetTests
//

import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing

/// Counts what a live `SCStream` delivers while its source makes no sound.
///
/// Off by default: it takes eight seconds of real ScreenCaptureKit and needs the
/// screen-recording permission, which the test host has because it is the app.
/// Run with `TEST_RUNNER_GHOSTMEET_LIVE_SCK=1`.
private final class IdleSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let lock = NSLock()
    var buffers = 0
    var nonEmpty = 0
    var stopped: String?

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        lock.lock()
        buffers += 1
        if buffer.numSamples > 0 { nonEmpty += 1 }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        stopped = error.localizedDescription
        lock.unlock()
    }
}

@Suite("Живой SCK: буферы при молчащем источнике")
struct SCKIdleStreamLiveTests {

    /// **The fact a frame watchdog for `Them` depends on.** A dead stream and a
    /// silent interlocutor look the same to the transcript; whether they look
    /// the same at the buffer level is what this measures. If a live stream keeps
    /// delivering (empty) buffers while Finder is quiet, then «ни одного буфера
    /// за N секунд» is a reliable sign of death. If it stops delivering, no such
    /// watchdog is possible.
    @Test("Что отдаёт живой поток, когда источник молчит",
          .enabled(if: LiveTestGate.isEnabled("GHOSTMEET_LIVE_SCK")))
    func liveStreamOnASilentSource() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let finder = try #require(content.applications.first { $0.bundleIdentifier == "com.apple.finder" })
        let display = try #require(content.displays.first)

        let filter = SCContentFilter(display: display, including: [finder], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sink = IdleSink()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck.idle.test"))
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(8))
        try await stream.stopCapture()

        sink.lock.lock()
        let (buffers, nonEmpty, stopped) = (sink.buffers, sink.nonEmpty, sink.stopped)
        sink.lock.unlock()

        print("SCK-IDLE: буферов \(buffers), непустых \(nonEmpty), обрыв: \(stopped ?? "нет")")
        #expect(stopped == nil, "поток оборвался сам: \(stopped ?? "")")
        // Recorded either way — the number is the finding, not the pass.
        #expect(buffers >= 0)
    }
}
