//
//  SuggestionFeedView.swift
//  GhostMeet
//

import SwiftUI

/// The feed of suggestions, oldest first.
///
/// The newest one is the answer to the question just asked, so the feed scrolls
/// to it and marks it out: during a call there is no time to look for it. Older
/// ones stay readable but recede, which is what makes the feed a history the
/// user can scroll back through rather than a single replaced answer.
///
/// A suggestion that could not be produced is shown here as a card like any
/// other. This window is the only place a failure is ever reported — a system
/// banner would be drawn over the shared screen and give the app away (ADR-0004).
/// The same failure happening again does not get a second card — see
/// `SuggestionFeedEntry`.
struct SuggestionFeedView: View {
    let suggestions: [Suggestion]

    /// What is actually drawn: one card per suggestion, except for a failure that
    /// keeps repeating for the same reason.
    private var entries: [SuggestionFeedEntry] {
        SuggestionFeedEntry.feed(of: suggestions)
    }

    var body: some View {
        // Folded once per redraw, not once per row: `entries` walks the whole
        // feed, and asking it for `last` inside the loop would make drawing the
        // feed quadratic in the length of the call.
        let entries = entries
        let latest = entries.last?.id

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        SuggestionCard(
                            suggestion: entry.suggestion,
                            repeats: entry.repeats,
                            isLatest: entry.id == latest
                        )
                        .id(entry.id)
                    }
                    // Anchor at the very bottom: scrolling to the card itself
                    // stops short while the card is still growing.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .overlay {
                if suggestions.isEmpty { emptyState }
            }
            // A new suggestion is worth an animation; the fragments that follow
            // are not — animating every one of them would make the text jitter
            // while it is being read.
            .onChange(of: suggestions.last?.id) {
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: suggestions.last?.text.count ?? 0) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "suggestion-feed-bottom"

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(String(localized: "Подсказок пока нет"))
                .font(.callout)
            Text(String(localized: "Нажмите хоткей, когда понадобится: сама подсказка не приходит."))
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }
}

/// One suggestion: what the model wrote, and where it got to.
private struct SuggestionCard: View {
    let suggestion: Suggestion

    /// How many identical failures this card stands for — `1` for anything the
    /// user normally sees.
    let repeats: Int

    /// The newest card, the one the user is meant to be reading right now.
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine
            // Above the answer and not below it: it says what the answer was
            // built from, and read afterwards it would only explain a
            // disappointment the user has already had.
            if let notice = suggestion.notice { noticeLine(notice) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background)
        .overlay(border)
        .opacity(isLatest ? 1 : 0.65)
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(statusTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // The count is the whole of what a repeat adds. Without it a second
            // press that failed for the same reason changes nothing on screen,
            // and a press that changes nothing reads as a press that never
            // registered — which is the mistake ADR-0008 makes expensive.
            if repeats > 1 {
                Text("×\(repeats)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .help(repeatsHelp)
            }

            Spacer(minLength: 0)
        }
    }

    private var repeatsHelp: String {
        String(localized: "Одна и та же ошибка подряд \(repeats) \(Self.times(repeats)). Показана один раз — пока причина не изменилась, повторять её нечем.")
    }

    /// «2 раза», «5 раз»: a count in the window has to read as Russian, and the
    /// user is going to see this one on the day nothing works.
    private static func times(_ count: Int) -> String {
        if (11...14).contains(count % 100) { return String(localized: "раз") }
        return (2...4).contains(count % 10) ? String(localized: "раза") : String(localized: "раз")
    }

    private var statusTitle: String {
        switch suggestion.state {
        case .streaming: String(localized: "печатается")
        case .complete: String(localized: "подсказка")
        case .superseded: String(localized: "устарела")
        case .cut: String(localized: "оборвана")
        case .failed: String(localized: "не получилось")
        }
    }

    private var statusColor: Color {
        switch suggestion.state {
        case .streaming: .accentColor
        case .complete: isLatest ? .accentColor : .secondary
        case .superseded: .secondary
        // The same yellow as a failure, but a different heading: the answer is
        // there and can be read aloud, it simply was not finished.
        case .cut: .orange
        case .failed: .orange
        }
    }

    // MARK: - Notice

    /// A circumstance the answer was produced under — not a failure, so not
    /// orange and not an exclamation mark. The user pressed and is getting an
    /// answer; this only says which half of the input it had.
    private func noticeLine(_ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch suggestion.state {
        case .failed(let message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)

        default:
            if suggestion.text.isEmpty {
                Text("…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                // Re-laid out on every fragment rather than once at the end: the
                // markup has to grow with the text, not replace it (ADR-0008 buys
                // its second of latency back on the first line arriving early).
                SuggestionMarkupView(text: suggestion.text)
            }
            // The reason for the cut-off goes BELOW the text rather than in its
            // place: half an answer can still be read aloud and is worth seeing,
            // and the line explains why the sentence stopped mid-word.
            if case .cut(let reason) = suggestion.state {
                cutLine(reason)
            }
        }
    }

    /// Why the answer ended before the model had finished.
    ///
    /// Not `noticeLine`: that one speaks about the conditions the answer was
    /// composed under and stands above it. This line is about the answer itself
    /// and stands below it.
    private func cutLine(_ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "scissors")
        }
        .font(.system(size: 10))
        .foregroundStyle(.orange)
    }

    // MARK: - Chrome

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isLatest ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                isLatest ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                lineWidth: 1
            )
    }
}

#Preview {
    SuggestionFeedView(suggestions: [
        Suggestion(
            text: """
            Я вёл миграцию сервиса на **Swift Concurrency**: убрал GCD-очереди, вынес состояние в акторы.

            - `DispatchQueue` → `actor`
            - колбэки → `async/await`

            ```swift
            actor TranscriptStore { private(set) var turns: [Turn] = [] }
            ```
            """,
            state: .complete,
            startedAt: Date()
        ),
        // Three identical failures in a row show as one card marked «×3».
        Suggestion(state: .failed(LLMFailure.missingKey.message), startedAt: Date()),
        Suggestion(state: .failed(LLMFailure.missingKey.message), startedAt: Date()),
        Suggestion(state: .failed(LLMFailure.missingKey.message), startedAt: Date()),
        Suggestion(text: String(localized: "Начну с оценки сложности: сейчас это O(n²), потому что `contains` внутри"), startedAt: Date()),
    ])
    .frame(width: 420, height: 420)
}
