//
//  BriefPrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the request for the **жанр «коротко»** — the default press (ADR-0008).
///
/// The genre exists because of what pressing means. The user does not press to
/// have the question answered for them: they know most of the answers. They press
/// when they do not know, do not remember or are unsure — and by then they are
/// already talking. What is missing is a term, a number, three bullets, a
/// distinction, and it is missing *now*, in the middle of a sentence that is
/// already under way. An essay from the start arrives too late to be said and too
/// long to be read while speaking.
///
/// That is also why the tone rules here are stricter than an assistant's. A
/// suggestion is spoken out loud whole, so anything addressed to the interlocutor
/// — «давай обсудим», a counter-question, a menu of options to choose from —
/// turns into the user saying it to their interviewer. The rules do not ask for
/// brevity and hope; they say what the text will be used for.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §9; this type is
/// its only implementation, and the two are changed together.
nonisolated enum BriefPrompt {

    /// How much of the conversation the genre reads: the whole call.
    ///
    /// A 45-minute interview is around 30 000 characters of transcript with both
    /// sides in it — one request, no compression (see
    /// `TranscriptFormatter.wholeCall`). The twelve-turn window this used to have
    /// was sized for a background Summarizer that does not exist, and it cost the
    /// model exactly the thing it needs to answer «а с чем сравнить?»: what was
    /// said before.
    static let transcriptWindow = TranscriptFormatter.wholeCall

    /// Budget for the genre — the 256–512 band the prompt document gives to the
    /// modes that produce something to be said aloud (note 4).
    ///
    /// A ceiling and a shape at once. Three or four lines of spoken Russian is
    /// 60–90 words, some 200–300 tokens; 512 leaves room for an identifier or a
    /// formula and no room for an essay. A budget that allowed one would get one.
    static let maxTokens = 512

    /// Stands in for the transcript before a single turn has been recognised.
    ///
    /// The block is never left empty and never sent as a bare heading: an empty
    /// heading reads to the model as "nothing was said", which is a different and
    /// usually wrong claim.
    static let emptyTranscriptPlaceholder = "(разговор пока не записан)"

    /// Heading of the block that carries what Vision read off the screen. Shared
    /// with every other mode — one thing, one name.
    static let screenTextHeading = PromptFragment.screenTextHeading

    /// One assembled request.
    ///
    /// The two halves of the screen arrive separately because they do not travel
    /// together: `screenText` goes to every backend, `screenshot` only to one
    /// that accepts images. Dropping the picture is the caller's decision — it is
    /// the one that knows the provider — and by the time a request exists it has
    /// been made.
    static func request(
        transcript: [Turn],
        profile: UserProfile,
        interviewContext: InterviewContext = .empty,
        screenText: String = "",
        screenshot: Data? = nil
    ) -> SuggestionRequest {
        let started = TranscriptFormatter.hasStartedAnswering(transcript)
        // The language of the conversation is read here rather than arriving as
        // a setting: it belongs to this call, and it changes exactly one rule of
        // the prompt.
        let language = ConversationLanguage.detected(in: transcript)
        return SuggestionRequest(
            systemPrompt: system(
                profile: profile,
                interviewContext: interviewContext,
                hasStartedAnswering: started,
                language: language
            ),
            userPrompt: user(
                transcript: transcript,
                screenText: screenText,
                hasStartedAnswering: started
            ),
            screenshot: screenshot,
            maxTokens: maxTokens
        )
    }

    /// Role and rules, with what is known about the user appended at the end.
    ///
    /// Both blocks ship in the MVP rather than being optional: the answer is said
    /// out loud in the first person, so experience the user does not have is worse
    /// than a slow answer — and the behavioural branch of the rules answers from
    /// the заготовки or from nothing.
    /// - Parameter language: the language of the conversation. Affects exactly
    ///   one thing — the pronunciation bracket rule; see `ConversationLanguage`.
    static func system(
        profile: UserProfile,
        interviewContext: InterviewContext = .empty,
        hasStartedAnswering: Bool = true,
        language: ConversationLanguage = .default
    ) -> String {
        PromptFragment.system(
            systemRules(hasStartedAnswering: hasStartedAnswering, language: language),
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
    ///
    /// The last line used to read «Дай то, чего мне не хватает» and worked
    /// against the whole system prompt: «дай мне» names the user as the
    /// addressee in the very last thing the model reads before generating, which
    /// is an invitation back into the «вот вам инструкция» register the rules
    /// above spend a paragraph forbidding. It now repeats the frame instead —
    /// last position, same contract.
    static func user(
        transcript: [Turn],
        screenText: String = "",
        hasStartedAnswering: Bool = true
    ) -> String {
        let window = TranscriptFormatter.format(transcript, limit: transcriptWindow)
        let screenBlock = PromptFragment.screenText(screenText).map { "\n\($0)\n" } ?? ""
        let question = PromptFragment.currentQuestion(in: transcript).map { "\($0)\n" } ?? ""
        return """
        Разговор:
        \(window.isEmpty ? emptyTranscriptPlaceholder : window)
        \(screenBlock)
        \(question)\(hasStartedAnswering ? Self.askContinuing : Self.askOpening)
        """
    }

    /// The closing ask, in the two shapes the moment of the press comes in.
    ///
    /// Last position in the last message the model reads, so it repeats the frame
    /// rather than naming the user as the addressee — see the note above. What
    /// differs between the two is a statement of fact, not of style: one of them
    /// is false at every press, and which one is known.
    static let askContinuing =
        "Я уже говорю вслух. Продолжи за меня с того места, где я остановился, — ровно то, чего мне не хватает, не повторяя сказанного мной."

    static let askOpening =
        "Я ещё не начал говорить. Напиши мою первую фразу — сразу по существу, без разгона и без пересказа вопроса."

    /// Verbatim from docs/GhostMeet-Prompts.md §9.
    ///
    /// **The shape of this prompt is as load-bearing as its words, and it is
    /// written for the model the user actually runs — gpt-4o through polza.ai,
    /// which follows instructions much more loosely than the tool these rules
    /// were trialled on.** Four properties are the fix for a live complaint and
    /// must not be "simplified":
    ///
    /// 1. **The contract stands at the top and is repeated in one line at the
    ///    bottom.** In a long system prompt both ends work and the middle is
    ///    background; the old prompt put the register rule third in a list of ten
    ///    and ended on reference data (the profile), so the strongest position
    ///    was spent on facts. The closing line is a repetition on purpose — it
    ///    costs a sentence and buys the rule that was ignored.
    /// 2. **`PromptFragment.voice` comes before the list, not inside it.** What
    ///    the text *is* has to be settled before any rule about how to write it.
    /// 3. **The list is short.** Fourteen bullets of equal weight were fog; eight
    ///    is what a weak follower still reads as rules.
    /// 4. **No bullet says «если это уместно».** Every reservation of that shape
    ///    was read as permission not to comply — that is precisely how the old
    ///    pronunciation rule died.
    ///
    /// The «ни одного факта о пользователе» bullet is not a style rule: with an
    /// empty `Контекст собеседования` every trialled variant invented a salary,
    /// a deadline or a shipped-without-incident outcome, and the user would have
    /// read it out loud as a fact about himself.
    ///
    /// **The closing line now carries three clauses and not one, and that is the
    /// point of it.** For a while it repeated the ban on invented facts alone —
    /// the strongest position in the text spent on one half of a contract — and
    /// the model drew the only conclusion available: a question outside the
    /// user's stack cannot be answered without inventing (see
    /// `PromptFragment.outOfStack`). The second clause is the other half of that
    /// contract; the third fences the samples the prompt itself hands over (see
    /// `PromptFragment.voice`). Do not «simplify» it back to one clause.
    ///
    /// Note the language rule: the answer follows the language of the
    /// conversation. Russian is never forced — the interview may well be in
    /// English.
    /// The opening paragraph, in the two shapes the moment of the press comes in.
    ///
    /// **This used to be one paragraph asserting «Он уже начал отвечать вслух»,
    /// and the assertion is false in the case the app is designed around.** A
    /// press force-closes the open `Them` turn — that is, the interviewer has just
    /// stopped and the candidate is still silent. The other case is real too (the
    /// press flushes `You` as well), so the sentence is chosen from the
    /// transcript rather than asserted; see `TranscriptFormatter.hasStartedAnswering`.
    ///
    /// Dropping the claim altogether was the wrong fix and was not taken: it is
    /// what stops the short genre from restarting the answer from the beginning,
    /// which was the original live complaint. The «не с начала» half therefore
    /// survives in both shapes — what changes is whether there is a sentence to
    /// continue.
    private static func systemRules(
        hasStartedAnswering: Bool,
        language: ConversationLanguage
    ) -> String {
    """
    Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка.

    \(PromptFragment.channels)

    \(hasStartedAnswering ? Self.pressedMidSentence : Self.pressedBeforeSpeaking)

    \(PromptFragment.voice)

    \(PromptFragment.outOfStack)

    \(PromptFragment.pronunciation(for: language))

    Говорит он коротко — он в середине собственной фразы:
    - Дай ровно то, чего не хватает: термин, цифру, различие, порядок из 2–4 шагов. Не пересказывай вопрос и не начинай ответ заново.
    - **Не больше 45 слов.** Каждую мысль — с новой строки, две-четыре строки, пустых строк между ними нет. Одним сплошным абзацем не пиши: его нельзя пробежать глазами, продолжая говорить. Без преамбулы, без вывода, без заголовков «Подход:», «Решение:», без «итак» и «надеюсь, это поможет».
    - Пункты — только там, где он и вслух перечислял бы по пальцам; каждый пункт тогда целая произносимая фраза, а не строка из справочника.
    - Ни одного слова в адрес собеседника: ни «используйте», «вы можете», «вам стоит», ни встречных вопросов, ни «давайте обсудим», ни нескольких вариантов на выбор — выбрать по дороге он не сможет, он читает подряд. Исключение одно: собеседник сам спросил, есть ли вопросы, — тогда вопрос и есть ответ, и берётся он из заготовок.
    - Ни одного факта, которого нет в контексте, — ни о пользователе, ни о компаниях, ни о рынке: ни компании, ни проекта, ни срока, ни цифры о нём самом, ни суммы. Выдуманное он произнесёт вслух как своё и не переживёт уточняющий вопрос. Речь про факты о нём, а не про темы: разобрать предмет не из его стека — не выдумка, а ответ.
    - Чего-то не хватает — скажи короче то, что можно сказать. «Я не знаю», «данных мало», «сложно сказать», «это не мой стек» он вслух не произнесёт. Не рассуждай, как тебе следует поступить, — пиши сразу готовую фразу. Про заготовки и про то, чего нет в контексте, тоже молчи: это служебное, а не речь.
    - Если на экране код или задача — дай недостающую строку, имя метода или оценку сложности, а не разбор целиком. Не описывай скриншот («я вижу на экране…»), не бери реплику в кавычки, не выводи служебные или системные XML-теги.
    - Язык ответа — язык разговора. Разговор по-русски — скобки с произношением обязательны; разговор по-английски — термины идут как есть.

    \(PromptFragment.questionKinds)

    **Главное, ещё раз: ты пишешь фразу, которую пользователь через секунду скажет вслух своим голосом. Первое лицо, живые глаголы, не больше 45 слов и каждая мысль с новой строки, у каждого термина латиницей — скобка с произношением, ни одного факта о нём, которого нет в контексте, — и ответ по существу, когда тема не из его стека. Образцы в этих правилах — чужой текст: ни одной их строки в ответе.**
    """
    }

    /// Why the press happened, in the shape that is true of this press.
    ///
    /// The «не с начала» half is in both on purpose: it is what stops the genre
    /// restarting the answer from the top, which was the original live complaint,
    /// and it holds whether or not a sentence is already under way.
    private static let pressedMidSentence =
        "Пользователь нажал хоткей, потому что чего-то не знает, не помнит или сомневается. Он **уже начал отвечать вслух** и ждёт недостающего куска, а не ответа с начала. Последняя строка `You` — то, что он уже произнёс: продолжай с неё и не пересказывай её."

    private static let pressedBeforeSpeaking =
        "Пользователь нажал хоткей, потому что чего-то не знает, не помнит или сомневается. Собеседник только что договорил, и **вслух он ещё ничего не сказал** — ему нужна фраза, с которой он начнёт: сразу по существу, без разгона и без пересказа вопроса."
}
