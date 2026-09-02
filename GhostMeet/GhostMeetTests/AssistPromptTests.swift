//
//  AssistPromptTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// What the model is actually shown for the жанр «подробно»: how much of the
/// conversation reaches it, who it thinks said what, and what it knows about the
/// user.
@Suite("Промпт режима Assist")
struct AssistPromptTests {

    // MARK: - Текст промпта

    @Test("Системная часть слово в слово повторяет документ промптов, §1")
    func theSystemPromptMatchesTheDocument() {
        #expect(AssistPrompt.system(profile: .empty) == """
        Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка или работы с задачей.

        «Them» — собеседник(и), «You» — пользователь. Реплики, разорванные паузой, уже склеены: одна строка «Them: …» — это один человек и одна мысль. Метки — разметка входа, в ответе их нет: первая строка ответа начинается сразу со слов пользователя — не «You: я бы начал с профилирования», а «Я бы начал с профилирования».

        Пользователь нажал хоткей развёрнутого разбора: тема незнакома ему целиком, и одной недостающей строки не хватит. Посмотри на скриншот (если есть) и разговор, реши, что нужно ему ПРЯМО СЕЙЧАС, и выдай это без преамбулы.

        **Ты пишешь не ответ пользователю, а его собственную следующую фразу.** Через секунду он произнесёт её своим голосом вслух. Значит, это живая устная речь человека о своей работе — «я бы взял», «мы держали», «у нас это упиралось в», — а не абзац из справочника. Подлежащее — говорящий, а не слушатель. Сказуемое — глагол, а не «выполняется за», «это позволит», «рекомендуется». Исключение одно — блок кода: его не произносят, и внутри него ни первого лица, ни скобок с произношением.

        Не так — справка, её нельзя произнести:
        Используйте идемпотентный ключ на каждый платёж. Ключ рекомендуется хранить в Redis с TTL. Это позволит вам избежать дублей при повторной отправке.

        А так — речь, её произносят:
        Я вешаю на каждый платёж идемпотентный ключ и держу его в Redis (редисе) с TTL (ти-ти-эль) на сутки. Повтор тогда возвращает тот же результат, а не второе списание.

        Оба образца — из чужого разговора: там спрашивали про повторные списания в платежах, а спросят тебя про другое. Бери из них строй фразы, а не текст: увидел у себя слова «платёж», «идемпотентный», «списание» — значит, выдал образец вместо ответа; сотри и напиши про то, о чём спросили.

        Вопрос запросто может оказаться не про его стек — на собеседовании это обычное дело, и нажимает он как раз на таком. Знание темы — не факт о пользователе: правило «ни одного факта о нём, которого нет в контексте» тему вопроса не закрывает. Разбирай предмет по существу и не приписывай ему опыта с ним; «это не мой стек» он скажет сам, если захочет.

        Не так — отказ, за ним и не нажимали:
        Погоди, это вопрос про JavaScript, а я backend на Go. Тут я не в теме — может, лучше про конкурентность в Go?

        А так — ответ по теме, за ним и нажимали:
        В питоне это упирается в GIL (джил): байткод в один момент исполняет только один поток.
        Поэтому на вводе-выводе потоки выигрывают, а на счёте нет.
        Тяжёлый счёт я бы вынес в отдельные процессы.

        Пользователь читает твой текст вслух, а латиницу вслух не прочесть: **сразу за латинскими буквами — и только за ними — идёт скобка, и вслух вместо них пойдёт её содержимое**, как термин говорят в русскоязычной IT-среде, а не по буквам оригинала: B-tree (би-три), GiST (джист), nginx (энджин-икс), PostgreSQL (постгрес), hash map (хеш-мапа), camelCase (кэмел-кейс), TTL (ти-ти-эль), created_at (крейтед-эт), O(n log n) (о от эн лог эн). Решать, очевидно ли произношение, не нужно: увидел латиницу — слово, аббревиатуру, имя из кода, формулу — поставил скобку. **Слева от скобки всегда латиница: написанное кириллицей скобки не открывает вовсе.** Смотри: Kubernetes (кубернетис) — латиница, скобка; кластер — кириллица, скобки нет; Kubernetes второй раз — голым. Скобка одна на весь термин, каким бы длинным он ни был, и одна за ответ; внутри — русские буквы и произношение целиком, дефис делит слова термина или буквы аббревиатуры, и больше ничего. Формулу читай ровно как написана, лишних букв не приписывай. Есть обычное русское слово — пиши сразу по-русски («экосистема», «на руки»), латиницу ради скобки не вставляй. В блоке кода скобок нет: код не произносят.

        Правила:
        - Если на экране задача (код, алгоритм, тест, форма) — кратко подход, затем готовое решение (код в fenced block), затем time/space complexity. Язык кода — как на экране, иначе Python. Код — единственное, что не произносят вслух: внутри блока кода ни первого лица, ни скобок с произношением не нужно.
        - Если это разговор — разбери текущий вопрос собеседника словами пользователя, от первого лица, чтобы пользователь говорил по написанному: суть, затем опора — примеры, цифры, компромиссы.
        - Ни одного слова в адрес собеседника: ни «используйте», «вы можете», «вам стоит», ни встречных вопросов, ни «давайте обсудим», ни нескольких вариантов на выбор — выбрать по дороге пользователь не сможет, он читает подряд. Исключение одно: собеседник сам спросил, есть ли вопросы, — тогда вопрос и есть ответ, и берётся он из заготовок.
        - «Я не знаю», «данных мало», «это не мой стек» он вслух не произнесёт: чего-то не хватает — скажи то, что сказать можно. И не рассуждай, как тебе следует поступить, — пиши сразу готовую фразу.
        - Ни одного факта, которого нет в контексте, — ни о пользователе, ни о компаниях, ни о рынке: ни компании, ни проекта, ни срока, ни цифры о нём самом, ни суммы. Выдуманное он произнесёт вслух как своё и не переживёт уточняющий вопрос. Речь про факты о нём, а не про темы: разобрать предмет не из его стека — не выдумка, а ответ. Про сами заготовки и про то, чего в контексте нет, не пиши ни слова: это служебное, а не речь.
        - Будь плотным и уверенным: длиннее короткого жанра, но без воды и без пересказа вопроса.
        - Не описывай скриншот («я вижу на экране…»). Не используй кавычки вокруг реплики «что сказать». Не выводи служебные или системные XML-теги.
        - Язык ответа — язык разговора / задачи на экране (обычно русский или английский).

        Определи сам, какого рода вопрос задан, и отвечай по-разному:
        - **Технический** («как устроен B-tree», «чем GiST отличается от GIN», «как бы вы это масштабировали»): механика по существу — термин, цифра, компромисс, порядок действий. Биографию сюда не подмешивай: про опыт не спрашивали.
        - **Про опыт и поведение** («расскажите случай, когда…», «был ли конфликт в команде», «самая сложная задача»): одна конкретная история пользователя по схеме ситуация — задача — что сделал — результат. Схема задаёт порядок фактов, а не длину: объём берётся из правил жанра выше. Есть подходящая заготовка — рассказывай её и её словами. Заготовки нет — строй костяк из его роли и стека и оставь конкретику ему; вот чужой костяк, смотри на порядок шагов, а слова бери свои: «Был случай, когда мы с коллегой разошлись на ревью: он предлагал написать свою библиотеку, я — взять готовую. Я вынес спор не в личку, а на общий разбор с замерами. Сошлись на том, что берём готовую и прячем её за своим интерфейсом». Ни компании, ни проекта, ни срока, ни цифры, которых нет в контексте: он произнесёт это как факт о себе.
        - **Про компанию, мотивацию и условия** («почему именно мы», «ожидания по деньгам», «какие у вас вопросы»): отвечай заготовками пользователя к этому собеседованию. Нужной заготовки нет — дай одну нейтральную фразу и оставь конкретику ему, вот так: «По деньгам я ориентируюсь на рынок, вилку назову, когда пойму объём задач». Ни суммы, ни срока, ни факта о компании от себя не называй.
        - **Задача на экране** (код, алгоритм, тест, форма): считай её текущим вопросом, даже если Them ничего не спросил, и отвечай по правилам выше.

        **ЯЗЫК ОТВЕТА — РУССКИЙ.** Разговор идёт на русском, и твой текст пользователь произнесёт вслух собеседнику.

        **Главное, ещё раз: разговорную часть ответа пользователь через секунду скажет вслух своим голосом. Первое лицо, живые глаголы, у каждого термина латиницей — скобка с произношением, ни одного факта о нём, которого нет в контексте, — и ответ по существу, когда тема не из его стека. Образцы в этих правилах — чужой текст: ни одной их строки в ответе.**
        """)
    }

    @Test("Запрет на диалоговые обороты стоит и в развёрнутом жанре")
    func theProhibitionsApplyToTheLongGenreToo() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("Ни одного слова в адрес собеседника"))
        #expect(system.contains("«используйте»"))
        #expect(system.contains("ни встречных вопросов"))
        #expect(system.contains("ни нескольких вариантов на выбор"))
        #expect(
            system.contains("он читает подряд"),
            "жалоба была на оба жанра — «давай обсудим, какой вариант ближе»"
        )
    }

    @Test("Рамка «это его собственная фраза» и контракт в конце есть и у развёрнутого жанра")
    func theLongGenreCarriesTheSameFrame() {
        let system = AssistPrompt.system(profile: .empty)

        // Пользователь показал ответы обоих жанров: обращение к нему и голые
        // термины были в обоих, значит и починка общая.
        #expect(system.contains("Ты пишешь не ответ пользователю, а его собственную следующую фразу."))
        #expect(system.contains("Не так — справка, её нельзя произнести:"))
        #expect(system.contains(PromptFragment.voice), "рамка — общий фрагмент, а не копия")
        #expect(system.contains("ни одного факта о нём, которого нет в контексте, —"))
        #expect(system.hasSuffix("Образцы в этих правилах — чужой текст: ни одной их строки в ответе.**"))
    }

    @Test("Код — объявленное исключение из произношения: его не произносят вслух")
    func codeIsExemptFromPronunciationBrackets() {
        let system = AssistPrompt.system(profile: .empty)

        // Этот жанр отвечает на задачу с экрана fenced-блоком, и скобка с
        // русским произношением внутри идентификатора — мусор.
        #expect(system.contains("Код — единственное, что не произносят вслух: внутри блока кода ни первого лица, ни скобок с произношением не нужно."))
        #expect(system.contains("В блоке кода скобок нет: код не произносят."))
    }

    @Test("Роды вопросов у обоих жанров описаны дословно одинаково")
    func bothGenresShareTheQuestionKinds() {
        #expect(AssistPrompt.system(profile: .empty).contains(PromptFragment.questionKinds))
        #expect(BriefPrompt.system(profile: .empty).contains(PromptFragment.questionKinds))
        // Различаются жанры объёмом, и только им: правило длины стоит у короткого
        // и отсутствует у развёрнутого, а общий блок про объём молчит вовсе.
        #expect(BriefPrompt.system(profile: .empty).contains("Не больше 45 слов"))
        #expect(!AssistPrompt.system(profile: .empty).contains("Не больше 45 слов"))
        #expect(!PromptFragment.questionKinds.contains("Максимум"))
    }

    @Test("Разрешение отвечать вне стека — общий фрагмент: аккорд не меняет вопроса")
    func bothGenresShareTheOutOfStackBlock() {
        let assist = AssistPrompt.system(profile: .empty)

        #expect(assist.contains(PromptFragment.outOfStack), "один текст, а не копия")
        #expect(BriefPrompt.system(profile: .empty).contains(PromptFragment.outOfStack))
        // Отказ пришёл на вопрос вне стека, и на этот аккорд он пришёл бы так же.
        #expect(assist.contains("Знание темы — не факт о пользователе"))
        #expect(assist.contains("и ответ по существу, когда тема не из его стека"))
    }

    @Test("Правило «я не знаю» появилось и у развёрнутого жанра — раньше его тут не было вовсе")
    func theLongGenreAlsoRefusesToSayItDoesNotKnow() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("«Я не знаю», «данных мало», «это не мой стек» он вслух не произнесёт"))
        #expect(system.contains("И не рассуждай, как тебе следует поступить, — пиши сразу готовую фразу."))
        #expect(system.contains("Речь про факты о нём, а не про темы: разобрать предмет не из его стека — не выдумка, а ответ."))
    }

    @Test("Ограда вокруг образцов и запрет меток стоят в обоих жанрах")
    func theSampleFenceAndLabelBanApplyToBothGenres() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("Оба образца — из чужого разговора"))
        #expect(system.contains("увидел у себя слова «платёж», «идемпотентный», «списание»"))
        #expect(system.contains("Метки — разметка входа, в ответе их нет"))
        #expect(system.contains(PromptFragment.channels), "запрет меток — общий фрагмент, а не копия")
    }

    @Test("Правило произношения терминов пережило правку — тем же текстом, что у короткого жанра")
    func thePronunciationRuleSurvives() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("GiST (джист)"))
        #expect(system.contains("увидел латиницу"))
        #expect(system.contains("Слева от скобки всегда латиница"))
        #expect(!system.contains("только там, где произношение неочевидно"), "оговорка = разрешение не делать")
        #expect(system.contains(PromptFragment.pronunciation), "одно правило, один текст на оба жанра")
    }

    // MARK: - Окно транскрипта

    @Test("Окно накрывает весь звонок — и у развёрнутого жанра оно то же, что у короткого")
    func thewholeCallReachesTheModel() {
        let call = (1...200).map { number in
            spoken(.them, "вопрос-\(String(format: "%03d", number))", at: Double(number) * 10)
        }

        let prompt = AssistPrompt.user(transcript: call)

        #expect(AssistPrompt.transcriptWindow == TranscriptFormatter.wholeCall)
        #expect(AssistPrompt.transcriptWindow == BriefPrompt.transcriptWindow, "жанры отвечают одному разговору")
        #expect(prompt.contains("вопрос-200"))
        #expect(prompt.contains("вопрос-001"))
        #expect(transcriptLines(of: prompt).count == 200)
    }

    @Test("Реплик немного — в промпт попадают все, в порядке разговора")
    func shortConversationKeepsItsOrder() {
        let call = [
            spoken(.them, "расскажите про ваш опыт", at: 0),
            spoken(.you, "семь лет на бэкенде", at: 10),
            spoken(.them, "а с конкурентностью работали?", at: 20),
        ]

        #expect(transcriptLines(of: AssistPrompt.user(transcript: call)) == [
            "Them: расскажите про ваш опыт",
            "You: семь лет на бэкенде",
            "Them: а с конкурентностью работали?",
        ])
    }

    @Test("У каждой реплики стоит метка её канала")
    func everyTurnCarriesItsChannelLabel() {
        let call = [spoken(.them, "как работает GCD?", at: 0), spoken(.you, "это очередь задач", at: 10)]

        let prompt = AssistPrompt.user(transcript: call)

        #expect(prompt.contains("Them: как работает GCD?"))
        #expect(prompt.contains("You: это очередь задач"))
    }

    @Test("Реплика без распознанного текста не превращается в пустую строку")
    func unrecognisedTurnsAreLeftOut() {
        let call = [
            spoken(.them, "первый вопрос", at: 0),
            Turn(channel: .them, text: "", timestamp: 10, duration: 1),
            Turn(channel: .you, text: "   ", timestamp: 20, duration: 1),
            spoken(.them, "второй вопрос", at: 30),
        ]

        #expect(transcriptLines(of: AssistPrompt.user(transcript: call)) == [
            "Them: первый вопрос",
            "Them: второй вопрос",
        ])
    }

    // MARK: - Пустой транскрипт

    @Test("Разговор ещё не начался — вместо транскрипта плейсхолдер, а запрос всё равно собирается")
    func emptyTranscriptStillProducesARequest() {
        let request = AssistPrompt.request(transcript: [], profile: .empty)

        #expect(request.userPrompt.contains(AssistPrompt.emptyTranscriptPlaceholder))
        #expect(request.userPrompt.hasSuffix(
            "Сделай то, что нужно мне прямо сейчас: если это разговор — напиши моими словами, что мне сейчас говорить; если на экране задача — реши её."
        ))
        #expect(!request.systemPrompt.isEmpty)
        #expect(transcriptLines(of: request.userPrompt).isEmpty)
    }

    @Test("Все реплики пока без текста — это тот же пустой разговор, а не пустые строки")
    func transcriptOfSilentTurnsFallsBackToThePlaceholder() {
        let unrecognised = [
            Turn(channel: .them, text: "", timestamp: 0, duration: 1),
            Turn(channel: .you, text: "", timestamp: 10, duration: 1),
        ]

        #expect(
            AssistPrompt.user(transcript: unrecognised)
                .contains(AssistPrompt.emptyTranscriptPlaceholder)
        )
    }

    // MARK: - Профиль и заготовки

    @Test("Профиль пользователя дописан в конец системной части")
    func profileLandsInTheSystemPrompt() {
        let profile = UserProfile(
            role: "Senior iOS Engineer",
            experience: "восемь лет, финтех",
            stack: "Swift, Combine, Core Audio"
        )

        let system = AssistPrompt.system(profile: profile)

        #expect(system.contains("Контекст о пользователе (резюме / роль / стек):"))
        #expect(system.contains("Роль: Senior iOS Engineer"))
        #expect(system.contains("Опыт: восемь лет, финтех"))
        #expect(system.contains("Стек: Swift, Combine, Core Audio"))
        #expect(system.hasSuffix("Стек: Swift, Combine, Core Audio"), "профиль идёт последним")
    }

    @Test("Профиль не заполнен — пустого блока в системной части нет")
    func emptyProfileAddsNothing() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(!system.contains("Контекст о пользователе"))
        #expect(system == AssistPrompt.system(profile: UserProfile(role: "  ")))
    }

    @Test("Профиль заполнен наполовину — пустые поля не превращаются в пустые метки")
    func blankProfileFieldsAreOmitted() {
        let system = AssistPrompt.system(profile: UserProfile(role: "Backend Engineer"))

        #expect(system.contains("Роль: Backend Engineer"))
        #expect(!system.contains("Опыт:"))
        #expect(!system.contains("Стек:"))
    }

    @Test("Заготовки к собеседованию уходят в system и развёрнутого жанра")
    func theInterviewContextReachesTheLongGenreToo() {
        let system = AssistPrompt.system(
            profile: UserProfile(role: "Тимлид"),
            interviewContext: InterviewContext(compensation: "от 400 на руки", questions: "Кто владеет роадмапом?")
        )

        #expect(system.contains(PromptFragment.interviewContextHeading))
        #expect(system.contains("Ожидания по деньгам:\nот 400 на руки"))
        #expect(system.contains("Вопросы к работодателю:\nКто владеет роадмапом?"))
        #expect(!system.contains("Истории из практики"))
    }

    @Test("Профиль относится к пользователю: очистка разговора его не трогает")
    func profileSurvivesAnEmptiedTranscript() {
        let profile = UserProfile(role: "Senior iOS Engineer")

        let afterClearing = AssistPrompt.request(transcript: [], profile: profile)

        #expect(afterClearing.systemPrompt.contains("Роль: Senior iOS Engineer"))
        #expect(afterClearing.userPrompt.contains(AssistPrompt.emptyTranscriptPlaceholder))
    }

    // MARK: - Настройки режима

    @Test("Бюджет токенов режима — из верхней части полосы, отведённой Assist")
    func tokenBudgetMatchesTheMode() {
        let request = AssistPrompt.request(transcript: [], profile: .empty)

        #expect((2_000...4_096).contains(request.maxTokens))
        #expect(request.maxTokens == AssistPrompt.maxTokens)
    }

    @Test("Язык ответа не форсируется: правило отсылает к языку разговора")
    func answerLanguageFollowsTheConversation() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("Язык ответа — язык разговора / задачи на экране"))
    }

    @Test("Скриншот прикладывается к запросу как есть")
    func screenshotIsCarriedIntoTheRequest() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let request = AssistPrompt.request(transcript: [], profile: .empty, screenshot: png)

        #expect(request.screenshot == png)
    }

    // MARK: - Хелперы

    private func spoken(_ channel: Channel, _ text: String, at timestamp: TimeInterval) -> Turn {
        Turn(channel: channel, text: text, timestamp: timestamp, duration: 1)
    }

    /// Lines of the transcript block — everything that carries a channel label.
    private func transcriptLines(of prompt: String) -> [String] {
        prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("Them: ") || $0.hasPrefix("You: ") }
    }
}
