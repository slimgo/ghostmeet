//
//  SessionIndicators.swift
//  GhostMeet
//

import Foundation

/// What one indicator is saying.
///
/// Five states and not three, because "слушает / думает / ошибка" leaves out the
/// two the user actually spends most of a call looking at: nothing is running
/// yet, and something is on its way. Collapsing either of them into "ошибка"
/// would cry wolf; collapsing them into "выключено" would hide a model that is
/// still downloading.
nonisolated enum IndicatorState: Equatable, Sendable {
    /// Nothing is happening, and nothing is wrong.
    case idle
    /// On its way, or waiting for something the user may have to provide.
    case waiting
    /// Audio is arriving on this channel.
    case listening
    /// The model is writing.
    case thinking
    /// Broken, with a reason the user can act on.
    case failed

    /// Whether this state has to be spelled out in the window rather than left
    /// in a tooltip.
    var deservesAnExplanation: Bool {
        self == .waiting || self == .failed
    }
}

/// One dot in the header: what it stands for, what it is doing, and why.
nonisolated struct Indicator: Equatable, Sendable, Identifiable {

    /// Stable id for `ForEach` — the channel name in lowercase Latin.
    let id: String
    /// What the user sees next to the dot.
    let name: String
    let state: IndicatorState
    /// One sentence, in the user's language, saying what that state means here.
    let detail: String
}

/// The state of a call as three dots.
///
/// Two of them are the channels, which by the glossary never mix and are never
/// summarised into one number. The third is the model: the `думает` state
/// belongs to it and not to either channel, and folding it into `Them` — the
/// channel whose turn started the generation — would report a working microphone
/// feed as busy and a failed request as a broken capture.
///
/// A value type computed from the session rather than state of its own, so the
/// rules can be checked without a window, a microphone, or a model.
///
/// Main-actor isolated, unlike `Indicator` itself: the wordings it assembles —
/// `ThemCaptureStatus.message`, `SessionController.Failure.message` — belong to
/// types that are, and this only ever runs while a window is being drawn.
struct SessionIndicators: Equatable, Sendable {

    let you: Indicator
    let them: Indicator
    let model: Indicator

    var all: [Indicator] { [you, them, model] }

    /// What to spell out in the window while a press is being prepared, or `nil`
    /// when there is nothing to say.
    ///
    /// A dot is not enough here, and this is the one place where that is worth a
    /// separate property. Between the press and the first token the app closes
    /// the open turn, waits for its words and takes a screenshot — up to
    /// `SessionEngine.recognitionBudget` in the worst case — while the user is on
    /// camera, looking at the interviewer, with a 420-point translucent window in
    /// the corner. If nothing visible changes, they conclude the chord missed and
    /// press again; the second press supersedes the first and starts the wait
    /// over, so the attempt to fix it exactly doubles it. ADR-0008 names that
    /// mistake as the expensive one.
    ///
    /// Only `.waiting` earns the block. A failure already arrives as a card in
    /// the feed, and saying it twice would be noise rather than emphasis.
    var preparationNotice: String? {
        model.state == .waiting ? model.detail : nil
    }

    static func make(
        isListening: Bool,
        failure: SessionController.Failure?,
        recognition: SpeechModelPhase,
        themStatus: ThemCaptureStatus,
        isPreparingAnswer: Bool = false,
        isGenerating: Bool,
        suggestionFailure: String?
    ) -> SessionIndicators {
        SessionIndicators(
            you: youIndicator(isListening: isListening, failure: failure, recognition: recognition),
            them: themIndicator(isListening: isListening, status: themStatus),
            model: modelIndicator(
                isListening: isListening,
                isPreparingAnswer: isPreparingAnswer,
                isGenerating: isGenerating,
                suggestionFailure: suggestionFailure
            )
        )
    }

    /// The microphone channel.
    ///
    /// A refusal outranks everything else: a denied microphone is the one state
    /// with a fix the user can carry out immediately, and it must not be hidden
    /// behind "модель готовится".
    private static func youIndicator(
        isListening: Bool,
        failure: SessionController.Failure?,
        recognition: SpeechModelPhase
    ) -> Indicator {
        if let failure {
            return Indicator(id: "you", name: "You", state: .failed, detail: failure.message)
        }
        if isListening {
            return Indicator(
                id: "you",
                name: "You",
                state: .listening,
                detail: String(localized: "Микрофон слушает — ваша речь пишется в канал You.")
            )
        }
        if let blocked = recognition.listeningBlockedReason {
            return Indicator(id: "you", name: "You", state: .waiting, detail: blocked)
        }
        return Indicator(
            id: "you",
            name: "You",
            state: .idle,
            detail: String(localized: "Прослушивание выключено. Нажмите «Слушать» или используйте хоткей.")
        )
    }

    /// The channel of everyone else, in the capture layer's own words.
    ///
    /// A broken capture is reported even while the session is stopped: it is
    /// usually a missing Screen Recording grant, and that is worth knowing
    /// *before* the call rather than during it.
    /// What a dead `Them` costs, said in front of the reason that caused it.
    ///
    /// **The reason alone is not enough, and that was measured the hard way.** On
    /// 15 August 2026 the stream broke a second after it started; the window did
    /// say «Произошел сбой трансляции из‑за прерванного подключения к
    /// приложению», and the user read straight past it — as anyone would, because
    /// nothing in that sentence says the transcript is now recording the
    /// interviewer under the user's own name. A system error message describes
    /// what the framework noticed. This describes what it costs, which is the
    /// half the user can act on.
    ///
    /// Added here rather than in each capture backend on purpose: a failure is
    /// published from several places, and a consequence written out at each of
    /// them is a consequence that goes missing at one of them.
    static let deafConsequence = String(localized: "Собеседника сейчас не слышно — его слова пишутся как ваша речь.")

    private static func themIndicator(isListening: Bool, status: ThemCaptureStatus) -> Indicator {
        if case .failed = status {
            // Пока звонок идёт, следствие важнее причины и потому стоит первым:
            // канал молчит, а транскрипт продолжает выглядеть правдоподобно.
            let detail = isListening
                ? "\(deafConsequence) \(status.message)"
                : status.message
            return Indicator(id: "them", name: "Them", state: .failed, detail: detail)
        }
        guard isListening else {
            return Indicator(
                id: "them",
                name: "Them",
                state: .idle,
                detail: String(localized: "Прослушивание выключено — звук собеседника не пишется.")
            )
        }
        switch status {
        case .capturing:
            return Indicator(id: "them", name: "Them", state: .listening, detail: status.message)
        case .idle, .waitingForSource, .restarting:
            // Восстановление — это ожидание, а не отказ: канал сейчас молчит, но
            // сам себя поднимает, и звать пользователя что-то делать не за чем.
            return Indicator(id: "them", name: "Them", state: .waiting, detail: status.message)
        case .failed:
            return Indicator(id: "them", name: "Them", state: .failed, detail: status.message)
        }
    }

    /// The model. `думает` lives here, and so does a request that came back
    /// empty — the suggestion feed shows the same reason, the dot is what makes
    /// it visible when the feed has scrolled.
    ///
    /// Preparation gets a state of its own rather than being folded into
    /// `думает`. It is the gap ADR-0008 accepts as the price of pressing — the
    /// tail of the question being recognised, the screen being grabbed — and it
    /// is the one second in which the user is most likely to decide the chord did
    /// not register and press again, throwing away the answer they are waiting
    /// for. Calling it «пишет» when nothing is being written would be a lie by a
    /// second, and this is the second that matters.
    private static func modelIndicator(
        isListening: Bool,
        isPreparingAnswer: Bool,
        isGenerating: Bool,
        suggestionFailure: String?
    ) -> Indicator {
        if isGenerating {
            return Indicator(
                id: "model",
                name: String(localized: "Модель"),
                state: .thinking,
                detail: String(localized: "Модель пишет подсказку.")
            )
        }
        if isPreparingAnswer {
            return Indicator(
                id: "model",
                name: String(localized: "Модель"),
                state: .waiting,
                detail: String(localized: "Нажатие принято — дозакрываю вопрос и снимаю экран.")
            )
        }
        if let suggestionFailure {
            return Indicator(id: "model", name: String(localized: "Модель"), state: .failed, detail: suggestionFailure)
        }
        return Indicator(
            id: "model",
            name: String(localized: "Модель"),
            state: .idle,
            detail: String(localized: "Подсказка приходит по нажатию хоткея — сама она не запускается.")
        )
    }
}
