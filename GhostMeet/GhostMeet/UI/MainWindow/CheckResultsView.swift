//
//  CheckResultsView.swift
//  GhostMeet
//

import SwiftUI

/// The result of one connection check, five lines of it.
///
/// **Shown until the next check and no longer.** It describes a moment — sound
/// was arriving three seconds ago — and a panel that keeps saying so tomorrow
/// morning would be worse than none: it would be believed.
struct CheckResultsView: View {

    let results: [CheckResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(results) { result in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(for: result.outcome))
                        .foregroundStyle(colour(for: result.outcome))
                        .font(.system(size: 9))
                    Text(result.subject.title)
                        .font(.system(size: 10, weight: .medium))
                    Text(result.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Three shapes, not two colours: «звука не было» is neither a pass nor a
    /// failure, and a user glancing at the panel has to see that at once.
    private func symbol(for outcome: CheckResult.Outcome) -> String {
        switch outcome {
        case .works: "checkmark.circle.fill"
        case .noSound: "questionmark.circle.fill"
        case .broken: "exclamationmark.triangle.fill"
        }
    }

    private func colour(for outcome: CheckResult.Outcome) -> Color {
        switch outcome {
        case .works: .green
        case .noSound: .orange
        case .broken: .red
        }
    }
}
