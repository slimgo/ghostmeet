//
//  LLMProvider.swift
//  GhostMeet
//

import Foundation

/// One request to a model, already assembled: every mode-specific decision —
/// which prompt, how many turns of transcript, how many tokens — has been made
/// by the time a request exists.
///
/// The provider therefore knows nothing about modes, channels or the profile.
/// That is what lets a cloud provider, a local HTTP server and a CLI all sit
/// behind the same protocol (ADR-0001).
nonisolated struct SuggestionRequest: Equatable, Sendable {

    /// Role and rules. Carries the user's `Профиль` appended by the prompt
    /// builder, so the provider never assembles anything itself.
    var systemPrompt: String

    /// The assembled context: transcript window, question, OCR text.
    var userPrompt: String

    /// PNG bytes of the screen, attached to the *user* message.
    ///
    /// Nil when the provider does not take images at all, or when the capture
    /// failed — a suggestion without a screenshot beats no suggestion. The text
    /// recognised from the screen travels in `userPrompt` either way, so a
    /// text-only provider still knows what is on screen.
    var screenshot: Data?

    /// Budget for this mode. Say/Follow-up are cheap, Solve/Assist are not.
    var maxTokens: Int
}

/// A single swappable model backend.
///
/// Streaming is the only shape offered on purpose: the whole product promise is
/// that a suggestion starts appearing while the model is still writing it. A
/// provider that can only answer in one piece yields one fragment.
nonisolated protocol LLMProvider: Sendable {

    /// Human-readable name for the settings screen and for error messages.
    var name: String { get }

    /// What this backend accepts. Read *before* a request is assembled: a
    /// screenshot handed to a text-only model is a failed request, not a worse
    /// answer, and every press attaches one (ADR-0008).
    var capabilities: ProviderCapabilities { get }

    /// Streams the answer in fragments, in order.
    ///
    /// **Cancellation is part of the contract, not a nicety.** A new press
    /// supersedes the suggestion in flight (ADR-0008) — and only a press does;
    /// the interlocutor speaking cancels nothing any more — so cancelling the
    /// consuming task must actually abandon the HTTP request rather than let it
    /// run to completion in the background.
    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error>
}

/// Why an answer stopped before the model finished saying it.
///
/// **Separate from `LLMFailure` because it is not a failure.** The request went
/// out, the model replied, and what arrived is usable — it just is not the whole
/// thing. Reporting it as an error would throw away text the user can read;
/// reporting nothing at all is what the app did until now, and that is worse:
/// an answer cut mid-word is indistinguishable from a model that answered
/// briefly, so the user reads half a sentence out loud and finds out on air.
///
/// Measured on the bench: one run of seven came back cut at «setTimeout
/// (сет-тайм-аут) попада», with no usage and no closing event. Nothing in the
/// app noticed.
nonisolated enum SuggestionCutoff: Error, Equatable, Sendable {

    /// The model ran into `maxTokens`. The one case the user can act on — the
    /// budget belongs to the genre, and a detailed answer has eight times the
    /// room of a short one.
    case budget

    /// The stream ended without the provider ever closing it. A dropped
    /// connection, a gateway timing out, a proxy cutting an idle socket.
    case connection

    /// The stream closed properly and carried no answer at all. Reasoning models
    /// do this when the budget is spent on invisible tokens: HTTP 200, a
    /// well-formed stream, nothing to say.
    case empty

    /// The provider stopped the answer and said why — a moderation filter, a
    /// gateway error mid-stream, a CLI tool killed by a signal.
    ///
    /// **This is what a refusal becomes once any text has reached the screen**,
    /// and the conversion happens in one place: the read loop, which is the only
    /// thing that knows whether anything was delivered. Before it existed, a
    /// filter tripping on the last chunk replaced a half-read answer with an
    /// orange line — the card renders `.failed` *instead of* the text, and the
    /// user was reading that text out loud at the time.
    case stopped(String)

    var message: String {
        switch self {
        case .budget: String(localized: "Ответ оборван: модель упёрлась в лимит токенов. Для длинного ответа нажмите ⌥⌘E.")
        case .connection: String(localized: "Ответ оборван: соединение закрылось раньше, чем модель договорила.")
        case .empty: String(localized: "Модель вернула пустой ответ — попробуйте ещё раз или смените модель в настройках.")
        case .stopped(let reason): String(localized: "Ответ оборван. \(reason)")
        }
    }
}

/// Why a suggestion could not be produced, in words meant for the user.
///
/// Never surfaced as a system notification: the banner would be drawn over
/// whatever the user is sharing and give the app away (ADR-0004).
nonisolated enum LLMFailure: Error, Equatable, Sendable {
    /// No API key in the Keychain yet.
    case missingKey
    /// The provider refused the key.
    case unauthorized
    /// Rate limit or quota.
    case throttled
    /// Anything else, with the provider's own wording.
    case provider(String)

    var message: String {
        switch self {
        case .missingKey: String(localized: "Не задан ключ провайдера — откройте настройки.")
        case .unauthorized: String(localized: "Провайдер отклонил ключ.")
        case .throttled: String(localized: "Провайдер ограничил частоту запросов.")
        case .provider(let text): text
        }
    }
}
