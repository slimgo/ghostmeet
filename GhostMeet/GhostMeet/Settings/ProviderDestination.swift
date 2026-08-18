//
//  ProviderDestination.swift
//  GhostMeet
//

import Foundation

/// Where the text of a request physically ends up.
///
/// The app is BYOK and local-first, which is only worth anything if the user
/// can tell the two apart at the moment it matters. It matters most when the
/// text is a resume: a transcript fragment is one sentence of a conversation
/// the other party heard anyway, whereas a resume is the user's name, employers
/// and phone number in one file.
///
/// Derived from the *effective* base URL — the override when the user typed
/// one, the preset's default otherwise — so the answer follows what the app
/// will really do rather than what the preset was named. Anything that is not
/// demonstrably a local address counts as `cloud`: guessing wrong in that
/// direction is a promise of privacy the app cannot keep.
nonisolated enum ProviderDestination: Equatable, Sendable {

    /// A server on this machine — Ollama, LM Studio, llama.cpp.
    case localMachine

    /// A command-line tool. Where *it* sends the prompt is the tool's business
    /// and cannot be seen from here.
    case commandLineTool

    /// Somebody else's servers.
    case cloud

    /// Host names that mean "this machine".
    private static let localHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0",
    ]

    init(preset: ProviderPreset, selection: ProviderSelection) {
        guard preset.transport != .cli else {
            self = .commandLineTool
            return
        }
        let typed = selection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = typed.isEmpty ? preset.defaultBaseURL : typed
        self = Self.isLocal(effective) ? .localMachine : .cloud
    }

    private static func isLocal(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return localHosts.contains(host) || host.hasSuffix(".local")
    }

    /// The sentence shown next to the "load a resume" button, before it is
    /// pressed.
    ///
    /// The CLI case deliberately does **not** say "stays on this machine". A
    /// command-line tool is not a local model: `claude -p` and `codex exec`
    /// forward the prompt to their vendor exactly as the HTTP providers do, and
    /// the app has no way to tell one tool from another. Promising privacy here
    /// because the process happens to run locally would be the one lie this
    /// screen cannot afford.
    func resumeNote(providerName: String) -> String {
        switch self {
        case .localMachine:
            String(localized: """
            Текст резюме уйдёт локальному провайдеру «\(providerName)» по адресу на этой машине — \
            за её пределы он не выйдет.
            """)
        case .commandLineTool:
            String(localized: """
            Текст резюме уйдёт инструменту командной строки «\(providerName)»: дальше он отправит его туда, \
            куда ходит сам. Для облачных инструментов (Claude CLI, Codex CLI) это серверы их разработчика, \
            и данные покинут машину.
            """)
        case .cloud:
            String(localized: """
            Текст резюме уйдёт облачному провайдеру «\(providerName)»: имя, места работы и контакты \
            покинут эту машину. Если это нежелательно — выберите локального провайдера или заполните \
            поля руками.
            """)
        }
    }
}
