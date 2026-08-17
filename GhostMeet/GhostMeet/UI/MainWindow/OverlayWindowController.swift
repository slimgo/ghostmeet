//
//  OverlayWindowController.swift
//  GhostMeet
//

import AppKit
import Combine
import SwiftUI

/// Owns the overlay panel: builds it from `OverlayWindowConfiguration`, restores its
/// geometry and opacity, and writes them back when the user moves, resizes or dims it.
///
/// The controller never calls `NSApp.activate(...)` and never uses
/// `makeKeyAndOrderFront(_:)` — that, together with `.nonactivatingPanel` and the
/// accessory activation policy, is what keeps the typing focus in the call.
final class OverlayWindowController: NSObject, ObservableObject, NSWindowDelegate {

    /// Window opacity, bound to the slider in `ContentView`.
    @Published var opacity: Double {
        didSet { applyOpacity() }
    }

    /// The session the overlay shows and drives. The controller only passes it
    /// on to the content view; window geometry and the session know nothing of
    /// each other.
    private let session: SessionController

    /// How far the recognition model has got. Passed straight through to the
    /// content view: the window geometry has no opinion about it, but the
    /// overlay is the only place the user can see it mid-call.
    private let recognition: SpeechModelStatus

    /// The global chords. Passed straight through to the content view, which is
    /// where they are re-bound — the panic key hides this very window, so the
    /// chord that brings it back has to be written down inside it.
    private let hotkeys: HotkeyCenter

    /// What the readiness strip reads: profiles, provider, source application.
    /// Passed straight through, like the two above — window geometry has no
    /// opinion about any of it.
    ///
    /// Optional, and `nil` only where there is no user to be armed: the window
    /// tests build this controller to check that the panic key hides a panel,
    /// and handing them a settings store would mean either the real one or a
    /// stand-in full of placeholders. The strip is then simply absent.
    private let settings: SettingsStore?

    /// Whether a newer build exists — passed through for the same reason and
    /// with the same `nil` case as the store above: the window tests have no
    /// user to be out of date.
    private let updates: AppUpdater?

    /// Opening the settings window is somebody else's job — the overlay only
    /// has the button. In accessory mode there is no menu bar to put it in.
    private let openSettings: OpenSettings

    private let configuration: OverlayWindowConfiguration
    private let stateStore: WindowStateStore
    private var panel: OverlayPanel?

    init(
        session: SessionController,
        recognition: SpeechModelStatus,
        hotkeys: HotkeyCenter,
        openSettings: @escaping OpenSettings,
        settings: SettingsStore? = nil,
        updates: AppUpdater? = nil,
        configuration: OverlayWindowConfiguration = .overlay,
        stateStore: WindowStateStore = WindowStateStore()
    ) {
        self.session = session
        self.recognition = recognition
        self.hotkeys = hotkeys
        self.openSettings = openSettings
        self.settings = settings
        self.updates = updates
        self.configuration = configuration
        self.stateStore = stateStore
        self.opacity = configuration.clampOpacity(stateStore.opacity ?? configuration.defaultOpacity)
        super.init()
    }

    // MARK: - What the content view is allowed to read

    var opacityRange: ClosedRange<Double> { configuration.opacityRange }

    var cornerRadius: CGFloat { configuration.cornerRadius }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Невидимость для захвата экрана

    /// Whether the app's windows are kept out of screen capture.
    ///
    /// `true` on every launch and **deliberately not persisted**. A switch that
    /// survived a restart would eventually be found in the state somebody left it
    /// in a week ago while recording a demo — and found during an interview, on
    /// the shared screen. The safe value is therefore the only one the app ever
    /// starts in; making the window visible is a decision taken again each time.
    @Published private(set) var isHiddenFromCapture: Bool = true

    /// What the flag means to a window. `.readOnly` — not `.readWrite` — is what
    /// an ordinary macOS window uses: capture may read it, nobody may draw into it.
    var captureSharingType: NSWindow.SharingType { isHiddenFromCapture ? .none : .readOnly }

    /// What the panel actually carries right now, or `nil` before it is built.
    ///
    /// Exists so the promise can be checked where it is kept — on the window —
    /// rather than on the field that was supposed to reach it. The two came
    /// apart once already in this project: `INFOPLIST_KEY_*` set values that
    /// never landed in the bundle, and the build said nothing.
    var windowSharingType: NSWindow.SharingType? { panel?.sharingType }

    /// Called whenever the flag changes, so the app's *other* windows follow.
    ///
    /// The settings window carries the same protection, and a demo of the
    /// settings screen is impossible while only the overlay obeys the switch.
    /// A closure rather than a reference, because the overlay has no business
    /// knowing that a settings window exists.
    var onCaptureVisibilityChange: ((NSWindow.SharingType) -> Void)?

    /// Turns the app's invisibility to screen capture on or off.
    ///
    /// **Refused while the session is listening** — that rule lives in the caller
    /// (`ContentView` disables the control), because the window layer has no
    /// opinion about what a call is. What lives here is the guarantee that a
    /// change reaches the panel at once: `sharingType` is read by the window
    /// server on the next frame, so no relaunch is involved.
    func setHiddenFromCapture(_ hidden: Bool) {
        guard hidden != isHiddenFromCapture else { return }
        isHiddenFromCapture = hidden
        panel?.sharingType = captureSharingType
        onCaptureVisibilityChange?(captureSharingType)
    }

    // MARK: - Visibility

    /// Puts the overlay on screen **without** activating GhostMeet.
    func show() {
        loadedPanel().orderFrontRegardless()
    }

    /// Takes the overlay off screen. Nothing else stops: this is only the window.
    func hide() {
        panel?.orderOut(nil)
    }

    /// Backing action for the show/hide (panic) hotkey.
    ///
    /// **Hiding stops nothing but the window.** Capture keeps running, turns keep
    /// closing, suggestions keep arriving — the user pressed this because
    /// somebody walked up behind them, not because the interview ended, and a
    /// panic key that also dropped the session would cost them the next question.
    /// `applicationShouldTerminateAfterLastWindowClosed` returns `false` for the
    /// same reason.
    func toggleVisibility() {
        isVisible ? hide() : show()
    }

    // MARK: - Panel construction

    private func loadedPanel() -> OverlayPanel {
        if let panel { return panel }
        let created = makePanel()
        panel = created
        return created
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: CGRect(origin: .zero, size: configuration.defaultContentSize),
            styleMask: configuration.styleMask,
            backing: .buffered,
            defer: false
        )
        configuration.apply(to: panel)
        // The configuration ships `.none`; this makes the panel obey the switch
        // even if it was flipped before the window was ever built.
        panel.sharingType = captureSharingType
        panel.delegate = self

        let hostingView = NSHostingView(
            rootView: ContentView(
                controller: self,
                session: session,
                recognition: recognition,
                settings: settings,
                updates: updates,
                hotkeys: hotkeys,
                openSettings: openSettings
            )
        )
        // Empty sizing options: otherwise the hosting view imposes the SwiftUI
        // content's ideal size on the window and overrides the restored frame.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        restoreGeometry(of: panel)
        panel.alphaValue = CGFloat(configuration.clampOpacity(opacity))
        return panel
    }

    // MARK: - Geometry and opacity persistence

    private func restoreGeometry(of panel: OverlayPanel) {
        if let stored = stateStore.frame, isOnSomeScreen(stored) {
            panel.setFrame(stored, display: false)
        } else {
            panel.setContentSize(configuration.defaultContentSize)
            placeInDefaultCorner(panel)
        }
    }

    /// A frame saved on a monitor that is no longer attached would put the overlay
    /// out of reach, so it is discarded in favour of the default position.
    private func isOnSomeScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    /// Top-right corner: out of the way of the call window and of a shared editor.
    private func placeInDefaultCorner(_ panel: OverlayPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            CGPoint(
                x: visible.maxX - size.width - configuration.screenMargin,
                y: visible.maxY - size.height - configuration.screenMargin
            )
        )
    }

    private func applyOpacity() {
        let clamped = configuration.clampOpacity(opacity)
        panel?.alphaValue = CGFloat(clamped)
        stateStore.opacity = clamped
    }

    private func persistFrame() {
        guard let panel, panel.isVisible else { return }
        stateStore.frame = panel.frame
    }

    /// Красная кнопка закрывает **приложение**, а не окно.
    ///
    /// У окна нет второго способа вернуться: значка в Dock нет, строки меню нет,
    /// ⌘-Tab тоже пуст. Закрытое окно оставило бы работающую программу, которую
    /// не видно и до которой не добраться иначе как аккордом, — то есть ровно ту
    /// ловушку, из-за которой кнопка и появилась.
    ///
    /// Отказ во время прослушивания живёт не здесь, а в самой кнопке: она гаснет
    /// вместе с `.closable`, и по красной кнопке, которая ничего не делает,
    /// щёлкать не приходится. Проверка всё равно повторена — окно закрывают не
    /// только мышью.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.canQuit else { return false }
        NSApplication.shared.terminate(nil)
        return false
    }

    /// Гасит и зажигает красную кнопку вслед за прослушиванием.
    ///
    /// Через `isEnabled` самой кнопки, а не через `styleMask` окна. Первая
    /// версия снимала `.closable` — на вид то же самое, погашенный кружок macOS
    /// рисует и так, и так, — но `styleMask` менялся из `onAppear`, то есть
    /// посреди раскладки SwiftUI, и AppKit бросал на это исключение прямо в
    /// цикле отрисовки. Приложение падало при запуске, а под тестами это
    /// выглядело как «0 tests passed»: host-приложение умирало раньше первого
    /// теста, и прогон рапортовал успех, не выполнив ничего.

    func setCloseEnabled(_ enabled: Bool) {
        panel?.standardWindowButton(.closeButton)?.isEnabled = enabled
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        persistFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistFrame()
    }
}
