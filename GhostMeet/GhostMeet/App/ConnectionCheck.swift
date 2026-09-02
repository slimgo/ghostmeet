//
//  ConnectionCheck.swift
//  GhostMeet
//

import Foundation

/// One line of the check, as the window shows it.
nonisolated struct CheckResult: Equatable, Sendable, Identifiable {

    /// What was checked. Also the id — each subject appears once.
    enum Subject: String, CaseIterable, Sendable {
        case microphone
        case them
        case provider
        case recognition
        case permissions

        var title: String {
            switch self {
            case .microphone: String(localized: "Микрофон")
            case .them: String(localized: "Звук собеседника")
            case .provider: String(localized: "Провайдер")
            case .recognition: String(localized: "Распознавание")
            case .permissions: String(localized: "Разрешения")
            }
        }
    }

    /// **Three outcomes, and the middle one is why this check is worth having.**
    /// A tick that lights up on a dead microphone is worse than no tick: it sends
    /// the user into an interview certain that everything works.
    enum Outcome: Equatable, Sendable {
        /// Data went through; it works.
        case works
        /// Nothing was heard. Not a failure and not a pass — say something and look again.
        case noSound
        /// Broken, and the line says how.
        case broken
    }

    let subject: Subject
    let outcome: Outcome
    /// One sentence readable without documentation.
    let detail: String

    var id: String { subject.rawValue }
}

/// What the check needs to know, without knowing who provides it.
///
/// A protocol rather than a pile of closures because the check has five subjects
/// and a test needs to drive each of them independently — including the states
/// that are hard to produce on a real machine, like a microphone delivering
/// frames of pure zeroes.
@MainActor
protocol ConnectionCheckSource {
    /// Whether capture is running at all — the channels cannot be checked otherwise.
    var isListening: Bool { get }
    /// Turns frame accounting on, waits `seconds`, and hands back what arrived.
    func measureChannels(for seconds: TimeInterval) async -> CaptureProbe
    /// Asks the configured provider a question that costs as little as possible.
    func askProvider() async -> Result<String, any Error>
    /// Where recognition has got to.
    var recognitionPhase: SpeechModelPhase { get }
    /// Permissions, as the system reports them right now.
    func permissions() async -> (microphone: Bool, screen: Bool)
    /// The microphone capture is actually bound to, if it is known.
    var activeMicrophone: String? { get }
}

/// Checks that everything the call needs is actually working, on request.
///
/// **It measures data passing through rather than settings being present.** The
/// live failure this exists for looked like this: capture started without an
/// error, the microphone delivered nothing, the app said nothing, and a
/// Stop/Listen cycle fixed it. `SessionEngine.start()` treats capture as started
/// when `source.start` does not throw, and nothing afterwards notices that no
/// frames arrive — so a check that read configuration would have reported five
/// green lines during exactly that failure.
@MainActor
struct ConnectionCheck {

    /// How long the channels are listened to.
    ///
    /// Long enough for a person to say a word after pressing, short enough that
    /// nobody walks away: the check is done before a call, with the interviewer
    /// possibly already waiting.
    static let window: TimeInterval = 3

    let source: any ConnectionCheckSource

    func run() async -> [CheckResult] {
        var results: [CheckResult] = []

        let permissions = await source.permissions()
        results.append(permissionsResult(permissions))
        results.append(recognitionResult(source.recognitionPhase))

        // Channels and the provider are the slow half, and they are independent:
        // the request goes out while the microphone is being listened to.
        async let provider = source.askProvider()
        results.append(contentsOf: await channelResults())
        results.append(providerResult(await provider))

        return results.sorted { lhs, rhs in
            let order = CheckResult.Subject.allCases
            return order.firstIndex(of: lhs.subject)! < order.firstIndex(of: rhs.subject)!
        }
    }

    // MARK: - The channels

    private func channelResults() async -> [CheckResult] {
        guard source.isListening else {
            let detail = String(localized: "Прослушивание не идёт — включите его, иначе проверять нечего.")
            return [
                CheckResult(subject: .microphone, outcome: .noSound, detail: detail),
                CheckResult(subject: .them, outcome: .noSound, detail: detail),
            ]
        }

        let probe = await source.measureChannels(for: Self.window)
        return [
            result(for: .microphone, probe[.you], quiet: String(localized: "Кадры идут, но звука в них нет. Слушаю: \(source.activeMicrophone ?? String(localized: "устройство по умолчанию")) — говорить нужно в него. Если это не тот микрофон, смените его в настройках.")),
            result(for: .them, probe[.them], quiet: String(localized: "Кадры идут, но звука в них нет. Это нормально, пока собеседник молчит; включите звук в звонилке и проверьте снова.")),
        ]
    }

    private func result(for subject: CheckResult.Subject, _ probe: ChannelProbe, quiet: String) -> CheckResult {
        switch probe.verdict {
        case .noFrames:
            CheckResult(
                subject: subject,
                outcome: .broken,
                detail: String(localized: "За \(String(Int(Self.window))) с не пришло ни одного кадра. Захват числится запущенным, но звук до него не доходит — помогает «Стоп», затем «Слушать».")
            )
        case .silent:
            CheckResult(subject: subject, outcome: .noSound, detail: quiet)
        case .sound(let peak):
            // **Громкости мало — важно, проходит ли она гейт.** Реплика не
            // откроется, пока RMS ниже `silenceGateRMS`, и встроенный микрофон
            // ноутбука на замере давал пик втрое ниже внешнего. Пользователь,
            // который видит «звук есть» и не получает ни одной реплики, будет
            // искать поломку где угодно, кроме порога.
            CheckResult(
                subject: subject,
                outcome: peak < TurnSegmentationConfig.default.silenceGateRMS * 2 ? .noSound : .works,
                detail: quietPeakDetail(subject: subject, peak: peak)
            )
        }
    }

    private func quietPeakDetail(subject: CheckResult.Subject, peak: Float) -> String {
        let gate = TurnSegmentationConfig.default.silenceGateRMS
        let device = subject == .microphone
            ? " " + String(localized: "Слушаю: \(source.activeMicrophone ?? String(localized: "устройство по умолчанию")).")
            : ""
        if peak < gate * 2 {
            return String(localized: "Звук есть, но тихий: пик \(String(Int(peak * 100))) % при пороге тишины \(String(Int(gate * 100))) %. Реплики будут открываться через раз — говорите ближе или добавьте громкости устройству в системных настройках.") + device
        }
        return String(localized: "Звук идёт, пик \(String(Int(peak * 100))) %.") + device
    }

    // MARK: - The rest

    /// The provider is asked a real question, because a key being present and a
    /// provider answering are different facts — and only the second one matters
    /// when a chord is pressed mid-interview.
    private func providerResult(_ answer: Result<String, any Error>) -> CheckResult {
        switch answer {
        case .success(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            CheckResult(
                subject: .provider,
                outcome: .broken,
                detail: String(localized: "Провайдер ответил пустотой. Обычно это модель, которая потратила бюджет на невидимые токены.")
            )
        case .success:
            CheckResult(subject: .provider, outcome: .works, detail: String(localized: "Ответил."))
        case .failure(let error):
            CheckResult(subject: .provider, outcome: .broken, detail: error.localizedDescription)
        }
    }

    private func recognitionResult(_ phase: SpeechModelPhase) -> CheckResult {
        switch phase {
        case .ready:
            CheckResult(subject: .recognition, outcome: .works, detail: String(localized: "Готово."))
        case .failed(let message):
            CheckResult(subject: .recognition, outcome: .broken, detail: message)
        case .idle, .downloading, .loading:
            CheckResult(subject: .recognition, outcome: .noSound, detail: phase.summary)
        }
    }

    private func permissionsResult(_ granted: (microphone: Bool, screen: Bool)) -> CheckResult {
        switch (granted.microphone, granted.screen) {
        case (true, true):
            CheckResult(subject: .permissions, outcome: .works, detail: String(localized: "Микрофон и запись экрана разрешены."))
        case (false, true):
            CheckResult(subject: .permissions, outcome: .broken, detail: String(localized: "Нет доступа к микрофону — канал You будет пустым."))
        case (true, false):
            CheckResult(subject: .permissions, outcome: .broken, detail: String(localized: "Нет доступа к записи экрана — не будет ни скриншота, ни звука собеседника через ScreenCaptureKit."))
        case (false, false):
            CheckResult(subject: .permissions, outcome: .broken, detail: String(localized: "Нет доступа ни к микрофону, ни к записи экрана."))
        }
    }
}
