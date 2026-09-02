//
//  SettingsStore.swift
//  GhostMeet
//

import Foundation
import Observation

/// Keychain accounts used by the app. Only provider keys ever go here.
nonisolated enum SecretAccount {

    /// Account holding the API key of **one** provider.
    ///
    /// Keyed by `ProviderPreset.id` on purpose. A single shared account would
    /// mean that switching from OpenAI to Anthropic overwrote the key left
    /// behind, and switching back would silently ask for it again — a keychain
    /// entry per provider is what lets several of them lie side by side.
    static func llmProviderKey(presetID: String) -> String {
        "llm.provider.\(presetID).api-key"
    }

    /// The one account used before keys became per-provider. Read once at
    /// startup and moved onto the selected provider, so that upgrading the app
    /// does not look like the key vanished.
    static let legacyLLMProviderKey = "llm.provider.api-key"
}

/// User-scoped settings: the user's profiles and the turn-segmentation
/// thresholds.
///
/// Two invariants shape this type:
///
/// 1. **No secrets.** The provider key is never stored here, never cached in a
///    property, never written to `UserDefaults` and never put into a
///    description. It is read from, and written to, the `SecretStore` on
///    demand; the store only remembers *whether* one exists.
/// 2. **No session state.** Everything here belongs to the user, not to a call.
///    Clearing the conversation context resets `SessionEngine`'s transcript and
///    never reaches this store, which is what lets the profile outlive it.
///
/// The type is observable, so a change made in the settings screen is picked up
/// by the engine and the UI immediately — no restart, no "Apply" button.
@MainActor
@Observable
final class SettingsStore {

    /// Shared instance backed by the real keychain and the standard defaults.
    static let shared = SettingsStore()

    private enum DefaultsKey {
        static let profileLibrary = "settings.profileLibrary"
        /// The key of the build that kept exactly one profile. Read once, at
        /// startup, and turned into a library — see `migratedLibrary(from:)`.
        static let legacyProfile = "settings.userProfile"
        static let interviewContext = "settings.interviewContext"
        static let turnSegmentation = "settings.turnSegmentation"
        /// Which retired defaults have already been replaced in the stored
        /// thresholds — see `TurnSegmentationMigration`. Absent means "written
        /// before ADR-0008".
        static let turnSegmentationVersion = "settings.turnSegmentation.version"
        static let speechModel = "settings.speechModel"
        static let speechEngine = "settings.speechEngine"
        static let interviewLanguage = "settings.interviewLanguage"
        static let microphoneUID = "settings.microphoneUID"
        static let themSourceApplication = "settings.themSourceApplication"
        static let themCaptureBackend = "settings.themCaptureBackend"
        static let providerSelection = "settings.providerSelection"
        static let hotkeys = "settings.hotkeys"
        static let checksForUpdates = "settings.checksForUpdates"
    }

    // MARK: - Persisted, user-scoped state

    /// Every profile the user keeps, and which one is in force. Survives both
    /// app restarts and clearing the conversation context.
    ///
    /// The list is here rather than in session state for the same reason the
    /// single profile always was: it belongs to the user. What is new is that
    /// the *choice* between them is made per call — «сейчас я иду на интервью
    /// тимлида» — and is therefore the one thing on this screen that also has
    /// to be reachable from the overlay, in one click, without opening
    /// settings.
    private(set) var profileLibrary: ProfileLibrary {
        didSet { persist(profileLibrary, forKey: DefaultsKey.profileLibrary) }
    }

    /// The profiles, in the order the user arranged them. Read-only: every
    /// change goes through a method, so both library invariants hold.
    var profiles: [UserProfile] { profileLibrary.profiles }

    /// Which profile is in force. Assigning it is the one-click switch the
    /// overlay makes before a call.
    var selectedProfileID: UserProfile.ID {
        get { profileLibrary.selectedID }
        set { profileLibrary.select(newValue) }
    }

    /// Standing facts about the user — **the selected profile, and only it**.
    ///
    /// Everything downstream reads the profile through this one property and
    /// sees exactly what it saw when the app kept a single one: `SessionEngine`,
    /// the composers and the prompt builders know nothing about a library.
    /// Assigning a whole profile replaces the selected entry, which is what
    /// makes `$store.profile.role` in the settings form still work.
    var profile: UserProfile {
        get { profileLibrary.selected }
        set { profileLibrary.replaceSelected(with: newValue) }
    }

    /// What the user prepared for the interview they are going to — stories,
    /// motivation, money, questions back.
    ///
    /// One, not one per profile: the same team-lead profile goes to three
    /// companies, and it is this that differs between them, not the experience.
    /// See `InterviewContext` for why it is not a field of `UserProfile`.
    ///
    /// Persisted like everything else here, and for the same reason: it is typed
    /// in before the call, and losing it to a restart — or to the panic key —
    /// would be losing ten minutes of preparation at the worst possible moment.
    /// It is emptied only when the user says so, through
    /// `clearInterviewContext()`.
    var interviewContext: InterviewContext {
        didSet { persist(interviewContext, forKey: DefaultsKey.interviewContext) }
    }

    /// Thresholds handed to `SessionEngine` as configuration.
    var turnSegmentation: TurnSegmentationConfig {
        didSet { persist(turnSegmentation, forKey: DefaultsKey.turnSegmentation) }
    }

    /// Which local model recognises speech. Belongs to the user rather than to a
    /// call: the model is downloaded once and reused across every session, so a
    /// choice made before an interview must still be there at the next one.
    var speechModel: WhisperModel {
        didSet { persist(speechModel, forKey: DefaultsKey.speechModel) }
    }

    /// Which engine recognises speech at all (ADR-0013).
    ///
    /// Belongs to the user like the model does, and for the same reason: it is a
    /// property of this machine and this person's calls, not of one session.
    var speechEngine: SpeechEngine {
        didSet { persist(speechEngine, forKey: DefaultsKey.speechEngine) }
    }

    /// The language this interview is conducted in.
    ///
    /// One setting for one language: it decides what the model answers in and
    /// which locale the system recogniser gets. Whisper works the language out of
    /// the audio; the system engine and the prompt layer cannot, so they are told.
    var interviewLanguage: InterviewLanguage {
        didSet { persist(interviewLanguage, forKey: DefaultsKey.interviewLanguage) }
    }

    /// Which microphone the `You` channel listens to; `nil` means the system's.
    ///
    /// Stored as a UID rather than an `AudioDeviceID` because the numeric id is
    /// handed out per boot and reused — a stored one would point at a different
    /// microphone after a restart, which is the exact failure this setting exists
    /// to prevent.
    var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: DefaultsKey.microphoneUID) }
    }

    /// Stable id of the application whose sound becomes the `Them` channel, or
    /// `nil` while none has been picked.
    ///
    /// An id and not a process: a browser plays the call from a helper process
    /// that gets a new PID on every launch, so anything narrower than the
    /// application would stop pointing at it after the first restart. Persisted
    /// because the same browser is used call after call — this is picked once,
    /// not before every interview.
    var themSourceApplicationID: String? {
        didSet {
            if let id = themSourceApplicationID, !id.isEmpty {
                defaults.set(id, forKey: DefaultsKey.themSourceApplication)
            } else {
                defaults.removeObject(forKey: DefaultsKey.themSourceApplication)
            }
        }
    }

    /// How the `Them` channel is captured.
    ///
    /// ScreenCaptureKit by default: on the same recording it delivers a signal
    /// 1.5–2.5 times louder than the process tap, and loudness is what
    /// recognition quality hangs on. The tap remains one switch away for a
    /// machine where Screen Recording is not on offer.
    ///
    /// Persisted as a bare string rather than as encoded JSON, so that the
    /// choice can be made from outside the app while the two backends are being
    /// compared — `defaults write … settings.themCaptureBackend` — and so that a
    /// value written by a future version simply falls back to the default
    /// instead of leaving the channel with no backend at all.
    var themCaptureBackend: ThemCaptureBackend {
        didSet { defaults.set(themCaptureBackend.rawValue, forKey: DefaultsKey.themCaptureBackend) }
    }

    // There is no `allowsVoiceProcessing` here any more, and its absence is a
    // decision rather than a tidy-up. ADR-0007 left it as an extension point «на
    // случай настоящей причины»; ADR-0009 measured the reason and it turned out
    // to point the other way — system voice processing costs every *other*
    // process on the machine 28–32 dB, the browser holding the call included. So
    // there is no backend, and no setting, under which it may come back on.

    /// Whether the app asks for the update feed at launch — and, since 0.4.0, may
    /// install what it finds (ADR-0012).
    ///
    /// **On by default, which is the one place this app reaches out without
    /// being asked.** The reason is how it is delivered: a disk image handed to a
    /// colleague, with no store and no way of learning about a new version other
    /// than being told. A check the user has to remember to run is a check nobody
    /// runs, and the machine stays on the build it was given.
    ///
    /// What the request carries is the whole of the argument for the default: an
    /// IP address and the running version. No transcript, no profile, no
    /// identifier of the machine or the user — the framework's optional system
    /// profile is off from three sides — and the answer is a public file anybody
    /// can open. It is off with one switch, and off means no request at all: with
    /// this false the updater is not built, never mind asked.
    ///
    /// **One switch for both, deliberately.** Splitting «спрашивать» from
    /// «ставить» would produce a state — knows about a version, may not install
    /// it — whose only outcome is a line nagging about something the user has
    /// already forbidden. What the switch permits is stated on the settings
    /// screen in the words «Проверять и ставить обновления».
    ///
    /// Stored as a bare `Bool`, so the absent value has to be handled explicitly
    /// at load: `UserDefaults.bool(forKey:)` answers false for "never written",
    /// which would silently ship the opposite default.
    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: DefaultsKey.checksForUpdates) }
    }

    /// The language of the interface.
    ///
    /// **Not the language of a suggestion** — that follows the conversation and
    /// is decided by the model, not here; see `AppLanguage`. Writing it takes
    /// effect at the next launch, which is stated on the settings screen beside
    /// the picker rather than left for the user to discover.
    var appLanguage: AppLanguage {
        didSet { appLanguage.apply(to: defaults) }
    }

    /// Which chord runs which global action.
    ///
    /// User-scoped like everything else here: hotkeys are muscle memory, and
    /// muscle memory that resets between calls is worse than no hotkeys at all.
    ///
    /// Stored whole rather than key by key, so that an action the user
    /// deliberately left **without** a chord stays without one: a per-action
    /// fallback to the default would quietly hand the combination back at the
    /// next launch. The shipped defaults apply only when nothing has ever been
    /// written here.
    var hotkeys: HotkeyBindings {
        didSet { persist(hotkeys, forKey: DefaultsKey.hotkeys) }
    }

    /// Which model answers, plus the overrides the user typed over the preset.
    ///
    /// Only the choice is here — never the key, which stays in the keychain
    /// under an account of its own. Persisted whole, so base URL, model and CLI
    /// command survive a restart together with the provider they belong to.
    var providerSelection: ProviderSelection {
        didSet {
            persist(providerSelection, forKey: DefaultsKey.providerSelection)
            // Every provider has its own key, so moving to another one changes
            // which keychain entry the screen is talking about.
            if providerSelection.presetID != oldValue.presetID {
                refreshProviderKeyPresence()
            }
        }
    }

    /// The preset behind the current selection, with its transport, defaults
    /// and — the part the settings screen must not lie about — its capabilities.
    var providerPreset: ProviderPreset {
        ProviderFactory.preset(id: providerSelection.presetID) ?? Self.fallbackPreset
    }

    /// Whether the screen has to ask for a key at all. False for local servers
    /// and for CLI tools, which authenticate themselves.
    var providerRequiresKey: Bool { providerPreset.needsKey }

    /// Whether a screenshot may ride along with a request.
    var providerAcceptsImages: Bool { providerPreset.capabilities.acceptsImages }

    /// What the screen tells the user about the chosen provider's reach.
    ///
    /// Lives here rather than in the view because it is a statement about the
    /// product's primary mode, not a caption: with a text-only provider `Solve
    /// on screen` reasons over recognised text alone, and the user has to learn
    /// that when picking, not when the answer turns out to be worse.
    var providerCapabilityNote: String {
        providerAcceptsImages
            ? String(localized: "Провайдер принимает изображения: режим «Решить с экрана» получает сам скриншот.")
            : String(localized: "Провайдер только текстовый: скриншот не отправляется, и режим «Решить с экрана» работает слабее — по распознанному тексту с экрана.")
    }

    /// The reason the current selection cannot be turned into a provider, in
    /// words meant for the user — a mistyped base URL, an emptied model.
    ///
    /// Built by trying the real thing rather than by validating separately, so
    /// the screen cannot say "fine" about a selection the session would refuse.
    var providerConfigurationError: String? {
        do {
            _ = try makeProvider()
            return nil
        } catch let failure as LLMFailure {
            return failure.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Where a request actually goes — this machine, a command-line tool, or
    /// somebody's servers.
    ///
    /// Computed from the *effective* base URL rather than from the preset, so
    /// an OpenAI preset repointed at `localhost` counts as local and an Ollama
    /// preset repointed at a rented box does not.
    var providerDestination: ProviderDestination {
        ProviderDestination(preset: providerPreset, selection: providerSelection)
    }

    /// What the user is told **before** handing over a resume — which provider
    /// gets it, and whether that means the text leaves the machine.
    ///
    /// Here rather than in the view because it is a statement of fact about the
    /// current selection, and because it has to be right: a resume carries a
    /// name, employers and often a phone number, and a user who would not have
    /// sent that to a cloud has to learn it before pressing, not after.
    var resumePrivacyNote: String {
        providerDestination.resumeNote(providerName: providerPreset.name)
    }

    /// Used when a hand-edited preferences file names a provider that no longer
    /// exists: the app falls back to the shipped default instead of ending up
    /// with no provider at all.
    private static var fallbackPreset: ProviderPreset {
        ProviderFactory.preset(id: ProviderFactory.defaultSelection.presetID)
            ?? ProviderFactory.presets[0]
    }

    // MARK: - Secret status (never the secret itself)

    /// Whether a key is stored for the **currently selected** provider. Keys of
    /// the other providers stay where they are and are not reflected here.
    private(set) var hasProviderKey: Bool = false

    /// Human-readable description of the last keychain failure, or `nil`.
    /// Contains a status code only — never the key.
    private(set) var lastSecretError: String?

    // MARK: - Dependencies

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainHelper.shared
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.profileLibrary = Self.decode(
            ProfileLibrary.self,
            from: defaults,
            key: DefaultsKey.profileLibrary
        ) ?? Self.migratedLibrary(from: defaults)
        // A build that had no interview context at all leaves nothing here, and
        // an empty one is exactly the right answer to that.
        self.interviewContext = Self.decode(
            InterviewContext.self,
            from: defaults,
            key: DefaultsKey.interviewContext
        ) ?? .empty
        self.turnSegmentation = Self.storedTurnSegmentation(in: defaults)
        // An unknown or hand-edited value falls back to the default instead of
        // leaving the app with no model at all.
        self.speechModel = Self.decode(WhisperModel.self, from: defaults, key: DefaultsKey.speechModel)
            ?? .default
        // A stored engine this machine cannot run — settings carried over from a
        // newer system, or a hand-edited value — falls back to Whisper rather
        // than leaving recognition pointing at something that does not exist.
        let storedEngine = Self.decode(SpeechEngine.self, from: defaults, key: DefaultsKey.speechEngine)
        self.speechEngine = (storedEngine?.isAvailable ?? false) ? storedEngine! : .whisper
        self.interviewLanguage = Self.decode(InterviewLanguage.self, from: defaults, key: DefaultsKey.interviewLanguage)
            ?? .automatic
        self.microphoneUID = defaults.string(forKey: DefaultsKey.microphoneUID)
        self.themSourceApplicationID = defaults.string(forKey: DefaultsKey.themSourceApplication)
        self.themCaptureBackend = defaults.string(forKey: DefaultsKey.themCaptureBackend)
            .flatMap(ThemCaptureBackend.init(rawValue:)) ?? .default
        self.hotkeys = Self.decode(HotkeyBindings.self, from: defaults, key: DefaultsKey.hotkeys)
            ?? .default
        // Absent means "never asked", and the shipped answer to that is yes —
        // see the property. Read through `object(forKey:)` because `bool(forKey:)`
        // cannot tell "written as false" from "never written" and would turn the
        // default upside down on every fresh install.
        self.checksForUpdates = defaults.object(forKey: DefaultsKey.checksForUpdates) == nil
            ? true
            : defaults.bool(forKey: DefaultsKey.checksForUpdates)
        // Read back from `AppleLanguages` rather than from a key of our own: two
        // places holding the same answer is two places that can disagree.
        self.appLanguage = AppLanguage.stored(in: defaults)
        // A selection naming a provider that has since been removed falls back
        // to the default rather than leaving the app pointed at nothing.
        let stored = Self.decode(ProviderSelection.self, from: defaults, key: DefaultsKey.providerSelection)
        self.providerSelection = stored.flatMap { selection in
            ProviderFactory.preset(id: selection.presetID) == nil ? nil : selection
        } ?? ProviderFactory.defaultSelection
        migrateLegacyProviderKeyIfNeeded()
        finishProfileMigrationIfNeeded()
        finishTurnSegmentationMigrationIfNeeded()
        refreshProviderKeyPresence()
    }

    // MARK: - Profiles

    /// Adds a profile and selects it. Returns its id so the caller can put the
    /// cursor in the name field.
    @discardableResult
    func addProfile(named name: String = "") -> UserProfile.ID {
        profileLibrary.add(UserProfile(name: name))
    }

    func selectProfile(_ id: UserProfile.ID) {
        profileLibrary.select(id)
    }

    func renameProfile(_ id: UserProfile.ID, to name: String) {
        profileLibrary.rename(id, to: name)
    }

    /// Deletes a profile. The library keeps at least one and moves the
    /// selection to a neighbour, so there is never a moment with no profile.
    func removeProfile(_ id: UserProfile.ID) {
        profileLibrary.remove(id)
    }

    /// Writes a profile back by id — used when a profile is edited somewhere
    /// other than the selection, and by the resume import when it applies the
    /// draft it built for one particular entry.
    func updateProfile(_ profile: UserProfile) {
        profileLibrary.update(profile)
    }

    /// Turns the single profile of an older build into a library.
    ///
    /// Runs before anything reads `profileLibrary`, so the upgrade is invisible:
    /// the profile the user filled in months ago becomes the first entry and
    /// stays selected. Losing it here would be found out mid-interview, when the
    /// suggestions stop sounding like them.
    private static func migratedLibrary(from defaults: UserDefaults) -> ProfileLibrary {
        guard let legacy = decode(UserProfile.self, from: defaults, key: DefaultsKey.legacyProfile)
        else { return .initial }
        return ProfileLibrary(migrating: legacy)
    }

    /// Writes the migrated library out and retires the old key — after the new
    /// value is on disk, never before, so a failure leaves the original intact.
    private func finishProfileMigrationIfNeeded() {
        guard defaults.data(forKey: DefaultsKey.legacyProfile) != nil else { return }
        persist(profileLibrary, forKey: DefaultsKey.profileLibrary)
        guard defaults.data(forKey: DefaultsKey.profileLibrary) != nil else { return }
        defaults.removeObject(forKey: DefaultsKey.legacyProfile)
    }

    // MARK: - Interview context

    /// Empties the interview context — the deliberate act of getting ready for
    /// the *next* company.
    ///
    /// A button of its own, and pointedly not part of «Очистить контекст
    /// разговора»: that one throws away the transcript of the call in progress
    /// and is bound to a panic key, and wiping ten minutes of preparation with
    /// it would be a disaster wearing the same word. The profile is untouched
    /// either way — it belongs to the person, not to the interview.
    func clearInterviewContext() {
        interviewContext = .empty
    }

    // MARK: - Provider key

    /// Reads the key of the currently selected provider straight from the
    /// keychain. Callers use it to build a request and drop it again; it is
    /// intentionally not cached.
    func providerKey() -> String? {
        providerKey(forPresetID: providerSelection.presetID)
    }

    /// Reads the key of one particular provider — the form the isolation
    /// between them is actually built on.
    func providerKey(forPresetID presetID: String) -> String? {
        do {
            let key = try secrets.secret(forAccount: SecretAccount.llmProviderKey(presetID: presetID))
            lastSecretError = nil
            return key
        } catch {
            report(error)
            return nil
        }
    }

    /// Stores the key of the currently selected provider. Returns `false` when
    /// the keychain refused, in which case `lastSecretError` explains why.
    @discardableResult
    func setProviderKey(_ key: String) -> Bool {
        setProviderKey(key, forPresetID: providerSelection.presetID)
    }

    @discardableResult
    func setProviderKey(_ key: String, forPresetID presetID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeProviderKey(forPresetID: presetID) }
        return write(trimmed, forPresetID: presetID)
    }

    /// Deletes the key of the currently selected provider, leaving every other
    /// provider's key untouched.
    @discardableResult
    func removeProviderKey() -> Bool {
        removeProviderKey(forPresetID: providerSelection.presetID)
    }

    @discardableResult
    func removeProviderKey(forPresetID presetID: String) -> Bool {
        write(nil, forPresetID: presetID)
    }

    private func write(_ key: String?, forPresetID presetID: String) -> Bool {
        do {
            try secrets.setSecret(key, forAccount: SecretAccount.llmProviderKey(presetID: presetID))
            lastSecretError = nil
            if presetID == providerSelection.presetID {
                hasProviderKey = key?.isEmpty == false
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func refreshProviderKeyPresence() {
        do {
            let account = SecretAccount.llmProviderKey(presetID: providerSelection.presetID)
            hasProviderKey = try secrets.secret(forAccount: account)?.isEmpty == false
            lastSecretError = nil
        } catch {
            hasProviderKey = false
            report(error)
        }
    }

    /// Moves a key written by a build that kept one shared account onto the
    /// selected provider.
    ///
    /// Without this the upgrade reads as data loss: the key is still in the
    /// keychain, but under an account nothing looks at any more. Runs once —
    /// the legacy entry is removed only after the new one has been written.
    private func migrateLegacyProviderKeyIfNeeded() {
        do {
            guard let legacy = try secrets.secret(forAccount: SecretAccount.legacyLLMProviderKey),
                  !legacy.isEmpty else { return }

            let account = SecretAccount.llmProviderKey(presetID: providerSelection.presetID)
            if try secrets.secret(forAccount: account)?.isEmpty != false {
                try secrets.setSecret(legacy, forAccount: account)
            }
            try secrets.setSecret(nil, forAccount: SecretAccount.legacyLLMProviderKey)
        } catch {
            report(error)
        }
    }

    /// Records a keychain failure for the UI. Only the error's own description
    /// is kept, which by construction carries a status code and nothing else.
    private func report(_ error: Error) {
        lastSecretError = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }

    // MARK: - Thresholds

    /// Puts every threshold back to the spec defaults.
    func resetTurnSegmentationToDefaults() {
        turnSegmentation = .default
    }

    /// The stored thresholds, brought up to what this version ships.
    ///
    /// Clamping happens after the migration and not instead of it: clamping
    /// defends against a value nobody could have chosen, migration against a
    /// value the app itself chose and has since retired.
    private static func storedTurnSegmentation(in defaults: UserDefaults) -> TurnSegmentationConfig {
        guard let stored = decode(
            TurnSegmentationConfig.self,
            from: defaults,
            key: DefaultsKey.turnSegmentation
        ) else { return .default }

        let version = defaults.integer(forKey: DefaultsKey.turnSegmentationVersion)
        return TurnSegmentationMigration.migrate(stored, storedVersion: version).clamped()
    }

    /// Writes the migrated thresholds out and records that this migration has
    /// run.
    ///
    /// The version is raised **after** the new value is on disk, so an upgrade
    /// interrupted between the two migrates again instead of freezing the old
    /// threshold under a version that claims otherwise. On a machine with nothing
    /// stored only the version is written: there is nothing to migrate, and
    /// leaving it absent would make the first slider drag look like a file from
    /// the proactive build at the next launch.
    private func finishTurnSegmentationMigrationIfNeeded() {
        let version = defaults.integer(forKey: DefaultsKey.turnSegmentationVersion)
        guard version < TurnSegmentationMigration.currentVersion else { return }
        if defaults.data(forKey: DefaultsKey.turnSegmentation) != nil {
            persist(turnSegmentation, forKey: DefaultsKey.turnSegmentation)
        }
        defaults.set(TurnSegmentationMigration.currentVersion, forKey: DefaultsKey.turnSegmentationVersion)
    }

    // MARK: - Persistence

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from defaults: UserDefaults,
        key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Building the provider

extension SettingsStore {

    /// The provider the user selected, wired to this store's keys.
    ///
    /// Throwing rather than optional-returning: a base URL the user mistyped
    /// has to reach them as a sentence — `providerConfigurationError` shows it
    /// right next to the field that caused it — instead of leaving the session
    /// quietly without a model.
    func makeProvider() throws -> any LLMProvider {
        try ProviderFactory.make(selection: providerSelection, key: providerKeyReader())
    }

    /// Reads the selected provider's key at the moment of the request.
    ///
    /// A closure and not a string: a key typed mid-call takes effect on the
    /// next suggestion, and nothing between here and the request keeps a copy
    /// of it. It is pinned to the provider that was selected when the provider
    /// object was built, so a later switch cannot send one service another
    /// service's key.
    func providerKeyReader() -> @Sendable () async -> String? {
        let presetID = providerSelection.presetID
        return { [self] in await MainActor.run { providerKey(forPresetID: presetID) } }
    }
}

extension SettingsStore: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted on purpose: `SettingsStore` must be safe to print. The provider
    /// key is not part of this type's state and must never appear in a log.
    nonisolated var description: String {
        "SettingsStore(secrets: keychain-only, redacted)"
    }

    nonisolated var debugDescription: String { description }
}
