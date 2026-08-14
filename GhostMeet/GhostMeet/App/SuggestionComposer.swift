//
//  SuggestionComposer.swift
//  GhostMeet
//

import Foundation

/// What the user asked for when they pressed.
///
/// Four cases and no more. Two of them are the **жанры** of the same request —
/// the suggestion about the conversation, short or long — and two are the modes
/// that answer something else: a sentence the user typed, and the task on screen.
///
/// The split into genres comes from what pressing means (ADR-0008): the user
/// presses because they do not know, do not remember or are unsure, and by then
/// they are already speaking. Most of the time what is missing is a term, a
/// number, three bullets — not an essay from the start. That is `brief`, and it
/// is the default press; `detailed` is for a subject that is unfamiliar whole.
nonisolated enum SuggestionAsk: Equatable, Sendable {

    /// Жанр «коротко» — the default press.
    case brief

    /// Жанр «подробно» — the full `Assist` answer.
    case detailed

    /// Mode `Ask`: a question the user typed.
    case question(String)

    /// Mode `Solve on screen`: the finished solution to the task on screen.
    case screenTask

    /// Whether the conversation is part of this request at all.
    ///
    /// Load-bearing rather than cosmetic: it decides whether a press waits for
    /// speech recognition still in flight. `Solve on screen` reads no transcript
    /// (see `SolvePrompt.readsTranscript`), so waiting there would be pure
    /// latency in the mode where latency hurts most — the cursor is in someone
    /// else's editor and the answer is the whole point.
    var readsTranscript: Bool {
        switch self {
        case .brief, .detailed, .question: true
        case .screenTask: false
        }
    }

    /// The same ask as the context layer records it on a `Подсказка`.
    ///
    /// The mapping lives here and only here, and the direction is the whole point:
    /// `App` knows about `Intelligence`, never the reverse (ADR-0001). Were
    /// `Suggestion` to hold a `SuggestionAsk` outright, the layer that stores what
    /// the model said would depend on the layer that decides which prompt to send
    /// it — and a saved call would stop being buildable without the prompts.
    ///
    /// Deliberately exhaustive rather than defaulted: a fifth thing to press for
    /// must not silently arrive in the file as one of the four already here.
    var kind: Suggestion.Kind {
        switch self {
        case .brief: .brief
        case .detailed: .detailed
        case .question(let text): .question(text)
        case .screenTask: .screenTask
        }
    }
}

/// Turns what the user asked for into a request a provider can take.
///
/// `SessionEngine` holds one of these instead of assembling prompts itself: how
/// many turns of transcript a mode reads, what it says to the model and how many
/// tokens it may spend are decisions of the prompt layer, and the engine must
/// stay unaware of them — the same way it stays unaware of which engine
/// recognised the speech (ADR-0001).
///
/// One seam and not two. Until ADR-0008 there were: an "automatic" composer for
/// the loop and a "manual" one for what the user pressed. With the loop gone
/// every suggestion starts from a press, and two protocols for one job would only
/// make each of them lie about which half it is.
///
/// It also keeps the pipeline testable at the one place that matters: a test can
/// watch what the engine asked for without a prompt of its own.
@MainActor
protocol SuggestionComposer {

    /// Builds the request for one suggestion.
    ///
    /// It cannot fail and it never refuses: an empty transcript is answered with
    /// a placeholder — or with the block left out entirely, where the prompt
    /// document guards it — and so is a screen that could not be grabbed, because
    /// a suggestion built from half the context is worth more than a window that
    /// stays silent.
    ///
    /// The screen arrives already captured rather than being fetched here: the
    /// engine starts it the instant the user presses, beside the wait for speech
    /// recognition, so its cost is hidden — and composing stays synchronous and
    /// pure.
    ///
    /// `capabilities` is what decides whether the picture may be attached at
    /// all. This is the layer that drops it — a screenshot handed to a text-only
    /// backend is a failed request, not a worse answer.
    func compose(
        _ ask: SuggestionAsk,
        transcript: [Turn],
        screen: ScreenContext,
        accepting capabilities: ProviderCapabilities
    ) -> SuggestionRequest
}

/// The composer the app actually runs.
///
/// It is the only place that knows which prompt each ask uses; the engine below
/// it knows only that the user asked for something, and the window above it knows
/// only that there are chords and a field. What it adds on top of the prompts is
/// the two things none of them owns — the selected `Профиль` and the
/// `Контекст собеседования` — and the decision of which half of the screen the
/// chosen backend is allowed to see.
struct PromptComposer: SuggestionComposer {

    /// Read anew on every request, so a profile edited mid-call reaches the next
    /// suggestion instead of the next launch. The profile belongs to the user,
    /// not to the call, and so survives clearing the context.
    private let profile: () -> UserProfile

    /// Read the same way and for the same reason: the заготовки are typed in
    /// before the call, live in user-scoped storage beside the profile, and a
    /// line added to them between two presses has to reach the second one.
    private let interviewContext: () -> InterviewContext

    init(
        profile: @escaping () -> UserProfile = { .empty },
        interviewContext: @escaping () -> InterviewContext = { .empty }
    ) {
        self.profile = profile
        self.interviewContext = interviewContext
    }

    func compose(
        _ ask: SuggestionAsk,
        transcript: [Turn],
        screen: ScreenContext,
        accepting capabilities: ProviderCapabilities
    ) -> SuggestionRequest {
        // The words on screen reach every backend, including the ones that cannot
        // take an image: for a local server or a CLI this is all they will ever
        // know about what the user is looking at. The picture only reaches a
        // backend that takes images, and `Solve on screen` degrades to reasoning
        // over the OCR text alone rather than failing — which is what
        // `ProviderCapabilities.acceptsImages` promises.
        let screenshot = capabilities.acceptsImages ? screen.image : nil

        switch ask {
        case .brief:
            return BriefPrompt.request(
                transcript: transcript,
                profile: profile(),
                interviewContext: interviewContext(),
                screenText: screen.text,
                screenshot: screenshot
            )
        case .detailed:
            return AssistPrompt.request(
                transcript: transcript,
                profile: profile(),
                interviewContext: interviewContext(),
                screenText: screen.text,
                screenshot: screenshot
            )
        case .question(let text):
            return AskPrompt.request(
                question: text,
                transcript: transcript,
                profile: profile(),
                interviewContext: interviewContext(),
                screenText: screen.text,
                screenshot: screenshot
            )
        case .screenTask:
            // Neither the transcript nor anything known about the user is passed,
            // and not merely windowed to zero: the mode answers the screen. The
            // conversation around a task is what turns a solution into a lecture,
            // and there is nobody to claim experience to — the answer goes into an
            // editor, not into a sentence said out loud (prompt document, note 5).
            return SolvePrompt.request(
                screenText: screen.text,
                screenshot: screenshot
            )
        }
    }
}
