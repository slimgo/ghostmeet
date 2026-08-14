//
//  TranscriptSaving.swift
//  GhostMeet
//

import AppKit
import Foundation
// Explicit, because `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on:
// `UTType` reaches this file through AppKit but its members do not.
import UniformTypeIdentifiers

/// Writing the saved call to a file the user chose.
///
/// **A panel, not a folder of ours.** Until this feature the app wrote nothing to
/// disk at all — not one `write(to:)` anywhere — and the promise in the README is
/// that nothing lands there unless the user puts it there. A save panel keeps
/// that literally true: the file exists because somebody pointed at a place for
/// it, not because a setting was left on.
@MainActor
enum TranscriptSaving {

    /// What to call the file before the user renames it. Sortable first, readable
    /// second: a folder of these lines up chronologically on its own.
    static func suggestedName(for moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "GhostMeet-\(formatter.string(from: moment)).md"
    }

    /// Asks where to put the file and writes it.
    ///
    /// Returns a sentence for the window when it could not be written, and `nil`
    /// both on success and on cancel — a user who closed the panel did not fail
    /// at anything and has nothing to be told.
    ///
    /// The report goes back to the caller rather than to a system notification,
    /// for the same reason every other failure in this app does: a banner is
    /// drawn on top of the shared screen (ADR-0004).
    static func save(_ markdown: String, suggestedName name: String) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.title = "Сохранить диалог"

        // The overlay is a non-activating panel, so without this the save sheet
        // can come up behind the call. Focus returns to the call window as soon
        // as the panel closes — GhostMeet stays an accessory and never becomes
        // the active app on its own.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Не удалось сохранить: \(error.localizedDescription)"
        }
    }
}
