//
//  HotkeyCenter.swift
//  GhostMeet
//

import Foundation
import Observation

/// What each hotkey actually does, injected by the composition root.
///
/// Closures and not a reference to the session: the panic key belongs to the
/// window layer, starting belongs to the session, and clearing belongs to the
/// conversation. Wiring them here would make this type know all three, and the
/// two things worth testing about hotkeys — that the right action runs, and that
/// hiding does not stop capture — are exactly the things such a type hides.
@MainActor
struct HotkeyActions {

    var toggleVisibility: () -> Void = {}
    /// Deliberately the "listen to this call" start and not "listen now": a
    /// chord pressed while the recognition model is still loading has to wait
    /// for it, because a turn closed too early is refused outright and the first
    /// question of the interview is lost. `SessionController` has
    /// `startWhenRecognitionIsReady()` for precisely this caller.
    var startListening: () -> Void = {}
    var stopListening: () -> Void = {}
    /// Жанр «коротко» — the press the whole app is built around (ADR-0008).
    var suggestBriefly: () -> Void = {}
    /// Жанр «подробно».
    var suggestInDetail: () -> Void = {}
    /// Mode `Solve on screen`. Needs no session — the screen is the whole input —
    /// so this fires whether or not capture is running.
    var solveOnScreen: () -> Void = {}
    var clearContext: () -> Void = {}

    subscript(action: HotkeyAction) -> () -> Void {
        switch action {
        case .toggleVisibility: toggleVisibility
        case .startListening: startListening
        case .stopListening: stopListening
        case .suggestBriefly: suggestBriefly
        case .suggestInDetail: suggestInDetail
        case .solveOnScreen: solveOnScreen
        case .clearContext: clearContext
        }
    }
}

/// The bindings the user has, the registration of those bindings with the
/// system, and the dispatch of a press to the action it stands for.
///
/// Nothing here reports anything through the system: a chord the system refused
/// is surfaced inside the overlay, next to the binding that failed. A
/// notification banner would be drawn over the shared screen and hand the app
/// over (ADR-0004), and that holds for a mundane "this shortcut is taken" just
/// as much as for a capture failure.
@MainActor
@Observable
final class HotkeyCenter {

    /// Which chord runs which action right now.
    private(set) var bindings: HotkeyBindings

    /// Actions whose chord the system would not give us — normally because
    /// another application already owns it. Shown next to the binding.
    private(set) var unavailable: Set<HotkeyAction> = []

    /// What the chords do. Set by the composition root after the window and the
    /// session exist.
    @ObservationIgnored var actions: HotkeyActions {
        didSet { registry.onPress = { [weak self] action in self?.perform(action) } }
    }

    @ObservationIgnored private let registry: any HotkeyRegistry
    @ObservationIgnored private let store: SettingsStore

    /// - Parameters:
    ///   - registry: defaulted in the body rather than in the signature, because
    ///     a default argument is evaluated outside any actor and both types here
    ///     are main-actor isolated.
    init(
        store: SettingsStore,
        registry: (any HotkeyRegistry)? = nil,
        actions: HotkeyActions? = nil
    ) {
        self.store = store
        self.registry = registry ?? CarbonHotkeyRegistry()
        self.actions = actions ?? HotkeyActions()
        self.bindings = store.hotkeys
    }

    // MARK: - Registration

    /// Registers everything the user has bound. Safe to call again — the registry
    /// replaces its whole set each time.
    func activate() {
        unavailable = registry.replaceAll(with: bindings.assigned)
        registry.onPress = { [weak self] action in self?.perform(action) }
    }

    // MARK: - Rebinding

    /// Moves an action onto another chord, or clears it with `nil`.
    ///
    /// Persisted immediately: a binding changed mid-call has to survive the
    /// crash that mid-call changes tend to precede, and there is no Apply button
    /// anywhere in this app.
    func rebind(_ action: HotkeyAction, to hotkey: Hotkey?) {
        bindings.assign(hotkey, to: action)
        store.hotkeys = bindings
        activate()
    }

    /// Puts every chord back to what shipped.
    func resetToDefaults() {
        bindings = .default
        store.hotkeys = bindings
        activate()
    }

    // MARK: - Dispatch

    /// Runs an action as if its chord had been pressed. The one entry point, so
    /// a test never has to press a real key to check what a hotkey does.
    func perform(_ action: HotkeyAction) {
        actions[action]()
    }

    // MARK: - What the interface reads

    /// The chord bound to an action, in words: `⌘⌥L`, or a dash when the user
    /// cleared it.
    func displayString(for action: HotkeyAction) -> String {
        bindings[action]?.displayString ?? "—"
    }

    /// Why a binding is not working, or `nil` when it is.
    ///
    /// The reasons read differently because the user's next step differs: a chord
    /// another application owns is fixed by picking another one, a chord that is
    /// not a chord at all (a preferences file edited by hand) is fixed by adding a
    /// modifier, and no chord at all is fixed by choosing one.
    ///
    /// **An action with no chord counts as a problem**, and that is the case this
    /// method used to be silent about. Since ADR-0008 a press is the only path to
    /// the model — there is no button in the overlay for either genre — so an
    /// action nothing is bound to is not a preference, it is a feature that does
    /// not exist, and the user finds out mid-interview. Even the deliberate case
    /// is stated: the picker already shows «Выключено», so this adds what the
    /// picker cannot — that the action will not run.
    func problem(with action: HotkeyAction) -> String? {
        guard let hotkey = bindings[action] else {
            return bindings.isCleared(action)
                ? String(localized: "Комбинация для «\(action.title)» снята — действие не сработает, пока вы не выберете новую.")
                : String(localized: "Действию «\(action.title)» не досталось комбинации — выберите её в списке, иначе оно не сработает.")
        }
        guard unavailable.contains(action) else { return nil }
        guard hotkey.isValid else {
            return String(localized: "Комбинация \(hotkey.displayString) не годится для глобального хоткея: нужен хотя бы один из ⌘, ⌥, ⌃.")
        }
        return String(localized: "Комбинацию \(hotkey.displayString) уже занимает другое приложение — выберите другую.")
    }
}
