//
//  AskBarView.swift
//  GhostMeet
//

import SwiftUI

/// The two ways the user reaches the model without waiting to be asked
/// something: a question typed into the field (`Ask`), and the button that
/// demands the task on screen be solved (`Solve on screen`).
///
/// It sits directly under the suggestion feed because that is where the answer
/// will appear — the question and its answer end up in one column, which is what
/// makes it obvious mid-call which card belongs to what was just typed.
///
/// Both are the same request as the chords make, entered from the window rather
/// than from the keyboard (ADR-0008): the transcript, the screen and the
/// lifecycle are identical, and the next press supersedes whatever was asked
/// here exactly as it supersedes an answer to a chord.
struct AskBarView: View {

    /// The session: where the question goes and what answers it.
    let session: SessionController

    /// The question being typed. Lives here rather than in the session: an
    /// unsent sentence is a state of the field, not of the call, and putting it
    /// in the session would redraw the whole overlay on every keystroke.
    @State private var question = ""

    var body: some View {
        HStack(spacing: 6) {
            field
            sendButton
            solveButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Ask

    /// Typing here is the one thing that takes the keyboard away from the call.
    ///
    /// It works because the panel is `becomesKeyOnlyIfNeeded` — it takes focus
    /// when a field is clicked directly and gives it back afterwards, so the
    /// overlay still never activates GhostMeet on its own.
    private var field: some View {
        TextField(String(localized: "Спросить модель…"), text: $question)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .onSubmit(send)
            .help(String(localized: "Вопрос про экран и разговор. Ответ появится в ленте подсказок; язык ответа — язык вопроса."))
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help(String(localized: "Спросить (Return)."))
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends the question and empties the field.
    ///
    /// Emptied on send rather than kept: the answer is on screen a moment later,
    /// and a field still holding the last question invites re-sending it by
    /// reflex. A blank field is refused by the engine, so Return on an empty box
    /// costs nothing.
    private func send() {
        guard canSend else { return }
        session.ask(question)
        question = ""
    }

    // MARK: - Solve on screen

    private var solveButton: some View {
        Button { session.solveOnScreen() } label: {
            Label(String(localized: "Решить"), systemImage: "wand.and.stars")
                .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .help(String(localized: "Решить задачу, которая сейчас на экране: подход, готовый код и сложность. Разговор при этом не читается."))
    }
}

#Preview {
    AskBarView(
        session: SessionController(engine: SessionEngine(), requestMicrophoneAccess: { false })
    )
    .frame(width: 420)
}
