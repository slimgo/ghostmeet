//
//  TranscriptView.swift
//  GhostMeet
//

import SwiftUI

/// The transcript: turns in the order they were closed, each with its channel
/// label and its length.
///
/// While recognition is stubbed a row shows the length only — that is what makes
/// the pause, silence and minimum-length thresholds checkable by eye.
struct TranscriptView: View {
    let turns: [Turn]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(turns) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .overlay {
                if turns.isEmpty { emptyState }
            }
            .onChange(of: turns.count) {
                guard let last = turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        Text(String(localized: "Пока тихо: ни одной реплики"))
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// One turn: who spoke, how long, and what was recognised.
private struct TurnRow: View {
    let turn: Turn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color, in: RoundedRectangle(cornerRadius: 4))
            Text(length)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(turn.text.isEmpty ? "—" : turn.text)
                .font(.body)
                .foregroundStyle(turn.text.isEmpty || turn.isLeak ? .secondary : .primary)
                .strikethrough(turn.isLeak)
                .textSelection(.enabled)
            if turn.isLeak {
                // The one place the mark is visible. Without it a leak that the
                // model never sees would still read here as the user's own
                // sentence — silent corruption of the transcript, which is the
                // failure this whole layer exists to prevent.
                Text(String(localized: "протечка"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Channels keep their names as they are: `You` and `Them`.
    private var label: String {
        switch turn.channel {
        case .you: return "You"
        case .them: return "Them"
        }
    }

    private var color: Color {
        switch turn.channel {
        case .you: return .accentColor
        case .them: return .purple
        }
    }

    private var length: String {
        String(format: String(localized: "%.2f с"), turn.duration)
    }
}

#Preview {
    TranscriptView(turns: [
        Turn(channel: .you, timestamp: 0, duration: 1.24),
        Turn(channel: .them, text: String(localized: "Расскажите, как вы решали эту задачу?"), timestamp: 3.1, duration: 2.75),
        Turn(channel: .you, timestamp: 7.4, duration: 10),
    ])
    .frame(width: 420, height: 240)
}
