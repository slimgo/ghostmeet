//
//  HotkeyRegistry.swift
//  GhostMeet
//

import Carbon.HIToolbox
import Foundation
import os

/// Whatever makes a chord fire when GhostMeet is not the focused application.
///
/// A seam of its own, for the usual reason (ADR-0001) and for one specific to
/// tests: registering a real system-wide chord from a test would take that chord
/// away from the machine running it. `HotkeyCenter` is exercised against a fake
/// that only records what it was asked to register.
@MainActor
protocol HotkeyRegistry: AnyObject {

    /// Called on the main actor when a registered chord is pressed.
    var onPress: ((HotkeyAction) -> Void)? { get set }

    /// Replaces every registration with `bindings`.
    ///
    /// Returns the actions the system refused — normally because another
    /// application already owns the chord. The refusal is a fact the user has to
    /// see next to the binding: a hotkey that silently does nothing reads as a
    /// broken app.
    @discardableResult
    func replaceAll(with bindings: [HotkeyAction: Hotkey]) -> Set<HotkeyAction>
}

/// A registry that registers nothing.
///
/// For the Xcode preview, which builds and runs the real views: a preview that
/// used the Carbon registry would take four chords away from the machine the
/// developer is working on, and keep them until the preview process was killed.
@MainActor
final class InertHotkeyRegistry: HotkeyRegistry {

    var onPress: ((HotkeyAction) -> Void)?

    init() {}

    @discardableResult
    func replaceAll(with bindings: [HotkeyAction: Hotkey]) -> Set<HotkeyAction> { [] }
}

/// Global hotkeys through Carbon's `RegisterEventHotKey`.
///
/// **Why Carbon and not `NSEvent.addGlobalMonitorForEvents`.** The `NSEvent`
/// monitor is a keylogger as far as the system is concerned: it sees every key
/// press in every application, and macOS therefore gates it behind the
/// Accessibility permission. `RegisterEventHotKey` asks the window server to
/// deliver one specific chord to this process and needs **no permission at all**.
/// GhostMeet already asks for four (microphone, audio capture, screen recording,
/// speech recognition); a fifth — the one that reads as "this app can watch
/// everything you type" — for a secondary control path would be a bad trade.
///
/// The API is old but not deprecated, and it is what every menu-bar utility on
/// the platform still uses.
@MainActor
final class CarbonHotkeyRegistry: HotkeyRegistry {

    var onPress: ((HotkeyAction) -> Void)?

    /// Four bytes identifying our hot keys among everyone else's: `GHMT`.
    private static let signature: OSType = 0x4748_4D54

    private static let log = Logger(subsystem: "Mixxy.GhostMeet", category: "hotkeys")

    /// Registered chords by the numeric id Carbon reports back on a press.
    private var registered: [UInt32: (action: HotkeyAction, ref: EventHotKeyRef)] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {}

    @discardableResult
    func replaceAll(with bindings: [HotkeyAction: Hotkey]) -> Set<HotkeyAction> {
        unregisterAll()
        installHandlerIfNeeded()

        var refused: Set<HotkeyAction> = []
        // Sorted so the ids a run hands out do not depend on dictionary order —
        // it makes a log of two runs comparable, and nothing else depends on it.
        for (action, hotkey) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard hotkey.isValid else {
                refused.insert(action)
                continue
            }
            if register(hotkey, for: action) == false {
                refused.insert(action)
                Self.log.error(
                    "ХОТКЕЙ ЗАНЯТ действие=\(action.rawValue, privacy: .public) комбинация=\(hotkey.displayString, privacy: .public)"  // не переводится: журнал
                )
            }
        }

        // What the system actually gave us, for the same reason capture logs
        // what it started: "the hotkey does nothing" is a report we cannot act
        // on without knowing whether the chord was ever registered. Nothing here
        // reaches the user — the window says it, this is the trace left behind.
        let granted = registered.values
            .map { "\($0.action.rawValue)=\(bindings[$0.action]?.displayString ?? "?")" }
            .sorted()
            .joined(separator: " ")
        Self.log.info("ХОТКЕИ ЗАРЕГИСТРИРОВАНЫ: \(granted, privacy: .public)")  // не переводится: журнал

        return refused
    }

    private func register(_ hotkey: Hotkey, for action: HotkeyAction) -> Bool {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.modifiers.carbonValue,
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        registered[id] = (action, ref)
        return true
    }

    private func unregisterAll() {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            ghostMeetHotkeyEventHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    /// Called from the Carbon event handler once the press has been mapped back
    /// to one of ours.
    fileprivate func deliver(id: UInt32) {
        guard let entry = registered[id] else { return }
        onPress?(entry.action)
    }
}

/// The C callback Carbon hands the press to.
///
/// A free function rather than a closure: only a non-capturing function converts
/// to the `@convention(c)` pointer `InstallEventHandler` takes. The registry
/// travels as the opaque `userData` pointer, which is a plain address and so
/// crosses the isolation boundary without carrying anything non-`Sendable`.
private nonisolated func ghostMeetHotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    // Carbon delivers hot keys on the main run loop, so the common path costs no
    // hop at all — which is the whole point of the panic key. The asynchronous
    // branch is insurance, not the expected route.
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            Unmanaged<CarbonHotkeyRegistry>.fromOpaque(userData).takeUnretainedValue().deliver(id: id)
        }
    } else {
        // The registry travels as a bare address rather than as a pointer, so
        // nothing non-`Sendable` is captured on the way to the main actor.
        let address = UInt(bitPattern: userData)
        DispatchQueue.main.async {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            MainActor.assumeIsolated {
                Unmanaged<CarbonHotkeyRegistry>.fromOpaque(pointer).takeUnretainedValue().deliver(id: id)
            }
        }
    }
    return noErr
}
