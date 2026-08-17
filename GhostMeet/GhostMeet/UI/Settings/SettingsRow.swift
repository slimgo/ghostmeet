//
//  SettingsRow.swift
//  GhostMeet
//

import SwiftUI

/// Sizes shared by every row of the settings window.
///
/// One place, because the whole point is that rows agree with each other: a
/// column each row decides for itself is the column that was complained about.
enum SettingsMetrics {

    /// Width of the label column.
    ///
    /// Measured rather than guessed — `SettingsLayoutTests` renders every
    /// side-label and refuses a column that does not fit them with room to
    /// spare. The longest is «Активный профиль» at about 120 points; the rest of
    /// the width is headroom, and it is not decoration: the window is about to
    /// speak a second language, and a column fitted exactly to today's Russian
    /// would truncate on the first English string.
    ///
    /// Labels that genuinely do not belong in a column of any width — the
    /// interview-context fields, where «Вопросы к работодателю» alone asks for
    /// 161 points — are not stretched to fit. They are laid out differently; see
    /// `SettingsParagraphRow`.
    static let labelColumn: CGFloat = 150

    static let labelGap: CGFloat = 12

    /// The window's one size. Every page gets it, so switching tabs does not
    /// resize the window — the old form was as tall as the sum of nine sections,
    /// and a page is as tall as the tallest one.
    static let windowWidth: CGFloat = 540
    static let windowHeight: CGFloat = 620
}

/// One labelled row: the label on the left in a column of fixed width, the
/// control filling everything to the right of it.
///
/// **Both complaints about this window came from not having this.** `Form` with
/// `.formStyle(.grouped)` pushes labels to the *right* edge of their column,
/// because that is how a system settings pane looks — correct on two fields,
/// unreadable on nine sections. And a control inside a `Form` sizes itself to its
/// content, so the source picker was one width holding «Не выбрано» and another
/// holding «Google Chrome · звучит», and changed size under the user when the
/// backend changed the list.
///
/// Neither is a bug in a field; both are the layout deciding for itself. So the
/// layout is decided here instead, once.
struct SettingsRow<Control: View>: View {

    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.labelGap) {
            Text(title)
                .frame(width: SettingsMetrics.labelColumn, alignment: .leading)
            control
                // The control's own label is hidden rather than absent: a picker
                // built without one loses its accessibility name, and the screen
                // reader would announce an unnamed popup.
                .labelsHidden()
                // Left, and capped at the full width.
                //
                // Text fields take the whole of it, so they are all exactly as
                // wide as each other — those were the fields that visibly moved.
                // A pop-up button keeps its natural width, because that is what a
                // pop-up on macOS does and dropping `alignment:` only centres it
                // rather than stretching it — measured, not assumed. What matters
                // is that every control now *starts* at the same x and none of
                // them can push the label column around: the column is fixed, and
                // it was the column moving that made the form look like it was
                // jumping.
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// A labelled row whose label sits **above** the control rather than beside it.
///
/// For the fields that take a paragraph — the interview context, the profile's
/// experience and stack. Two reasons, and the first one is measured: their
/// labels are the long ones («Вопросы к работодателю» needs 161 points), so
/// beside a fixed column they would either truncate or force the column wide
/// enough to squeeze every other field on the screen. The second is that a
/// multi-line field with a single-line label pinned to its top-left corner reads
/// as misaligned no matter how wide the column is.
struct SettingsParagraphRow<Control: View>: View {

    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            control
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

extension View {

    /// Makes a control that has no label of its own occupy the full row.
    ///
    /// For the things that are a sentence rather than a value — a toggle, a row
    /// of buttons — where the label column would truncate the sentence and leave
    /// the control stranded on the other side of the window.
    func settingsFullWidth() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}
