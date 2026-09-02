//
//  PromptFragments.swift
//  GhostMeet
//

import Foundation

/// The blocks more than one mode puts in its message, kept in one place.
///
/// Not a convenience: the heading of the screen block, the shape of the `Профиль`
/// block and the rules about what kind of question was asked are all *wording*,
/// and wording is what docs/GhostMeet-Prompts.md is authoritative about. Three
/// modes spelling «Текст с экрана (OCR):» separately is three chances to drift
/// from the document — and from each other, which is worse: the model would be
/// shown two different names for one thing depending on which chord the user
/// pressed.
///
/// The document still prints every prompt in full, and the tests compare the
/// assembled string against it. Composing from fragments is what makes the two
/// genres impossible to drift apart; the document is what keeps either of them
/// from drifting away from what is written down.
nonisolated enum PromptFragment {

    /// Heading of the block that carries what Vision read off the screen.
    /// Verbatim from docs/GhostMeet-Prompts.md §1 and §6.
    static let screenTextHeading = "Текст с экрана (OCR):"

    /// Names the question the press is about, when there is one.
    ///
    /// **Added because a live run answered the wrong question.** The transcript
    /// carries the whole call and nothing in it says which line is the current
    /// question. With a single question that is obvious; with two `Them` lines in
    /// a row — which is exactly what happens when the user reads a suggestion
    /// instead of answering aloud — the model has to guess, and it guessed the
    /// earlier one. The line stands last, right before the ask, because that is
    /// the strongest position in the message.
    ///
    /// Omitted entirely when there is no question yet rather than written empty:
    /// a bare «Сейчас он спросил:» reads as a question that was asked and not
    /// heard, which is a different and wrong claim.
    static func currentQuestion(in transcript: [Turn]) -> String? {
        TranscriptFormatter.currentQuestion(transcript).map { "Сейчас он спросил: «\($0)»" }
    }

    /// Heading the selected `Профиль` is written under — the `{{resume_context}}`
    /// slot of the prompt document, note 5.
    static let profileHeading = "Контекст о пользователе (резюме / роль / стек):"

    /// Heading the `Контекст собеседования` is written under — note 7.
    ///
    /// Named for what it is rather than "context": the app already has one
    /// «контекст», the conversation, and it is the one a hotkey clears. These are
    /// the answers the user drafted before the call, and calling them заготовки
    /// keeps the two apart in the one place where the model reads both.
    static let interviewContextHeading = "Заготовки пользователя к этому собеседованию:"

    /// Who is who in the transcript, and what one line of it means.
    ///
    /// The second sentence is not decoration. `Them` is declared as
    /// «собеседник(и)», and before turns were merged a question broken by a pause
    /// arrived as two `Them:` lines — which reads as two people, and an answer to
    /// two people is the «давай обсудим, какой вариант вам ближе» the user
    /// complained about. The merge is done by `TranscriptFormatter`; this says
    /// out loud that it was done.
    ///
    /// The third sentence bans what the first two teach. `Them:` and `You:` are
    /// explained here and nowhere else, and the only thing the prompt ever said
    /// about service markup in the *answer* was «не выводи служебные или
    /// системные XML-теги» — one class closed, this one left open. A live gemini
    /// run came back as «Them: Давайте про event loop… / You: setTimeout…»: the
    /// model took the input format for the output format, in the paragraph that
    /// describes the input format. The ban therefore stands next to what causes
    /// it, and shows the shape rather than only forbidding it — a positive
    /// template plus a one-line «не так / а так» pair, the construct that already
    /// repaired the register. The example is deliberately about profiling, which
    /// is in none of the trial questions, so nothing here can be copied as an
    /// answer.
    static let channels = """
    «Them» — собеседник(и), «You» — пользователь. Реплики, разорванные паузой, уже склеены: одна строка «Them: …» — это один человек и одна мысль. Метки — разметка входа, в ответе их нет: первая строка ответа начинается сразу со слов пользователя — не «You: я бы начал с профилирования», а «Я бы начал с профилирования».
    """

    /// Who the text belongs to — the paragraph that reframes the whole answer,
    /// plus one «не так / а так» pair (note 6).
    ///
    /// **Written for a weak instruction-follower, not for a strong one.** The
    /// model the user actually runs is gpt-4o through polza.ai, and every word
    /// here answers a failure it produced live. The old rule «Пиши от первого
    /// лица, готовыми к произнесению фразами» was already in the prompt and did
    /// not work: it says nothing about *whose* first person and *who is
    /// listening*, so the model kept writing «Используйте Hash Map», which the
    /// user would then read out loud as an instruction to his own interviewer.
    ///
    /// Three properties are load-bearing and must not be "tidied away":
    ///
    /// 1. **The frame comes before the rules.** A statement about what the text
    ///    *is* (his next sentence, in his voice) sets the register; a rule buried
    ///    third in a list of ten reads as one more stylistic note.
    /// 2. **A positive pattern beats a prohibition.** Told only «не пиши в
    ///    императиве», a weak model routes around it by the letter — passive
    ///    voice, nominal sentences without a verb («Redis Sorted Set с окном —
    ///    ключи по минутам»), which is not second person and not speech either.
    /// 3. **The pair shows the register instead of describing it.** Two lines of
    ///    example did what three paragraphs of explanation had not.
    ///
    /// The example is deliberately about idempotency, *not* about the top-N
    /// question from the user's complaint. An example that answers a likely
    /// interview question turns into a template the model copies verbatim, and
    /// then any trial of the prompt measures copying rather than transfer.
    ///
    /// **The closing paragraph is the fence around the sample, and it is not
    /// optional.** A finished line of the right length, in the right register,
    /// with the pronunciation brackets in place, introduced by «А так» — that is
    /// a ready-made answer, and «А так» reads as «пиши так». On a question
    /// outside the user's stack (event loop against a Go profile) gemini-2.5-flash
    /// returned this very sample verbatim, twice out of three, payments and all.
    /// Cutting the pair was never an option — it is what measurably fixed the
    /// register — so the sample is fenced instead, and the fence is a *checkable
    /// sign* rather than an abstraction: three words that can only have come from
    /// here. A weak instruction-follower checks for a word far better than it
    /// honours a ban on copying.
    static let voice = """
    **Ты пишешь не ответ пользователю, а его собственную следующую фразу.** Через секунду он произнесёт её своим голосом вслух. Значит, это живая устная речь человека о своей работе — «я бы взял», «мы держали», «у нас это упиралось в», — а не абзац из справочника. Подлежащее — говорящий, а не слушатель. Сказуемое — глагол, а не «выполняется за», «это позволит», «рекомендуется». Исключение одно — блок кода: его не произносят, и внутри него ни первого лица, ни скобок с произношением.

    Не так — справка, её нельзя произнести:
    Используйте идемпотентный ключ на каждый платёж. Ключ рекомендуется хранить в Redis с TTL. Это позволит вам избежать дублей при повторной отправке.

    А так — речь, её произносят:
    Я вешаю на каждый платёж идемпотентный ключ и держу его в Redis (редисе) с TTL (ти-ти-эль) на сутки. Повтор тогда возвращает тот же результат, а не второе списание.

    Оба образца — из чужого разговора: там спрашивали про повторные списания в платежах, а спросят тебя про другое. Бери из них строй фразы, а не текст: увидел у себя слова «платёж», «идемпотентный», «списание» — значит, выдал образец вместо ответа; сотри и напиши про то, о чём спросили.
    """

    /// Permission to answer a question that is not about the user's stack —
    /// stated outright, because the prompt's own rules read as a ban on it.
    ///
    /// **This is a conflict of rules, not disobedience.** «Ни одного факта о
    /// пользователе, которого нет в контексте» stands fifth of eight in the list
    /// (the middle, which is background) and is repeated *alone* in the closing
    /// line (the strongest position in the whole text). Nowhere did the prompt
    /// ask for an answer on a foreign topic. Given a Go profile and a question
    /// about the JavaScript event loop, claude-haiku-4.5 concluded three times out
    /// of three that knowing JS would be a fact about the user it had no licence
    /// to invent — and refused, asked the interviewer a counter-question, and
    /// reasoned out loud about how to proceed. It executed rule five to the
    /// letter.
    ///
    /// The product answer is the opposite one and has to be said in the prompt:
    /// **knowing a topic is not a fact about the user.** He pressed the chord
    /// *because* he does not know; a refusal destroys the point of pressing.
    ///
    /// Two properties are load-bearing:
    ///
    /// 1. **The counterweight sits at a strong end, not in the list.** The block
    ///    goes right after `voice`, and the closing line of both genres now
    ///    carries both halves of the contract. Moving the ban instead of
    ///    balancing it would bring back the invented salaries it was put there
    ///    to stop.
    /// 2. **The negative sample is written without «ты» or «вы».** The first
    ///    draft ended it on a counter-question («ты спрашиваешь не о моём
    ///    стеке?») and the control question *inside* the stack immediately came
    ///    back in generalised second person («перевернёшь порядок — получишь
    ///    range scan»), losing the first person everywhere. A sample teaches its
    ///    pronouns along with its point.
    ///
    /// The positive sample is on a foreign topic on purpose: every other example
    /// in the prompt is written on the user's own stack (Redis, TTL, Postgres,
    /// миграция таблицы), so out of stack the model had nothing to copy the
    /// *shape* from — and dropped the pronunciation bracket and the first person
    /// together. Python and the GIL are far enough from any likely interview
    /// question to be useless as a stolen answer.
    static let outOfStack = """
    Вопрос запросто может оказаться не про его стек — на собеседовании это обычное дело, и нажимает он как раз на таком. Знание темы — не факт о пользователе: правило «ни одного факта о нём, которого нет в контексте» тему вопроса не закрывает. Разбирай предмет по существу и не приписывай ему опыта с ним; «это не мой стек» он скажет сам, если захочет.

    Не так — отказ, за ним и не нажимали:
    Погоди, это вопрос про JavaScript, а я backend на Go. Тут я не в теме — может, лучше про конкурентность в Go?

    А так — ответ по теме, за ним и нажимали:
    В питоне это упирается в GIL (джил): байткод в один момент исполняет только один поток.
    Поэтому на вводе-выводе потоки выигрывают, а на счёте нет.
    Тяжёлый счёт я бы вынес в отдельные процессы.
    """

    /// The rule that makes a term sayable, shared by every mode whose answer is
    /// read out loud (note 6).
    ///
    /// **The rule has no negative examples any more, and that is its whole
    /// point.** Three redactions in a row tried to forbid a shape by printing it:
    /// «и „бакеты (бакеты)“ — мусор», «не оригинал латиницей („промис
    /// (promise)“)», «не по слогам („мак-ро-таск“)». Each repaired the shape it
    /// named and taught the neighbouring one, and the third was measured
    /// properly: five models out of five, twelve spoiled brackets out of
    /// twenty-one, and **four of the twelve are verbatim copies of strings that
    /// existed only as prohibitions here** — «микротаски (микротаски)» came back
    /// from three different models, «промис (promise)» from a fourth. The other
    /// eight are the same shape applied to the neighbouring word.
    ///
    /// The conclusion is not about wording. A weak instruction-follower reads a
    /// prohibited example as a demonstration, so a rule that shows the failure
    /// *is* the failure's source, however firmly it is negated. The register
    /// frame gets away with a «не так / а так» pair because both halves are whole
    /// sentences from somebody else's conversation — copying one is visible. A
    /// two-word bracket is not: «микротаски (микротаски)» drops into an answer
    /// about the event loop and reads as if the model wrote it.
    ///
    /// What replaces them is positional. The alphabet test lives **inside** the
    /// trigger — «сразу за латинскими буквами — и только за ними» — so the rule
    /// does not fire on Cyrillic at all, rather than firing and then being told
    /// not to. All twelve measured failures have Cyrillic to the left of the
    /// bracket, so a rule that cannot start there closes every one of them
    /// without printing a single broken pair. The three cases are then *shown*
    /// on Kubernetes and «кластер» — Latin takes a bracket, Cyrillic does not,
    /// a repeat goes bare — which demonstrates the absence of a bracket instead
    /// of prohibiting its presence.
    ///
    /// What survives from earlier redactions, and why:
    ///
    /// - The unconditional trigger with the right to judge explicitly removed
    ///   («Решать, очевидно ли произношение, не нужно»). Its predecessor carried
    ///   two «только» and got brackets on three terms out of ~14: a reservation
    ///   of the form «только там, где это уместно» is read as permission not to
    ///   comply.
    /// - «Есть обычное русское слово — пиши сразу по-русски». Without it the
    ///   hard trigger made a model *insert* English to earn a bracket («живой
    ///   ecosystem (экосистема)», «рублей net (нет)»), which is worse than the
    ///   disease.
    /// - The hyphen bound, now phrased as what a hyphen *does* divide — words of
    ///   a term or letters of an abbreviation — rather than as a ban on
    ///   syllables. Syllable-splitting was never mentioned by any rule; it was
    ///   taught, because every positive sample is hyphenated and nothing bounded
    ///   how many hyphens a bracket may hold.
    /// - `GiST (джист)`, the one sample that proves the bracket carries live
    ///   speech rather than letter-by-letter transliteration.
    ///
    /// `camelCase (кэмел-кейс)` and «имя из кода» are the one addition: two
    /// models out of five left `setTimeout` and `then` bare, and identifiers are
    /// exactly what a screen task produces endlessly. The sample is from naming
    /// conventions rather than from any trial question, so copying it would show.
    ///
    /// The list is nine pairs, down from fifteen. What was cut was recognition
    /// fodder — a term the model matches against the list is not obeying the
    /// rule, and `microtask queue (майкротаск-кью)` in particular was scoring
    /// itself: it sat in the prompt verbatim and counted as a success in the very
    /// run it was copied into.
    ///
    /// The code exception is structural: `Assist` answers a screen task with a
    /// fenced block, and nobody reads an identifier out loud.
    /// The bracket rule is **for a Russian conversation only**.
    ///
    /// In an English interview the answer comes back in English — the answer
    /// follows the conversation — and a Cyrillic gloss in the middle of a spoken
    /// English sentence makes it unreadable. So in English the rule is simply not
    /// in the prompt: a rule that is absent cannot be half-obeyed, whereas a
    /// caveat «только когда по-русски» would be outweighed by the nine Cyrillic
    /// examples beside it — this project has recorded that examples get executed
    /// more readily than prohibitions get observed.
    /// The language of the answer, stated at the very end of the system prompt.
    ///
    /// **Measured, not assumed.** The prompt already said «Язык ответа — язык
    /// разговора» in the middle of a list, and on an English interview
    /// claude-haiku-4.5 answered in English **once in five runs** — the rest came
    /// back in Russian, which is what the user reported from a live call. With
    /// this line at the end: **ten out of ten in English**, and a Russian call
    /// stayed Russian three out of three.
    ///
    /// Two things make it work, and neither is the wording.
    ///
    /// 1. **Position.** This project has already recorded that a long prompt is
    ///    obeyed at its edges while its middle is background. The old sentence sat
    ///    third from the end of a list of ten.
    /// 2. **It names the trap instead of ignoring it.** The system prompt is 1328
    ///    words and 96 % Cyrillic, so the strongest signal about the answer's
    ///    language is the prompt itself. Saying «эти инструкции написаны
    ///    по-русски, но отвечать нужно по-английски» disarms exactly that signal;
    ///    an instruction that pretends the surrounding language does not exist
    ///    leaves the model to weigh one line against twelve hundred words.
    ///
    /// This is why the whole prompt is **not** translated into English. That was
    /// the obvious fix and it would have cost the Russian samples their register —
    /// «я бы взял», «у нас это упиралось в» is what teaches spoken Russian, and an
    /// English sample cannot teach it. One measured line does the same work.
    static func answerLanguage(_ language: ConversationLanguage) -> String {
        switch language {
        case .russian:
            "**ЯЗЫК ОТВЕТА — РУССКИЙ.** Разговор идёт на русском, и твой текст пользователь произнесёт вслух собеседнику."
        case .english:
            "**ЯЗЫК ОТВЕТА — АНГЛИЙСКИЙ.** Эти инструкции написаны по-русски, но отвечать нужно только по-английски: разговор идёт на английском, и твой текст пользователь произнесёт вслух собеседнику."
        }
    }

    static func pronunciation(for language: ConversationLanguage) -> String {
        language == .russian ? pronunciation : ""
    }

    static let pronunciation = """
    Пользователь читает твой текст вслух, а латиницу вслух не прочесть: **сразу за латинскими буквами — и только за ними — идёт скобка, и вслух вместо них пойдёт её содержимое**, как термин говорят в русскоязычной IT-среде, а не по буквам оригинала: B-tree (би-три), GiST (джист), nginx (энджин-икс), PostgreSQL (постгрес), hash map (хеш-мапа), camelCase (кэмел-кейс), TTL (ти-ти-эль), created_at (крейтед-эт), O(n log n) (о от эн лог эн). Решать, очевидно ли произношение, не нужно: увидел латиницу — слово, аббревиатуру, имя из кода, формулу — поставил скобку. **Слева от скобки всегда латиница: написанное кириллицей скобки не открывает вовсе.** Смотри: Kubernetes (кубернетис) — латиница, скобка; кластер — кириллица, скобки нет; Kubernetes второй раз — голым. Скобка одна на весь термин, каким бы длинным он ни был, и одна за ответ; внутри — русские буквы и произношение целиком, дефис делит слова термина или буквы аббревиатуры, и больше ничего. Формулу читай ровно как написана, лишних букв не приписывай. Есть обычное русское слово — пиши сразу по-русски («экосистема», «на руки»), латиницу ради скобки не вставляй. В блоке кода скобок нет: код не произносят.
    """

    /// What kind of question was asked, and how each kind is answered.
    ///
    /// The classification happens **inside this request**, not in one of its own:
    /// a second round trip would cost the user a second of silence in the moment
    /// the whole product is that second. So the rules are stated and the model
    /// applies them itself, which also means the category never narrows what is
    /// sent — the same transcript, the same profile and the same заготовки go out
    /// whichever kind it turns out to be, and a misread category costs a worse
    /// answer instead of a missing one.
    ///
    /// Four kinds and not a taxonomy of ten: a long list eats the system prompt
    /// and blurs every instruction in it. Every branch has to work with nothing
    /// filled in — an unfilled `InterviewContext` is the normal case, not an
    /// error — which is why each of them says what to do without its fields
    /// rather than assuming them.
    ///
    /// Deliberately silent about *length* — that is the difference between the two
    /// genres and is set by their own rules above. Saying so is not enough on its
    /// own, though: the STAR schema in the behavioural branch **is** a statement
    /// about length, expressed as a shape, and against «максимум 3–4 строки» it
    /// reads as a contradiction. The branch therefore says outright that the
    /// schema orders the facts and the genre sets the size; otherwise a
    /// behavioural question answered briefly comes back as a story cut in half.
    ///
    /// Two branches carry a **positive sample of the answer**, and both were
    /// added because the bare prohibition failed on a live model. Told only «не
    /// выдумывай компанию, проект, срок или цифру», every trialled variant
    /// invented exactly those: «план на две недели», «релиз прошёл без
    /// даунтайма», «через полгода вынесли за пару дней». Told «не называй от
    /// себя ни суммы», three variants out of three named one — «350–450 тысяч»,
    /// «400–500 тысяч на руки», «от двухсот до двухсот пятидесяти». A ban with
    /// no pattern beside it leaves the model with nothing to produce, so it
    /// produces the plausible thing; the sample gives it something to say
    /// instead. That is why the samples must survive editing: they are the
    /// working half of these two branches, not illustration.
    ///
    /// The behavioural sample is deliberately free of any company, date, metric
    /// or outcome claim — it is what a skeleton looks like, and the model copies
    /// its *shape* along with its emptiness.
    ///
    /// Two things about that sample were changed after a live run copied nine of
    /// its words verbatim («и работать вместе это не помешало») into an answer
    /// built from the user's own заготовка:
    ///
    /// - **The заготовка is now named before the skeleton, not beside it.** They
    ///   used to be one sentence, one «или» apart, and the model took both.
    /// - **Its story no longer rhymes with the typical заготовка.** While the
    ///   sample and the user's prepared story were both about an argument over a
    ///   migration, «взял из заготовок» and «скопировал образец» were
    ///   indistinguishable in the result. The sample is now build-vs-buy, and
    ///   every clause of it — the library, the interface — is topic-bound, so a
    ///   borrowed phrase shows up as nonsense rather than as a plausible tail.
    static let questionKinds = """
    Определи сам, какого рода вопрос задан, и отвечай по-разному:
    - **Технический** («как устроен B-tree», «чем GiST отличается от GIN», «как бы вы это масштабировали»): механика по существу — термин, цифра, компромисс, порядок действий. Биографию сюда не подмешивай: про опыт не спрашивали.
    - **Про опыт и поведение** («расскажите случай, когда…», «был ли конфликт в команде», «самая сложная задача»): одна конкретная история пользователя по схеме ситуация — задача — что сделал — результат. Схема задаёт порядок фактов, а не длину: объём берётся из правил жанра выше. Есть подходящая заготовка — рассказывай её и её словами. Заготовки нет — строй костяк из его роли и стека и оставь конкретику ему; вот чужой костяк, смотри на порядок шагов, а слова бери свои: «Был случай, когда мы с коллегой разошлись на ревью: он предлагал написать свою библиотеку, я — взять готовую. Я вынес спор не в личку, а на общий разбор с замерами. Сошлись на том, что берём готовую и прячем её за своим интерфейсом». Ни компании, ни проекта, ни срока, ни цифры, которых нет в контексте: он произнесёт это как факт о себе.
    - **Про компанию, мотивацию и условия** («почему именно мы», «ожидания по деньгам», «какие у вас вопросы»): отвечай заготовками пользователя к этому собеседованию. Нужной заготовки нет — дай одну нейтральную фразу и оставь конкретику ему, вот так: «По деньгам я ориентируюсь на рынок, вилку назову, когда пойму объём задач». Ни суммы, ни срока, ни факта о компании от себя не называй.
    - **Задача на экране** (код, алгоритм, тест, форма): считай её текущим вопросом, даже если Them ничего не спросил, и отвечай по правилам выше.
    """

    /// The screen block, or nothing at all when the screen gave up no text.
    ///
    /// The block is omitted rather than left empty on purpose: a bare heading
    /// reads to the model as "the screen is blank", which is a different — and
    /// usually wrong — statement about a screen that simply could not be grabbed.
    static func screenText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(screenTextHeading)\n\(trimmed)"
    }

    /// The system prompt with what is known about the user appended: the
    /// selected `Профиль` first, then the `Контекст собеседования`.
    ///
    /// Both are optional in the document and neither is optional here. Without
    /// the profile the model suggests experience the user does not have, which is
    /// a worse failure than a slow answer; without the заготовки the behavioural
    /// and motivation branches of `questionKinds` have nothing to answer from and
    /// fall back to generalities. An unfilled one of either adds nothing at all
    /// rather than an empty heading — a heading with nothing under it is not
    /// silence, it is a claim that there is nothing to say.
    ///
    /// The order is the order of ownership: the profile is about the person and
    /// outlives the call, the заготовки are about this call. Nothing reads them
    /// positionally, but the model sees the standing facts before the ones that
    /// change per company.
    static func system(
        _ rules: String,
        profile: UserProfile,
        interviewContext: InterviewContext = .empty
    ) -> String {
        var blocks = [rules]
        if !profile.isEmpty {
            blocks.append("\(profileHeading)\n\(profile.promptFragment)")
        }
        if !interviewContext.isEmpty {
            blocks.append("\(interviewContextHeading)\n\(interviewContext.promptFragment)")
        }
        return blocks.joined(separator: "\n\n")
    }
}
