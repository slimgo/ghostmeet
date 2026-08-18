//
//  HotkeysSectionView.swift
//  GhostMeet
//

import SwiftUI

/// Where the user re-binds the global chords.
///
/// Deliberately without a number: it has been wrong twice already — the list
/// went from four to five to seven, and the sentence stayed.
///
/// It lives in the overlay and not in the settings window because the overlay is
/// the window that is on screen when a chord turns out to be wrong — and because
/// a chord that another application has taken is only discovered by pressing it.
/// Collapsed by default: mid-call the window has to stay small.
///
/// The chords are picked from a list rather than recorded by pressing them. The
/// overlay is a `.nonactivatingPanel` that deliberately refuses the keyboard
/// focus — that refusal is what keeps typing in the call working — so it is the
/// one window in the app that cannot reliably read a key press.
struct HotkeysSectionView: View {

    let hotkeys: HotkeyCenter

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(HotkeyAction.allCases) { action in
                    row(for: action)
                }

                Button(String(localized: "Вернуть комбинации по умолчанию")) { hotkeys.resetToDefaults() }
                    .controlSize(.small)
                    .font(.system(size: 10))
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "command")
                    .font(.system(size: 9))
                Text(String(localized: "Хоткеи"))
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
                if hasProblem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private var hasProblem: Bool {
        HotkeyAction.allCases.contains { hotkeys.problem(with: $0) != nil }
    }

    @ViewBuilder
    private func row(for action: HotkeyAction) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(action.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Picker("", selection: binding(for: action)) {
                    Text(String(localized: "Выключено")).tag(Hotkey?.none)
                    ForEach(options(for: action), id: \.self) { hotkey in
                        Text(hotkey.displayString).tag(Hotkey?.some(hotkey))
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 108)
            }

            Text(action.summary)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = hotkeys.problem(with: action) {
                Text(problem)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(for action: HotkeyAction) -> Binding<Hotkey?> {
        Binding(
            get: { hotkeys.bindings[action] },
            set: { hotkeys.rebind(action, to: $0) }
        )
    }

    /// The offered chords, with whatever is bound right now always among them —
    /// a preference file carried over from another machine may name a chord this
    /// version no longer suggests, and the picker must not silently drop it.
    private func options(for action: HotkeyAction) -> [Hotkey] {
        var chords = action.candidates
        if let current = hotkeys.bindings[action], !chords.contains(current) {
            chords.insert(current, at: 0)
        }
        return chords
    }
}
