//
//  ResumeImport.swift
//  GhostMeet
//

import Foundation
import Observation

/// Filling a profile in from a resume: read the file, ask the model, hand the
/// result back for the user to edit and approve.
///
/// The point of the middle step is that nothing is applied behind the user's
/// back. The model proposes; the person decides. Until `apply(to:)` is called
/// the settings store has not changed, and cancelling leaves the profile exactly
/// as it was.
///
/// **Nothing about the file survives this type.** The path is used once, the
/// text lives in a local variable for the duration of one request, and neither
/// is written to disk, to `UserDefaults` or to a log. What remains afterwards is
/// the profile the user approved — the same `UserProfile` the three text fields
/// produce, in the same library, with no separate «profile from a resume»
/// anywhere in the app.
///
/// The request is one-shot background work, not a suggestion: it never enters
/// the suggestion feed and is not cancelled by a press (ADR-0008 governs
/// answers to the conversation; this is setup before the call).
@MainActor
@Observable
final class ResumeImport {

    /// Where the import has got to. Everything the screen shows — the spinner,
    /// the sheet, the red line — is a reading of this.
    enum Phase: Equatable {
        case idle
        case reading
        case asking
        /// The model answered; `draft` is on screen and editable.
        case review
        /// Nothing was applied; the message explains why, inside the window and
        /// never as a system notification (ADR-0004).
        case failed(String)

        var isBusy: Bool { self == .reading || self == .asking }

        /// Shown next to the button while the work runs.
        var summary: String {
            switch self {
            case .idle, .review, .failed: ""
            case .reading: String(localized: "Читаю файл…")
            case .asking: String(localized: "Спрашиваю модель…")
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// What the model proposed, editable field by field before it is applied.
    /// Carries the id of the profile it was built for, so applying it updates
    /// that entry instead of creating another one.
    var draft: UserProfile = .empty

    /// Something true about the result the user should know — that the resume
    /// was too long to send whole, above all.
    private(set) var notice: String?

    @ObservationIgnored private var work: Task<Void, Never>?

    init() {}

    // MARK: - Running

    /// Fire-and-forget entry for the UI: import into the profile currently
    /// selected in `store`.
    ///
    /// The provider is read at the moment of the request rather than captured
    /// earlier, exactly like `SettingsStore.providerKeyReader` — a provider
    /// switched a second ago is the one that should get the resume.
    func start(url: URL, in store: SettingsStore) {
        let target = store.profile.id
        work?.cancel()
        work = Task { [weak self] in
            await self?.load(url: url, into: target) { try store.makeProvider() }
        }
    }

    /// The whole import, awaitable — the seam the tests drive.
    func load(
        url: URL,
        into target: UserProfile.ID,
        provider: @MainActor () throws -> any LLMProvider
    ) async {
        notice = nil
        phase = .reading

        let resume: ResumeDocument.Extract
        do {
            resume = try await Task.detached { try ResumeDocument.read(at: url) }.value
        } catch let failure as ResumeDocument.Failure {
            fail(failure.message)
            return
        } catch {
            fail(String(localized: "Файл не удалось прочитать: \(error.localizedDescription)."))
            return
        }
        guard !Task.isCancelled else { return }

        phase = .asking
        let answer: String
        let cutoff: SuggestionCutoff?
        do {
            let model = try provider()
            (answer, cutoff) = try await collect(
                model.stream(
                    ResumeProfilePrompt.request(
                        resumeText: resume.text,
                        isTruncated: resume.isTruncated
                    )
                )
            )
        } catch let failure as LLMFailure {
            fail(failure.message)
            return
        } catch is CancellationError {
            reset()
            return
        } catch {
            fail(String(localized: "Провайдер не ответил: \(error.localizedDescription)."))
            return
        }
        guard !Task.isCancelled else { return }

        var parsed = UserProfile.parsed(from: answer)
        guard !parsed.isEmpty else {
            // Оборвался и не собрался — тогда причина обрыва и есть объяснение,
            // и она куда полезнее общего «профиль не собрался». Без этой ветки
            // пользователь получал английскую системную строку об ошибке Swift.
            fail(cutoff?.message ?? String(localized: """
            Из ответа модели профиль не собрался: в нём нет ни роли, ни опыта, ни стека. \
            Попробуйте ещё раз, выберите другого провайдера — или заполните поля руками.
            """))
            return
        }

        // The draft belongs to the profile the user was editing: applying it
        // must fill that entry in, not add a fourth one to the list.
        parsed = UserProfile(
            id: target,
            name: parsed.name,
            role: parsed.role,
            experience: parsed.experience,
            stack: parsed.stack
        )

        draft = parsed
        // Две разные правды, и обе стоит сказать: резюме не влезло целиком — и
        // ответ модели кончился раньше времени. Профиль при этом собрался, и
        // выбрасывать его из-за подрезанной последней строки было бы хуже, чем
        // показать его с оговоркой.
        var notices: [String] = []
        if resume.isTruncated {
            notices.append(String(localized: """
            Резюме длинное: модель прочитала первые \(String(ResumeDocument.maxCharacters)) символов \
            из \(resume.originalCharacterCount). Проверьте, не потерялось ли что-то важное.
            """))
        }
        if let cutoff {
            notices.append(String(localized: "\(cutoff.message) Проверьте последние поля — они могли не дописаться."))
        }
        notice = notices.isEmpty ? nil : notices.joined(separator: "\n")
        phase = .review
    }

    // MARK: - Finishing

    /// Writes the approved draft into the profile it was built for. This is the
    /// only line in the import that changes anything the user keeps.
    func apply(to store: SettingsStore) {
        store.updateProfile(draft)
        reset()
    }

    /// Drops everything — the draft, the notice, the request still in flight.
    func cancel() {
        work?.cancel()
        reset()
    }

    /// Reports a failure the screen ran into before the import started, such as
    /// the open panel handing back an error instead of a file.
    func report(_ message: String) {
        fail(message)
    }

    private func fail(_ message: String) {
        draft = .empty
        notice = nil
        phase = .failed(message)
    }

    private func reset() {
        work = nil
        draft = .empty
        notice = nil
        phase = .idle
    }

    /// Everything the model said, plus the reason it stopped if it stopped early.
    ///
    /// One-shot collection: the stream exists because suggestions need to appear
    /// as they are written, and a profile is four lines nobody reads mid-flight.
    ///
    /// **The cutoff does not throw here, and that is the whole point.** A profile
    /// is four short lines and the budget is 512 tokens, so the answer that runs
    /// out of room is the one whose last line — the stack, a comma-separated
    /// list — got clipped. The first three lines are already correct and parse
    /// perfectly well; throwing them away to report that the fourth is short
    /// costs the user the import they were doing, for nothing.
    private func collect(
        _ stream: AsyncThrowingStream<String, any Error>
    ) async throws -> (answer: String, cutoff: SuggestionCutoff?) {
        var answer = ""
        do {
            for try await fragment in stream { answer += fragment }
            return (answer, nil)
        } catch let cutoff as SuggestionCutoff {
            return (answer, cutoff)
        }
    }
}
