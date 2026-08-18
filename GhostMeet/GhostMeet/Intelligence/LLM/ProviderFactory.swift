//
//  ProviderFactory.swift
//  GhostMeet
//

import Foundation

/// The one place that turns "what the user picked" into "a thing that answers".
///
/// Everything above it — the engine, the composer, the overlay — sees only
/// `LLMProvider`, which is what ADR-0001 is for. Adding a backend means adding a
/// preset and a branch here, and nothing else in the app changes.
nonisolated enum ProviderFactory {

    /// Providers offered in the settings picker.
    ///
    /// Note how few distinct transports there are: everything from OpenRouter to
    /// a local llama.cpp speaks the same OpenAI dialect and differs only by base
    /// URL, model name and whether it wants a key. Base URL and model stay
    /// editable, so a provider absent from this list is still reachable.
    static let presets: [ProviderPreset] = [
        ProviderPreset(
            id: "anthropic",
            name: "Anthropic (Claude)",
            transport: .anthropic,
            defaultBaseURL: "https://api.anthropic.com",
            defaultModel: "claude-opus-5",
            needsKey: true,
            capabilities: .multimodal
        ),
        ProviderPreset(
            id: "openai",
            name: "OpenAI",
            transport: .openAICompatible,
            defaultBaseURL: "https://api.openai.com/v1",
            // The balanced member of the current frontier family; takes images,
            // which `Solve on screen` needs.
            defaultModel: "gpt-5.6-terra",
            needsKey: true,
            capabilities: .multimodal
        ),
        ProviderPreset(
            id: "gemini",
            name: "Google Gemini",
            transport: .gemini,
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            // Current stable Gemini: multimodal, and Flash rather than Pro
            // because this scenario pays for latency in seconds of silence on
            // camera. Editable, like every other model here.
            defaultModel: "gemini-3.6-flash",
            needsKey: true,
            capabilities: .multimodal
        ),
        ProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            transport: .openAICompatible,
            defaultBaseURL: "https://openrouter.ai/api/v1",
            // Same model as the Anthropic preset, reached through the router.
            defaultModel: "anthropic/claude-opus-5",
            needsKey: true,
            capabilities: .multimodal
        ),
        ProviderPreset(
            id: "polza",
            name: "Polza.AI",
            transport: .openAICompatible,
            defaultBaseURL: "https://api.polza.ai/api/v1",
            defaultModel: "openai/gpt-4o",
            needsKey: true,
            capabilities: .multimodal
        ),
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek",
            transport: .openAICompatible,
            // DeepSeek documents the base without `/v1`, and the `deepseek-chat`
            // alias stopped resolving on 24.07.2026 — V4 model ids only.
            defaultBaseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-v4-pro",
            needsKey: true,
            // V4 is text-only: `Solve on screen` here reasons over OCR alone.
            capabilities: .textOnly
        ),
        ProviderPreset(
            id: "kimi",
            name: "Kimi (Moonshot)",
            transport: .openAICompatible,
            defaultBaseURL: "https://api.moonshot.ai/v1",
            defaultModel: "kimi-k3",
            needsKey: true,
            // K3 is natively multimodal, unlike the K2 line it replaced.
            capabilities: .multimodal
        ),
        ProviderPreset(
            id: "ollama",
            name: String(localized: "Ollama (локально)"),
            transport: .openAICompatible,
            defaultBaseURL: "http://localhost:11434/v1",
            defaultModel: "qwen3:8b",
            needsKey: false,
            // Local servers take images only when a vision model is loaded, and
            // we cannot know that from here — so no screenshot is sent unless
            // the user says otherwise by editing the preset.
            capabilities: .textOnly
        ),
        ProviderPreset(
            id: "lmstudio",
            name: String(localized: "LM Studio (локально)"),
            transport: .openAICompatible,
            defaultBaseURL: "http://localhost:1234/v1",
            defaultModel: "local-model",
            needsKey: false,
            capabilities: .textOnly
        ),
        ProviderPreset(
            id: "llamacpp",
            name: String(localized: "llama.cpp server (локально)"),
            transport: .openAICompatible,
            defaultBaseURL: "http://localhost:8080/v1",
            defaultModel: "local-model",
            needsKey: false,
            capabilities: .textOnly
        ),
        ProviderPreset(
            id: "claude-cli",
            name: "Claude CLI",
            transport: .cli,
            defaultBaseURL: "",
            defaultModel: "",
            needsKey: false,
            capabilities: .textOnly,
            command: ["claude", "-p"]
        ),
        ProviderPreset(
            id: "codex-cli",
            name: "Codex CLI",
            transport: .cli,
            defaultBaseURL: "",
            defaultModel: "",
            needsKey: false,
            capabilities: .textOnly,
            command: ["codex", "exec"]
        ),
        ProviderPreset(
            id: "kimi-cli",
            name: "Kimi CLI",
            transport: .cli,
            defaultBaseURL: "",
            defaultModel: "",
            needsKey: false,
            capabilities: .textOnly,
            command: ["kimi"]
        ),
    ]

    static func preset(id: String) -> ProviderPreset? {
        presets.first { $0.id == id }
    }

    /// The default the app starts with: the strongest option for this scenario,
    /// where the primary mode is solving a task shown on screen.
    static let defaultSelection = ProviderSelection(presetID: "anthropic", baseURL: "", model: "")

    /// Builds the provider the user selected.
    ///
    /// `key` is passed in rather than read here so that this stays free of the
    /// settings and keychain layers — and so a test can hand it a literal.
    static func make(
        selection: ProviderSelection,
        key: @escaping @Sendable () async -> String?
    ) throws -> any LLMProvider {
        guard let preset = preset(id: selection.presetID) else {
            throw LLMFailure.provider(String(localized: "Неизвестный провайдер «\(selection.presetID)»."))
        }

        switch preset.transport {
        case .anthropic:
            return ClaudeProvider(apiKey: key)
        case .openAICompatible:
            return OpenAICompatibleProvider(
                configuration: try OpenAICompatibleProvider.Configuration.resolve(
                    preset: preset,
                    selection: selection
                ),
                apiKey: key
            )
        case .gemini:
            return GeminiProvider(
                apiKey: key,
                configuration: try GeminiProvider.Configuration.resolve(
                    preset: preset,
                    selection: selection
                )
            )
        case .cli:
            // No key: the tool answers on the subscription it is already logged
            // into. The model override is ignored on purpose — naming a model is
            // a per-tool flag, and guessing one would break the other tools.
            //
            // The command override is honoured here rather than by the settings
            // layer: an app launched from Finder inherits launchd's thin `PATH`,
            // so "give the full path to the tool" is the standard fix, and it
            // has to work no matter who assembles the provider.
            let command = selection.commandComponents.isEmpty
                ? preset.command
                : selection.commandComponents
            return CLIProvider(
                name: preset.name,
                configuration: CLIProvider.Configuration(command: command)
            )
        }
    }
}
