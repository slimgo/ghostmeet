//
//  ResumeDocument.swift
//  GhostMeet
//

import Foundation
import PDFKit

/// Pulls the text out of a resume file — and nothing else.
///
/// The file itself never leaves this type: it is read, its text is handed back,
/// and neither the bytes nor the path are stored, cached or logged anywhere.
/// What survives the import is the profile the user approves, which is the whole
/// of what the app is entitled to keep.
nonisolated enum ResumeDocument {

    /// Formats the picker offers. Deliberately short: these three cover an
    /// exported CV, and every additional one is a parser that can be wrong
    /// about a document quietly.
    static let fileExtensions = ["txt", "text", "md", "markdown", "pdf"]

    /// Upper bound on what is sent to the model.
    ///
    /// A ten-page CV with layout debris runs to tens of thousands of characters,
    /// all of it paid for and most of it employer addresses. The head of the
    /// document is kept because that is where the summary, the current role and
    /// the skills list sit — and the user is told when it was cut.
    static let maxCharacters = 12_000

    /// The text of a resume, with an honest note of how much of it was dropped.
    struct Extract: Equatable, Sendable {
        var text: String
        /// Length of the whole document, before clipping.
        var originalCharacterCount: Int

        var isTruncated: Bool { originalCharacterCount > text.count }
    }

    /// Why a file gave up no text, in words meant for the user.
    ///
    /// Every case is explained rather than reported: the failure that matters
    /// here — a scanned resume — looks exactly like success from the outside if
    /// nobody says otherwise, and the user would sit in front of an empty
    /// profile believing the import worked.
    enum Failure: Error, Equatable {
        case unsupportedFormat(String)
        case unreadable(String)
        case imageOnlyPDF
        case empty

        var message: String {
            switch self {
            case .unsupportedFormat(let ext):
                let named = ext.isEmpty ? String(localized: "Файл без расширения") : String(localized: "Файл «.\(ext)»")
                return """
                \(named) не подойдёт: GhostMeet читает резюме в форматах .txt, .md и .pdf. \
                Сохраните резюме в одном из них — или заполните поля профиля руками.
                """
            case .unreadable(let reason):
                return String(localized: "Файл не удалось прочитать: \(reason).")
            case .imageOnlyPDF:
                return """
                В этом PDF нет текстового слоя: резюме сохранено картинкой — скан или снимок страницы. \
                Извлекать из него нечего, поэтому профиль остался бы пустым. Сохраните резюме в PDF \
                с текстом (экспорт из Word, Pages, Google Docs), в .txt или .md — или заполните поля руками.
                """
            case .empty:
                return String(localized: "В файле нет текста — собирать профиль не из чего.")
            }
        }
    }

    /// Reads the file and returns its text, clipped to `maxCharacters`.
    ///
    /// Synchronous and `nonisolated`: the caller runs it off the main actor,
    /// because a large PDF takes long enough to be noticed as a frozen window.
    static func read(at url: URL) throws -> Extract {
        // With the sandbox off this grants nothing, but a file chosen through
        // the open panel is security-scoped whenever the sandbox is on, and
        // reading it without this would fail for no visible reason.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard fileExtensions.contains(ext) else { throw Failure.unsupportedFormat(ext) }
        return try clipped(ext == "pdf" ? pdfText(at: url) : plainText(at: url))
    }

    // MARK: - Formats

    private static func plainText(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }

        if let text = String(data: data, encoding: .utf8) { return text }
        // Only with a byte-order mark: without one, arbitrary bytes of even
        // length decode as UTF-16 "successfully" and produce garbage.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        // A Russian CV exported by an old Windows editor is the realistic
        // non-UTF-8 case.
        if let text = String(data: data, encoding: .windowsCP1251) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw Failure.unreadable(String(localized: "не удалось определить кодировку текста"))
    }

    private static func pdfText(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw Failure.unreadable(String(localized: "файл не открывается как PDF — возможно, он повреждён"))
        }
        guard !document.isLocked else {
            throw Failure.unreadable(String(localized: "PDF защищён паролем"))
        }
        guard document.pageCount > 0 else {
            throw Failure.unreadable(String(localized: "в PDF нет страниц"))
        }

        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = pages.joined(separator: "\n")
        // A page-count above zero and no text at all means the pages are
        // pictures. This is the one failure that has to be named: it is
        // indistinguishable from an empty profile unless somebody says so.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.imageOnlyPDF
        }
        return text
    }

    // MARK: - Tidying

    private static func clipped(_ text: String) throws -> Extract {
        let tidied = tidied(text)
        guard !tidied.isEmpty else { throw Failure.empty }
        let length = tidied.count
        guard length > maxCharacters else {
            return Extract(text: tidied, originalCharacterCount: length)
        }
        return Extract(text: String(tidied.prefix(maxCharacters)), originalCharacterCount: length)
    }

    /// Squeezes out the layout debris PDF extraction leaves behind — trailing
    /// spaces and runs of blank lines. Not cosmetics: those characters are paid
    /// for by the token, and they push the useful half of a long CV past the
    /// clipping limit.
    private static func tidied(_ text: String) -> String {
        var lines: [String] = []
        var blankRun = 0
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for line in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            lines.append(trimmed)
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
