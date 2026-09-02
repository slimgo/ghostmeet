//
//  LiveConnectionCheckSource.swift
//  GhostMeet
//

import AVFoundation
import CoreGraphics
import Foundation

/// The real answers behind `ConnectionCheck` — capture, provider, permissions.
///
/// Separate from the check itself so that every outcome can be produced in a test,
/// including the one that matters most and cannot be staged on a live machine: a
/// microphone delivering frames of pure zeroes.
@MainActor
struct LiveConnectionCheckSource: ConnectionCheckSource {

    let controller: SessionController
    let recognition: SpeechModelStatus
    let settings: SettingsStore

    var isListening: Bool { controller.isListening }

    var recognitionPhase: SpeechModelPhase { recognition.phase }

    func measureChannels(for seconds: TimeInterval) async -> CaptureProbe {
        controller.beginCaptureProbe()
        try? await Task.sleep(for: .seconds(seconds))
        return controller.endCaptureProbe()
    }

    /// Asks the configured provider the shortest question that still proves the
    /// whole path works: key, network, model, streaming.
    ///
    /// **It costs money, which is why nothing calls it on its own.** No timer, no
    /// window opening — only the button. The prompt is deliberately trivial and
    /// the answer is thrown away; what is being measured is that something came
    /// back at all.
    func askProvider() async -> Result<String, any Error> {
        guard let provider = try? settings.makeProvider() else {
            return .failure(CheckFailure.noProvider)
        }
        let request = SuggestionRequest(
            systemPrompt: "Reply with one word: ok",  // not localized: a probe, not interface text
            userPrompt: "ok?",                        // not localized: a probe, not interface text
            screenshot: nil,
            maxTokens: 16
        )
        do {
            var answer = ""
            for try await fragment in provider.stream(request) {
                answer += fragment
                // One fragment is proof enough; the rest would only cost tokens.
                if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            }
            return .success(answer)
        } catch {
            return .failure(error)
        }
    }

    func permissions() async -> (microphone: Bool, screen: Bool) {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Preflight rather than a request: asking here would pop a system dialog
        // in the middle of a check the user ran to *look* at something.
        let screen = CGPreflightScreenCaptureAccess()
        return (microphone, screen)
    }

    enum CheckFailure: LocalizedError {
        case noProvider

        var errorDescription: String? {
            switch self {
            case .noProvider:
                String(localized: "Провайдер не настроен — некому отвечать на подсказки.")
            }
        }
    }
}
