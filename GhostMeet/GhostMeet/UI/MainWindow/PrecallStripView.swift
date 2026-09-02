//
//  PrecallStripView.swift
//  GhostMeet
//

import SwiftUI

/// The readiness strip: one line under the indicators saying what the user goes
/// into the call armed with — which `Профиль` speaks, which model answers, which
/// `Приложение-источник` is listened to — and letting the profile be swapped
/// without opening settings.
///
/// **One line, and only one.** The suggestion feed is what this window is for,
/// and a readiness *panel* would take its space every second of the call to
/// answer a question asked once, before it. So: 10-point text, no headings, no
/// second row, values truncated rather than wrapped, and the whole sentence
/// behind the tooltip.
///
/// **It does not repeat the dots above it.** Those report what is happening now
/// — this channel is capturing, the model is writing — and all three of them are
/// grey while the session is stopped, which is precisely when this line is read.
/// The strip reports configuration instead, and configuration is exactly what
/// the dots go quiet about: `Them` says «прослушивание выключено» whether or not
/// a source application was ever picked, and no dot has ever known that the
/// provider key is missing.
///
/// Nothing here activates GhostMeet. The menu is a menu, the two links are plain
/// buttons, and none of them wants the keyboard — the panel is
/// `becomesKeyOnlyIfNeeded`, so the focus stays in the call window.
struct PrecallStripView: View {

    /// The settings themselves, read live: switching a profile has to reach the
    /// next suggestion, and re-reading the store on every redraw is the whole
    /// mechanism (`SettingsStore` is observable).
    let settings: SettingsStore

    /// Where the provider and the source send the user — and to which section of
    /// the settings screen. In accessory mode the overlay owns the only door
    /// into settings, and a door that opens on a form of seven sections is only
    /// half of what this line promised.
    let openSettings: OpenSettings

    var body: some View {
        let readiness = PrecallReadiness.make(settings: settings)
        HStack(spacing: 5) {
            profileMenu(readiness.profile)
            separator
            languageMenu
            separator
            settingsLink(readiness.provider)
            separator
            settingsLink(readiness.source)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }

    // MARK: - The profile

    /// The one control in the strip: the `Активный профиль`, swapped in a click.
    ///
    /// A menu rather than a cycling button, because the user has two or three
    /// profiles and needs the *right* one, not the next one — and because the
    /// check mark next to the current entry is the confirmation the strip exists
    /// to give. Selecting writes straight through to the store, so the change is
    /// in force for the next suggestion without a restart of anything: the
    /// composers read `SettingsStore.profile` at request time.
    private func profileMenu(_ item: ReadinessItem) -> some View {
        Menu {
            ForEach(settings.profiles) { profile in
                Button { settings.selectProfile(profile.id) } label: {
                    if profile.id == settings.selectedProfileID {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
            Divider()
            Button("Профили и резюме…") { openSettings(.profile) }
        } label: {
            label(for: item)
        }
        .menuStyle(.borderlessButton)
        // Deliberately *not* `fixedSize()`: a profile the user called
        // «Синьор фулстек, финтех, платежи» would then refuse to shrink and
        // push the provider and the source off the line. Truncating a name the
        // user chose is a smaller loss than losing the other two fields.
        .help(item.detail)
        .accessibilityLabel(item.detail)
    }

    // MARK: - The language of the call

    /// The interview's language, declared before the call rather than guessed.
    ///
    /// It sits here and not in settings because it belongs to *this call*, like
    /// the profile beside it — the same person interviews in Russian on Monday
    /// and in English on Tuesday, and neither is a property of the machine.
    ///
    /// Auto is the default and reads the transcript, which is enough to decide
    /// the pronunciation rule and was measured not to be enough to decide the
    /// answer's language: against 96 % Cyrillic in the assembled prompt, a model
    /// answers in the language of its instructions.
    private var languageMenu: some View {
        Menu {
            ForEach(InterviewLanguage.allCases, id: \.self) { language in
                Button {
                    settings.interviewLanguage = language
                } label: {
                    if language == settings.interviewLanguage {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 9))
                Text(settings.interviewLanguage.displayName)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(settings.interviewLanguage.explanation)
        .accessibilityLabel(settings.interviewLanguage.explanation)
    }

    // MARK: - Provider and source

    /// A fact plus the way to change it. Both of these live in settings and
    /// nowhere else, so the strip states them and hands over — to the section
    /// the field's own tooltip named, `item.target`.
    private func settingsLink(_ item: ReadinessItem) -> some View {
        Button { openSettings(item.target) } label: {
            label(for: item)
        }
        .buttonStyle(.plain)
        .help(item.detail)
        .accessibilityLabel(item.detail)
    }

    /// Icon plus value, in the one colour decision this line makes: orange for a
    /// gap, secondary for everything else. A gap has to be visible at a glance —
    /// that is the whole point — without becoming a fourth indicator.
    private func label(for item: ReadinessItem) -> some View {
        Label {
            Text(item.value)
        } icon: {
            Image(systemName: item.icon)
        }
        .font(.system(size: 10))
        .foregroundStyle(item.isMissing ? Color.orange : Color.secondary)
    }
}

#Preview {
    // A throwaway suite: previewing must not rewrite the user's own profiles.
    let settings = SettingsStore(
        defaults: UserDefaults(suiteName: "GhostMeetPrecallStripPreview") ?? .standard,
        secrets: InMemorySecretStore()
    )
    return PrecallStripView(settings: settings, openSettings: { _ in })
        .padding()
        .frame(width: 420)
}
