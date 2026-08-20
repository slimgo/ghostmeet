//
//  Suggestion.swift
//  GhostMeet
//

import Foundation

/// What the model produced for the user: a line to say out loud, a solution to
/// the task on screen, or a recap.
///
/// A `Подсказка` is always addressed to the user and never leaves for the call.
/// It arrives in fragments while the model writes, so it exists on screen long
/// before it is finished — `text` grows and `state` settles.
nonisolated struct Suggestion: Identifiable, Equatable, Sendable {

    /// Вид подсказки: which of the four things a `Нажатие` may ask for produced
    /// this one.
    ///
    /// **Not the same as `Жанр подсказки`, and the difference is the reason this
    /// type is not called a genre.** Genres are two — коротко and подробно, the
    /// same request in two sizes. Kinds are four: the two genres plus `Ask` and
    /// `Solve on screen`, which answer something else entirely. `Solve on screen`
    /// reads no conversation at all, so a card carrying it is not a short answer
    /// to the call — it is an answer to a different question.
    ///
    /// **A mirror of `SuggestionAsk`, deliberately.** The original lives in the
    /// App layer beside the composer, because deciding which prompt an ask uses is
    /// the prompt layer's business. This layer holds a value of its own and `App`
    /// maps into it; the arrow may not point the other way, or the context layer
    /// would learn what a prompt is (ADR-0001).
    ///
    /// `question` carries the text the user typed rather than just marking the
    /// mode. In a saved call «Ask: почему не Mongo?» is worth more than «Ask»: the
    /// answer below it is unreadable without knowing what was asked, and unlike a
    /// genre press there is no `Them` turn above it that would say.
    nonisolated enum Kind: Equatable, Sendable {
        /// Жанр «коротко» — the default press.
        case brief
        /// The «подробно» genre.
        case detailed
        /// Mode `Ask`, with the question the user typed.
        case question(String)
        /// Mode `Solve on screen`.
        case screenTask
    }

    nonisolated enum State: Equatable, Sendable {
        /// The model is still writing. `text` keeps growing.
        case streaming
        /// The model finished on its own.
        case complete
        /// The user pressed again and this one stopped being the answer they are
        /// waiting for (ADR-0008). Whatever arrived stays on screen — the feed
        /// keeps history — but nothing more will be appended.
        case superseded
        /// The model stopped before finishing. **Not a failure:** the text that
        /// arrived is on screen and readable, and the reason stands under it.
        ///
        /// A separate state and not `.failed` because the user does different
        /// things with them. A failure means there is nothing to say and the
        /// press is to be repeated; a cut answer is half of a usable one, said
        /// out loud as far as it goes while the rest is asked for again.
        case cut(String)
        /// It could not be produced. Shown inside the overlay window only.
        case failed(String)
    }

    let id: UUID

    /// Grows fragment by fragment while `state` is `.streaming`.
    var text: String

    var state: State

    /// What the user has to know about this answer before reading it, or `nil`
    /// when there is nothing to say.
    ///
    /// Not an error and not part of the answer: the request went out, the model
    /// replied, and something about the circumstances makes the reply narrower
    /// than the user expects. So far there is one such circumstance — a press
    /// made while nothing is being captured — and it deserves a sentence rather
    /// than a refusal, because the answer is still useful and refusing mid-
    /// interview would be worse than a thin answer.
    let notice: String?

    /// When generation started, for ordering in the feed.
    let startedAt: Date

    /// What the press asked for, or `nil` when nobody said.
    ///
    /// Optional because it is a record and not a requirement: a `Подсказка` is
    /// whole without it — it has text, a state and a time — and every test that
    /// builds one to check the feed would otherwise have to name a kind it does
    /// not care about. The app itself always fills it in.
    let kind: Kind?

    init(
        id: UUID = UUID(),
        text: String = "",
        state: State = .streaming,
        notice: String? = nil,
        startedAt: Date,
        kind: Kind? = nil
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.notice = notice
        self.startedAt = startedAt
        self.kind = kind
    }

    /// Whether anything more may still be appended.
    var isSettled: Bool {
        state != .streaming
    }
}
