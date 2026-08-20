//
//  OverlayWindowConfiguration.swift
//  GhostMeet
//

import AppKit

/// Everything that turns a plain window into a copilot overlay, in one place.
///
/// Each field exists because of a specific promise: float above everything, stay
/// out of screen capture, never take the keyboard focus away from the call.
/// The limits of the invisibility promise are in `docs/adr/0004-invisibility-scope.md`.
struct OverlayWindowConfiguration {

    /// Above ordinary windows and above another app's full-screen window.
    var level: NSWindow.Level

    /// Follows the user across Spaces, shows over full-screen apps, and stays out
    /// of Cmd+` window cycling and Mission Control.
    var collectionBehavior: NSWindow.CollectionBehavior

    /// `.none` keeps the window out of every screen capture: the user's screen
    /// sharing and the screenshots GhostMeet takes for itself (ADR-0004).
    var sharingType: NSWindow.SharingType

    /// `.nonactivatingPanel` is the part that keeps typing focus in the other app:
    /// the panel can be shown and clicked without activating GhostMeet.
    /// `.titled` + `.fullSizeContentView` gives a chromeless look that is still
    /// resizable by dragging the window edges.
    var styleMask: NSWindow.StyleMask

    var defaultContentSize: CGSize
    var minContentSize: CGSize

    /// Distance from the screen edge when the overlay is placed for the first time.
    var screenMargin: CGFloat

    var cornerRadius: CGFloat

    /// Lower bound is not 0: a fully transparent overlay is impossible to find again.
    var opacityRange: ClosedRange<Double>
    var defaultOpacity: Double

    static let overlay = OverlayWindowConfiguration(
        level: .screenSaver,
        collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle],
        sharingType: .none,
        styleMask: [.titled, .closable, .fullSizeContentView, .resizable, .nonactivatingPanel],
        defaultContentSize: CGSize(width: 420, height: 520),
        minContentSize: CGSize(width: 320, height: 220),
        screenMargin: 24,
        cornerRadius: 14,
        opacityRange: 0.3...1.0,
        defaultOpacity: 0.95
    )

    func clampOpacity(_ value: Double) -> Double {
        min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    /// Applies the configuration to a freshly built panel.
    func apply(to panel: NSPanel) {
        // Floating panel that never becomes the app's main window and never grabs
        // the keyboard unless a control genuinely needs text input.
        //
        // Order matters: `isFloatingPanel` pushes the window down to `.floating`,
        // so the level has to be assigned after it, not before.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true

        panel.level = level
        panel.collectionBehavior = collectionBehavior
        panel.sharingType = sharingType

        // Chromeless, with one exception — the red close button.
        //
        // It sits where it belongs on a Mac: top left. A custom button in the
        // right corner of the header used to play that part and was wrong twice
        // over — not the system one and on the wrong side; the user noticed
        // within the first minute. There is still nothing to miniaturise or zoom
        // with: the overlay is hidden with a chord, and there is nothing in it to
        // zoom.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        // The SwiftUI content draws its own rounded, translucent background.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.contentMinSize = minContentSize
    }
}
