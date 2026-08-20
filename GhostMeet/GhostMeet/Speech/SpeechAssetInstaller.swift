//
//  SpeechAssetInstaller.swift
//  GhostMeet
//

import Foundation
import Speech

/// Where the system's language assets come from.
///
/// A seam for the same reason `SpeechModelProvider` is one: without it a test
/// that so much as hands over a turn reaches `AssetInventory`, and a test that
/// reaches `AssetInventory` downloads a language pack on a clean CI machine.
nonisolated protocol SpeechAssetInstaller: Sendable {
    /// Whether the system can recognise this language at all.
    func supports(_ locale: Locale) async -> Bool
    /// Installs what is missing; returns having done nothing if all is in place.
    func install(_ locale: Locale) async throws
}

/// The real one: `DictationTranscriber` plus `AssetInventory`.
@available(macOS 26, *)
nonisolated struct SystemSpeechAssets: SpeechAssetInstaller {

    func supports(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
        return await DictationTranscriber.supportedLocales.contains { candidate in
            let identifier = candidate.identifier(.bcp47)
            return identifier == wanted || identifier.hasPrefix(language + "-")
        }
    }

    func install(_ locale: Locale) async throws {
        let module = NativeSpeechRecognizer.transcriber(for: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            return
        }
        try await request.downloadAndInstall()
    }
}
