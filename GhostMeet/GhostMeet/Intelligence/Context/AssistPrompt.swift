//
//  AssistPrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the request for the `Assist` mode — **жанр «подробно»**, one of the two
/// genres a press can ask for (ADR-0008).
///
/// Its prompt decides for itself what the user needs right now: a line to say out
/// loud, or the solution to the task on screen. What makes it the *long* genre is
/// its budget and its tone; the short one is `BriefPrompt`, and it is the default
/// press. The genre is chosen by which chord was pressed, and the two differ in
/// exactly two things — how much room the answer gets and how it is meant to be
/// used. The rules about *what kind of question* was asked are the same in both
/// (`PromptFragment.questionKinds`), because those are about the interview and
/// not about the chord.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §1; this type is
/// its only implementation, and the two are changed together.
nonisolated enum AssistPrompt {

    /// How much of the conversation the mode reads: the whole call — the same
    /// window the short genre gets, for the same reason (`TranscriptFormatter.wholeCall`).
    ///
    /// Both genres answer one conversation; only the answer differs. Two windows
    /// would mean the long answer knew less about the call than the short one,
    /// which is exactly backwards.
    static let transcriptWindow = TranscriptFormatter.wholeCall

    /// Budget for the mode. `Assist` may have to answer with working code, so it
    /// sits at the top of the 2k–4k band the prompt document gives it, unlike the
    /// short genre which gets by on a few hundred.
    static let maxTokens = 4096

    /// Stands in for the transcript before a single turn has been recognised. An
    /// empty transcript must not fail the request: the overlay has to answer from
    /// the screen alone if that is all there is.
    static let emptyTranscriptPlaceholder = "(разговор пока не записан)"

    /// Heading of the block that carries what Vision read off the screen.
    ///
    /// Same wording as the `Ask` and `Solve on screen` prompts in
    /// docs/GhostMeet-Prompts.md §5 and §6 — one thing, one name, whichever mode
    /// is asking, which is why the constant itself is shared.
    static let screenTextHeading = PromptFragment.screenTextHeading

    /// One assembled request. Every mode-specific decision — prompt, window
    /// size, token budget — is made here, which is why `LLMProvider` needs to
    /// know nothing about modes.
    ///
    /// The two halves of the screen arrive separately because they do not
    /// travel together: `screenText` goes to every backend, `screenshot` only to
    /// one that accepts images. Dropping the picture is the caller's decision —
    /// it is the one that knows the provider — and by the time a request exists
    /// it has been made.
    static func request(
        transcript: [Turn],
        profile: UserProfile,
        interviewContext: InterviewContext = .empty,
        screenText: String = "",
        screenshot: Data? = nil
    ) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: system(
                profile: profile,
                interviewContext: interviewContext,
                language: ConversationLanguage.detected(in: transcript)
            ),
            userPrompt: user(transcript: transcript, screenText: screenText),
            screenshot: screenshot,
            maxTokens: maxTokens
        )
    }

    /// Role and rules, with what is known about the user appended at the end.
    ///
    /// The profile ships in the MVP rather than being optional: without it the
    /// model suggests experience the user does not have, which is a worse failure
    /// than a slow answer. The `Контекст собеседования` is beside it for the same
    /// reason — the behavioural and motivation branches of the rules answer from
    /// the заготовки, and invented ones are the failure they exist to prevent.
    /// - Parameter language: the language of the conversation. Affects exactly
    ///   one thing — the pronunciation bracket rule, which in an English
    ///   interview is unnecessary and harmful; see `ConversationLanguage`.
    static func system(
        profile: UserProfile,
        interviewContext: InterviewContext = .empty,
        language: ConversationLanguage = .default
    ) -> String {
        PromptFragment.system(
            systemRules(language: language),
            profile: profile,
            interviewContext: interviewContext
        )
    }

    /// The transcript window, what is written on the screen, and the ask.
    ///
    /// The screen block is omitted rather than left empty when there is no text:
    /// an empty heading reads to the model as "the screen is blank", which is a
    /// different and usually wrong statement about a screen that simply could
    /// not be grabbed.
    static func user(transcript: [Turn], screenText: String = "") -> String {
        let window = TranscriptFormatter.format(transcript, limit: transcriptWindow)
        let screenBlock = PromptFragment.screenText(screenText).map { "\n\($0)\n" } ?? ""
        let question = PromptFragment.currentQuestion(in: transcript).map { "\($0)\n" } ?? ""
        return """
        Разговор:
        \(window.isEmpty ? emptyTranscriptPlaceholder : window)
        \(screenBlock)
        \(question)Сделай то, что нужно мне прямо сейчас: если это разговор — напиши моими словами, что мне сейчас говорить; если на экране задача — реши её.
        """
    }

    /// Verbatim from docs/GhostMeet-Prompts.md §1.
    ///
    /// **The register fix landed here too, and not out of symmetry.** The user's
    /// complaint came with answers from both genres: the model addressed him
    /// («Используйте Hash Map») and dropped the pronunciation brackets in both.
    /// The frame, the pronunciation rule and the closing one-line contract are
    /// therefore the same shared fragments the short genre uses — see
    /// `PromptFragment.voice` and `BriefPrompt.systemRules` for what each
    /// construct is defending against, since all of it is written for a loose
    /// instruction-follower (gpt-4o) rather than for the tool it was trialled on.
    ///
    /// The rule about «я не знаю» arrived here late and not for symmetry: this
    /// genre never had one, while the refusal that made it necessary («это
    /// вопрос про JavaScript, а я backend на Go») came from a question outside
    /// the user's stack — and such a question reaches this chord exactly as
    /// readily as the short one. See `PromptFragment.outOfStack`.
    ///
    /// One thing is genre-specific: **code is the exception to being said out
    /// loud.** This genre answers a screen task with a fenced block, and a
    /// bracket with a Russian pronunciation inside an identifier would be
    /// garbage — the rule says so where the code rule is, not as a footnote.
    ///
    /// Note the language rule: the answer follows the language of the
    /// conversation and of the task on screen. Russian is never forced — the
    /// interview may well be in English.
    private static func systemRules(language: ConversationLanguage) -> String {
        """
        Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка или работы с задачей.

        \(PromptFragment.channels)

        Пользователь нажал хоткей развёрнутого разбора: тема незнакома ему целиком, и одной недостающей строки не хватит. Посмотри на скриншот (если есть) и разговор, реши, что нужно ему ПРЯМО СЕЙЧАС, и выдай это без преамбулы.

        \(PromptFragment.voice)

        \(PromptFragment.outOfStack)

        \(PromptFragment.pronunciation(for: language))

        Правила:
        - Если на экране задача (код, алгоритм, тест, форма) — кратко подход, затем готовое решение (код в fenced block), затем time/space complexity. Язык кода — как на экране, иначе Python. Код — единственное, что не произносят вслух: внутри блока кода ни первого лица, ни скобок с произношением не нужно.
        - Если это разговор — разбери текущий вопрос собеседника словами пользователя, от первого лица, чтобы пользователь говорил по написанному: суть, затем опора — примеры, цифры, компромиссы.
        - Ни одного слова в адрес собеседника: ни «используйте», «вы можете», «вам стоит», ни встречных вопросов, ни «давайте обсудим», ни нескольких вариантов на выбор — выбрать по дороге пользователь не сможет, он читает подряд. Исключение одно: собеседник сам спросил, есть ли вопросы, — тогда вопрос и есть ответ, и берётся он из заготовок.
        - «Я не знаю», «данных мало», «это не мой стек» он вслух не произнесёт: чего-то не хватает — скажи то, что сказать можно. И не рассуждай, как тебе следует поступить, — пиши сразу готовую фразу.
        - Ни одного факта, которого нет в контексте, — ни о пользователе, ни о компаниях, ни о рынке: ни компании, ни проекта, ни срока, ни цифры о нём самом, ни суммы. Выдуманное он произнесёт вслух как своё и не переживёт уточняющий вопрос. Речь про факты о нём, а не про темы: разобрать предмет не из его стека — не выдумка, а ответ. Про сами заготовки и про то, чего в контексте нет, не пиши ни слова: это служебное, а не речь.
        - Будь плотным и уверенным: длиннее короткого жанра, но без воды и без пересказа вопроса.
        - Не описывай скриншот («я вижу на экране…»). Не используй кавычки вокруг реплики «что сказать». Не выводи служебные или системные XML-теги.
        - Язык ответа — язык разговора / задачи на экране (обычно русский или английский).

        \(PromptFragment.questionKinds)

        **Главное, ещё раз: разговорную часть ответа пользователь через секунду скажет вслух своим голосом. Первое лицо, живые глаголы, у каждого термина латиницей — скобка с произношением, ни одного факта о нём, которого нет в контексте, — и ответ по существу, когда тема не из его стека. Образцы в этих правилах — чужой текст: ни одной их строки в ответе.**
        """
    }
}
