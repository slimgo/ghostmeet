//
//  HotkeyAction.swift
//  GhostMeet
//

import Carbon.HIToolbox
import Foundation

/// What a global hotkey does.
///
/// Hotkeys are **the** path in GhostMeet, not a secondary one: since ADR-0008 a
/// request reaches the model only when the user presses. Three of these seven
/// chords are that press — the two genres of the suggestion about the
/// conversation, and the task on screen — and the other four are the session
/// itself.
///
/// The order matters, because it is the order of the list in the window: the
/// session first, then what the user actually presses mid-answer.
///
/// `Ask` gets no chord: it needs the keyboard anyway, so the field is already the
/// fastest way in.
nonisolated enum HotkeyAction: String, CaseIterable, Codable, Sendable, Identifiable {

    /// Show or hide the overlay. **Capture keeps running while it is hidden** —
    /// this is the panic key, not a stop button.
    case toggleVisibility
    /// Start listening, waiting for the recognition model if it is not loaded yet.
    case startListening
    /// Stop listening.
    case stopListening
    /// Жанр «коротко» — the default press: the user is already answering and is
    /// missing one thing.
    case suggestBriefly
    /// Жанр «подробно» — the full answer, for a subject that is unfamiliar whole.
    case suggestInDetail
    /// Ask for the task on screen to be solved. Wanted at exactly the moment the
    /// interview turns into a shared editor — the cursor is in someone else's
    /// window and hunting for a button in a translucent overlay is both slow and
    /// visible.
    case solveOnScreen
    /// Forget the conversation so far. The `Профиль` survives it — it belongs to
    /// the user, not to the call — and so does the `Контекст собеседования`,
    /// which belongs to the call but was typed in before it and is not part of
    /// what was said.
    case clearContext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleVisibility: String(localized: "Показать / скрыть окно")
        case .startListening: String(localized: "Начать прослушивание")
        case .stopListening: String(localized: "Остановить прослушивание")
        case .suggestBriefly: String(localized: "Подсказка коротко")
        case .suggestInDetail: String(localized: "Подсказка подробно")
        case .solveOnScreen: String(localized: "Решить задачу с экрана")
        case .clearContext: String(localized: "Очистить контекст разговора")
        }
    }

    /// One line of what actually happens, for the row in the interface. The
    /// panic key's line is the important one: users assume hiding stops
    /// recording, and here it does not.
    var summary: String {
        switch self {
        case .toggleVisibility:
            String(localized: "Прячет окно с глаз мгновенно. Захват при этом продолжается — реплики пишутся дальше.")
        case .startListening:
            String(localized: "Если модель распознавания ещё готовится, прослушивание включится само, как только она будет готова.")
        case .stopListening:
            String(localized: "Останавливает оба канала и закрывает начатую реплику.")
        case .suggestBriefly:
            String(localized: "Главный аккорд. Дозакрывает вопрос собеседника и вашу начатую фразу, а просит только недостающее — термин, цифру, пару пунктов. Нажимают, уже начав отвечать.")
        case .suggestInDetail:
            String(localized: "То же, но развёрнутым разбором — когда тема незнакома целиком.")
        case .solveOnScreen:
            String(localized: "Просит готовое решение задачи, которая сейчас на экране. Работает и без прослушивания.")
        case .clearContext:
            String(localized: "Стирает транскрипт и подсказки текущего звонка. Профиль и контекст собеседования остаются — они заполнены заранее.")
        }
    }

    /// What ships. Chosen to avoid chords the user's other applications need:
    /// a global hotkey outranks the focused app, so ⌘⇧S here would take «Сохранить
    /// как…» away from every editor on the machine.
    ///
    /// The panic key is the exception to the ⌘⌥ pattern: it has to be reachable
    /// in one motion, on camera, without looking down.
    ///
    /// **The three chords pressed during a call are one cluster under one hand,
    /// and that is the whole rule.** `A`, `Z` and `X` sit on top of each other in
    /// the bottom-left corner, so the thumb takes ⌥⌘ and the remaining fingers
    /// reach all three without the hand moving and without looking down — while
    /// the other hand keeps typing, which is the situation these are pressed in.
    ///
    /// It replaced ⌥⌘E and ⌥⌘G, and the complaint was the plain one: `E` is two
    /// rows up from the modifiers and needs the second hand. Letters here are
    /// chosen for the hand and never for a mnemonic; the mnemonic is what the
    /// settings screen is for.
    ///
    /// What the cluster cannot use, and why — the neighbours are all taken:
    /// ⌥⌘D is the system's own "hide the Dock", ⌥⌘S is "Save All" in VS Code,
    /// ⌥⌘W closes every window, ⌥⌘V is "Move item here" in Finder, ⌥⌘Q sits one
    /// slip away from logging out. A global hotkey outranks the focused app, so
    /// taking one of those would take it away from every application on the
    /// machine. F13–F15 are the safest chords of all and are also absent from
    /// every laptop keyboard, which is what this app runs on.
    ///
    /// The panic key is the exception to the ⌥⌘ pattern: it has to be reachable
    /// in one motion, on camera, without looking down.
    var defaultHotkey: Hotkey {
        switch self {
        case .toggleVisibility: Hotkey(kVK_ANSI_Backslash, [.command])
        case .startListening: Hotkey(kVK_ANSI_L, [.command, .option])
        case .stopListening: Hotkey(kVK_ANSI_Period, [.command, .option])
        case .suggestBriefly: Hotkey(kVK_ANSI_A, [.command, .option])
        case .suggestInDetail: Hotkey(kVK_ANSI_Z, [.command, .option])
        case .solveOnScreen: Hotkey(kVK_ANSI_X, [.command, .option])
        case .clearContext: Hotkey(kVK_ANSI_K, [.command, .option])
        }
    }

    /// The chord this action used to ship with, when a later version moved it.
    ///
    /// Kept so that a set written by the older build can be brought forward
    /// without touching anything the user chose: a binding that still equals the
    /// retired default was never a decision, it was what happened to ship.
    var retiredDefaultHotkey: Hotkey? {
        switch self {
        case .suggestInDetail: Hotkey(kVK_ANSI_E, [.command, .option])
        case .solveOnScreen: Hotkey(kVK_ANSI_G, [.command, .option])
        default: nil
        }
    }

    /// The chords offered for this action in the interface.
    ///
    /// A fixed list rather than a "press the keys" recorder: the overlay is a
    /// `.nonactivatingPanel` that deliberately never takes the keyboard focus
    /// (that is what keeps typing in the call working), so it is the one window
    /// in the app that cannot reliably read a key press. A picker needs no focus.
    var candidates: [Hotkey] {
        var chords = [defaultHotkey]
        chords.append(contentsOf: Self.sharedCandidates.filter { $0 != defaultHotkey })
        return chords
    }

    /// Chords that are free of standard system and browser shortcuts, offered for
    /// every action.
    private static let sharedCandidates: [Hotkey] = [
        Hotkey(kVK_ANSI_Backslash, [.command]),
        Hotkey(kVK_ANSI_Backslash, [.command, .option]),
        Hotkey(kVK_ANSI_A, [.command, .option]),
        Hotkey(kVK_ANSI_Z, [.command, .option]),
        Hotkey(kVK_ANSI_X, [.command, .option]),
        Hotkey(kVK_ANSI_E, [.command, .option]),
        Hotkey(kVK_ANSI_L, [.command, .option]),
        Hotkey(kVK_ANSI_Period, [.command, .option]),
        Hotkey(kVK_ANSI_K, [.command, .option]),
        Hotkey(kVK_ANSI_G, [.command, .option]),
        Hotkey(kVK_ANSI_J, [.command, .option]),
        Hotkey(kVK_ANSI_Quote, [.command, .option]),
        Hotkey(kVK_F13, [.control, .option]),
        Hotkey(kVK_F14, [.control, .option]),
        Hotkey(kVK_F15, [.control, .option]),
        Hotkey(kVK_ANSI_1, [.control, .option, .command]),
        Hotkey(kVK_ANSI_2, [.control, .option, .command]),
        Hotkey(kVK_ANSI_3, [.control, .option, .command]),
        Hotkey(kVK_ANSI_4, [.control, .option, .command])
    ]
}

/// Which chord runs which action, as the user left it.
///
/// An absent action is an action with **no** hotkey, and that is a state the user
/// can choose: a binding they cleared must not come back at the next launch.
///
/// That rule alone is not enough, and the difference cost a whole feature once.
/// The set is stored whole, so «нет комбинации» covered two situations that look
/// identical in the file and are opposites in meaning: the user took the chord
/// away, and the version that wrote the file had never heard of the action. When
/// ADR-0008 added the two genres, everyone who had ever touched a binding got a
/// blob with the five actions of the proactive build — and the press that is now
/// the *only* path to the model silently had no key. So the two are recorded
/// apart: `cleared` is the user's decision and survives every upgrade, and
/// anything neither bound nor cleared is an action this file has never seen and
/// is given the chord it ships with.
nonisolated struct HotkeyBindings: Codable, Equatable, Sendable {

    /// Keyed by the raw value rather than by `HotkeyAction`, so the stored JSON
    /// is a plain object and an action added by a later version simply does not
    /// appear instead of failing the whole decode.
    private var storage: [String: Hotkey]

    /// Actions the user deliberately left without a chord.
    ///
    /// Kept by raw value for the same reason `storage` is, and kept at all
    /// because it is the only thing that distinguishes a decision from a gap.
    private var cleared: Set<String>

    init(_ pairs: [HotkeyAction: Hotkey] = [:]) {
        storage = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key.rawValue, $0.value) })
        cleared = []
    }

    /// What ships on a first launch.
    static var `default`: HotkeyBindings {
        HotkeyBindings(
            Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultHotkey) })
        )
    }

    subscript(action: HotkeyAction) -> Hotkey? {
        get { storage[action.rawValue] }
        set { assign(newValue, to: action) }
    }

    /// Whether the user chose to leave this action without a chord.
    ///
    /// The window says so in different words than it says «этому действию
    /// комбинации не досталось»: one of them is a decision to remind the user of,
    /// the other is something the app failed to give them.
    func isCleared(_ action: HotkeyAction) -> Bool {
        cleared.contains(action.rawValue)
    }

    /// Every action that currently has a chord.
    var assigned: [HotkeyAction: Hotkey] {
        var result: [HotkeyAction: Hotkey] = [:]
        for (raw, hotkey) in storage {
            guard let action = HotkeyAction(rawValue: raw) else { continue }
            result[action] = hotkey
        }
        return result
    }

    /// Which action a chord currently runs, if any.
    func action(boundTo hotkey: Hotkey) -> HotkeyAction? {
        assigned.first { $0.value == hotkey }?.key
    }

    /// Binds a chord to an action, or clears the binding with `nil`.
    ///
    /// A chord already used by another action is **taken** from it rather than
    /// refused. Two actions on one chord is not a state the system can honour —
    /// only one of them would ever fire — and a silent refusal would leave the
    /// user pressing a key that does the wrong thing.
    mutating func assign(_ hotkey: Hotkey?, to action: HotkeyAction) {
        guard let hotkey else {
            storage.removeValue(forKey: action.rawValue)
            cleared.insert(action.rawValue)
            return
        }
        guard hotkey.isValid else { return }
        for (raw, existing) in storage where existing == hotkey && raw != action.rawValue {
            // Taken, not cleared: the action it is taken from ends up without a
            // chord, but nobody decided that it should stay that way, and the
            // window is expected to say so.
            storage.removeValue(forKey: raw)
        }
        storage[action.rawValue] = hotkey
        cleared.remove(action.rawValue)
    }

    // MARK: - Storage

    private enum CodingKeys: String, CodingKey {
        case storage
        case cleared
    }

    /// Reads a stored set and brings it up to the actions this version has.
    ///
    /// A file written before `cleared` existed carries the decision implicitly:
    /// back then the only way for an action to be missing was for the user to
    /// clear it, **provided the version that wrote the file knew the action at
    /// all**. `actionsOfTheProactiveBuild` is that list, and it is written out by
    /// hand rather than derived from `HotkeyAction.allCases` precisely because
    /// `allCases` moves and history does not.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storage = try container.decodeIfPresent([String: Hotkey].self, forKey: .storage) ?? [:]
        cleared = try container.decodeIfPresent(Set<String>.self, forKey: .cleared)
            ?? Self.actionsOfTheProactiveBuild.subtracting(storage.keys)
        adoptDefaultsForUnknownActions()
        moveOnFromRetiredDefaults()
    }

    /// The actions that existed while a chord was the secondary path (ADR-0003):
    /// everything a file of that era leaves out, the user left out.
    private static let actionsOfTheProactiveBuild: Set<String> = [
        "toggleVisibility", "startListening", "stopListening", "solveOnScreen", "clearContext"
    ]

    /// Gives its shipped chord to every action this set has never heard of.
    ///
    /// The chord is **not** taken from whoever holds it. Stealing a binding the
    /// user chose, silently, at launch, would be a worse version of the very
    /// failure this migration exists to undo; the action is left without one
    /// instead, and `HotkeyCenter.problem(with:)` states it in the window.
    private mutating func adoptDefaultsForUnknownActions() {
        for unknown in HotkeyAction.allCases {
            guard storage[unknown.rawValue] == nil, !cleared.contains(unknown.rawValue) else { continue }
            guard action(boundTo: unknown.defaultHotkey) == nil else { continue }
            storage[unknown.rawValue] = unknown.defaultHotkey
        }
    }

    /// Brings a binding that is still the **old** shipped chord forward to the
    /// new one.
    ///
    /// The line between a decision and an inheritance is exactly this: a chord
    /// equal to the retired default was never chosen, it was what the build of
    /// the day happened to give. Anything else — including the new default's
    /// chord assigned to some other action — is the user's and is left alone.
    ///
    /// Nothing is stolen here either. If the new chord is already taken, the
    /// action keeps the old one: an uncomfortable chord that works beats a
    /// comfortable one that silently disabled something else.
    private mutating func moveOnFromRetiredDefaults() {
        for action in HotkeyAction.allCases {
            guard let retired = action.retiredDefaultHotkey,
                  storage[action.rawValue] == retired,
                  self.action(boundTo: action.defaultHotkey) == nil
            else { continue }
            storage[action.rawValue] = action.defaultHotkey
        }
    }
}
