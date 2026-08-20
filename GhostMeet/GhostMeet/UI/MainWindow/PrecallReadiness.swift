//
//  PrecallReadiness.swift
//  GhostMeet
//

import AppKit
import Foundation

/// One field of the readiness strip: a single thing the user goes into the call
/// armed with, in as few words as fit.
///
/// Deliberately shaped like `Indicator` and deliberately not one. The dots in
/// the header answer «что происходит сейчас» — a channel that is capturing, a
/// model that is writing — and every one of them goes grey the moment the
/// session is stopped, which is exactly when this strip has to speak. This
/// answers the other question, «чем я вооружён», and it is a statement about
/// settings rather than about a session: nothing in it changes when the user
/// presses «Слушать».
nonisolated struct ReadinessItem: Equatable, Sendable, Identifiable {

    /// Stable id for `ForEach` — what the field names, in lowercase Latin.
    let id: String

    /// SF Symbol drawn before the value.
    let icon: String

    /// What the user reads in the strip. Short on purpose: three of these share
    /// one line of a window 420 points wide.
    let value: String

    /// One sentence saying what that value means and what a click does with it.
    let detail: String

    /// Where a click on this field goes. Not always the field's own section: a
    /// provider whose key is missing sends the user to the key, because that is
    /// what `detail` just promised and what actually has to be filled in.
    let target: SettingsSection

    /// Whether this is a gap rather than a choice — no source picked, no key
    /// stored, an empty profile. Gaps are the reason the strip exists: left to
    /// itself, every one of them is discovered in the first minute of the call.
    let isMissing: Bool
}

/// What the user is armed with, as three short fields: which `Профиль` speaks,
/// which model answers, which `Приложение-источник` is listened to.
///
/// A value type computed from the settings on every redraw, like
/// `SessionIndicators` — so the strip cannot show a provider the next request
/// will not use, and so the whole thing can be checked without a window.
struct PrecallReadiness: Equatable, Sendable {

    let profile: ReadinessItem
    let provider: ReadinessItem
    let source: ReadinessItem

    var all: [ReadinessItem] { [profile, provider, source] }

    /// Built from the store itself rather than from anything handed in, which is
    /// what makes «фактические значения, а не заглушки» a property of the type
    /// instead of a promise about the caller.
    ///
    /// `applicationName` is the one seam: turning a bundle identifier into
    /// «Google Chrome» means asking the system what is running, and a test must
    /// be able to answer that question itself.
    static func make(
        settings: SettingsStore,
        applicationName: (String) -> String? = { runningApplicationName(forID: $0) }
    ) -> PrecallReadiness {
        PrecallReadiness(
            profile: profileItem(settings),
            provider: providerItem(settings),
            source: sourceItem(settings, applicationName: applicationName)
        )
    }

    // MARK: - The profile

    /// The `Активный профиль` — the one, and only one, that reaches the prompt.
    ///
    /// An empty profile counts as a gap even though the app is perfectly able to
    /// answer without one: suggestions then come from a person with no history,
    /// which on an interview is the failure the profile exists to prevent.
    private static func profileItem(_ settings: SettingsStore) -> ReadinessItem {
        let profile = settings.profile
        let name = profile.displayName
        guard !profile.isEmpty else {
            return ReadinessItem(
                id: "profile",
                icon: "person.crop.circle.badge.exclamationmark",
                value: name,
                detail: String(localized: "Профиль «\(name)» пуст: ни роли, ни опыта, ни стека. Подсказки будут говорить за человека вообще, а не за вас. Заполните его в настройках или загрузите резюме."),
                target: .profile,
                isMissing: true
            )
        }
        let role = profile.role.trimmed
        return ReadinessItem(
            id: "profile",
            icon: "person.crop.circle",
            value: name,
            detail: role.isEmpty
                ? String(localized: "Активный профиль: «\(name)». Подсказки идут от лица этого опыта. Нажмите, чтобы выбрать другой — сменится к следующей подсказке.")
                : String(localized: "Активный профиль: «\(name)» — \(role). Подсказки идут от лица этого опыта. Нажмите, чтобы выбрать другой — сменится к следующей подсказке."),
            target: .profile,
            isMissing: false
        )
    }

    // MARK: - The provider

    /// Who answers, and on what. Both halves, because either one alone is a
    /// half-truth: «Anthropic» says nothing about which Claude, and a bare model
    /// id says nothing about whose servers it is reached through.
    private static func providerItem(_ settings: SettingsStore) -> ReadinessItem {
        let preset = settings.providerPreset
        let model = effectiveModel(preset: preset, selection: settings.providerSelection)
        let value = model.isEmpty ? preset.name : "\(preset.name) · \(model)"

        // A selection that cannot be built outranks a missing key: the session
        // is running on the previous provider, so what the strip would otherwise
        // show is not what would answer.
        if let error = settings.providerConfigurationError {
            return ReadinessItem(
                id: "provider",
                icon: "exclamationmark.triangle",
                value: value,
                detail: String(localized: "Провайдер настроен неверно: \(error) Отвечает пока предыдущий — или никто. Нажмите, чтобы поправить."),
                target: .provider,
                isMissing: true
            )
        }
        if settings.providerRequiresKey, !settings.hasProviderKey {
            return ReadinessItem(
                id: "provider",
                icon: "key",
                value: value,
                detail: String(localized: "Ключ для «\(preset.name)» не задан — первая же подсказка вернётся ошибкой. Нажмите, чтобы вписать ключ в настройках."),
                // The key and not the provider: the sentence above names the one
                // field that has to be filled in, and a click that stops one
                // section short of it makes a liar of it.
                target: .providerKey,
                isMissing: true
            )
        }
        return ReadinessItem(
            id: "provider",
            icon: "brain",
            value: value,
            detail: summary(preset: preset, model: model),
            target: .provider,
            isMissing: false
        )
    }

    private static func summary(preset: ProviderPreset, model: String) -> String {
        let head: String
        switch preset.transport {
        case .cli:
            head = model.isEmpty
                ? String(localized: "Отвечает \(preset.name).")
                : String(localized: "Отвечает \(preset.name), команда «\(model)».")
        case .anthropic, .openAICompatible, .gemini:
            head = model.isEmpty
                ? String(localized: "Отвечает \(preset.name).")
                : String(localized: "Отвечает \(preset.name), модель \(model).")
        }
        return head + String(localized: " Нажмите, чтобы сменить провайдера или модель — новый ответит уже на следующую подсказку.")
    }

    /// The model the next request will actually name: the user's override when
    /// they typed one, the preset's own otherwise.
    ///
    /// For a CLI tool the equivalent fact is the command, because that is what
    /// decides which tool — and which subscription — answers; the model field is
    /// ignored by that transport altogether.
    static func effectiveModel(preset: ProviderPreset, selection: ProviderSelection) -> String {
        switch preset.transport {
        case .cli:
            let override = selection.commandOverride.trimmed
            return override.isEmpty ? preset.command.joined(separator: " ") : override
        case .anthropic, .openAICompatible, .gemini:
            let override = selection.model.trimmed
            return override.isEmpty ? preset.defaultModel : override
        }
    }

    // MARK: - The source application

    /// Which application the `Them` channel is pointed at — and, when none has
    /// been picked, that fact stated before the call rather than during it.
    ///
    /// Not a duplicate of the `Them` dot: the dot reports what capture is doing
    /// and reads «прослушивание выключено» while the session is stopped, which
    /// is the whole of the time this line is looked at.
    private static func sourceItem(
        _ settings: SettingsStore,
        applicationName: (String) -> String?
    ) -> ReadinessItem {
        let backend = settings.themCaptureBackend.displayName
        let stored = (settings.themSourceApplicationID ?? "").trimmed
        guard !stored.isEmpty else {
            return ReadinessItem(
                id: "source",
                icon: "speaker.slash",
                value: String(localized: "источник не выбран"),
                detail: String(localized: "Приложение-источник не выбрано — канал Them будет молчать весь звонок, и собеседника модель не услышит. Нажмите, чтобы выбрать браузер со звонком."),
                target: .sourceApplication,
                isMissing: true
            )
        }
        let name = applicationName(stored) ?? derivedName(fromID: stored)
        return ReadinessItem(
            id: "source",
            icon: "speaker.wave.2",
            value: name,
            detail: String(localized: "Источник канала Them — «\(name)», через \(backend). Звук берётся с приложения целиком: всё, что играет в нём же, попадёт в Them. Нажмите, чтобы выбрать другое."),
            target: .sourceApplication,
            isMissing: false
        )
    }

    /// What the system calls the application stored under this id, if it is
    /// running right now.
    ///
    /// A best effort by design: the browser is usually already open before an
    /// interview, and «Brave Browser» reads better than the identifier it was
    /// remembered by. When it is not running the name is derived from the id
    /// instead — a strip that goes blank because the call app has not been
    /// launched yet would be useless at exactly the moment it is read.
    static func runningApplicationName(forID id: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .compactMap(\.localizedName)
            .first
    }

    /// A readable name taken from the stored id alone: `com.google.Chrome` →
    /// `Chrome`, `/Applications/Foo.app` → `Foo`.
    ///
    /// Both shapes occur, because a process belonging to no application bundle
    /// is remembered by its path — see `AudioProcess.fallbackIdentity`.
    static func derivedName(fromID id: String) -> String {
        if id.contains("/") {
            let last = (id as NSString).lastPathComponent
            let bare = last.hasSuffix(".app") ? String(last.dropLast(4)) : last
            return bare.isEmpty ? id : bare
        }
        guard let tail = id.split(separator: ".").last, !tail.isEmpty else { return id }
        return String(tail)
    }
}

private extension String {
    nonisolated var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
