# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Язык общения

**Всегда отвечай пользователю только на русском языке** — все объяснения, вопросы и отчёты о выполненной работе. Идентификаторы в коде и комментарии в коде — на английском, по обычным конвенциям Swift.

**Сообщения коммитов и описания PR — на английском.** Репозиторий публичный, и история — такая же его витрина, как README: читают её те же люди и по той же ссылке. Стиль при этом не меняется — заголовок-утверждение о том, что стало правдой, и тело с причиной, а не перечень тронутых файлов.

**Соавторства в коммитах нет.** Автор один — владелец репозитория, и трейлер `Co-Authored-By` с моделью не ставится: GitHub считает соавторов контрибьюторами, и в списке из одного человека вторым именем стояла модель. Это тоже проверяет хук.

**Держит эти правила не память, а `.githooks/commit-msg`** — он отклоняет кириллицу в первой строке (пропуская её в теле) и трейлер `Co-Authored-By` с моделью, где цитируются строки интерфейса и сообщения об ошибках. Ставится один раз: `git config core.hooksPath .githooks`. Появился он потому, что правила оказалось мало: четыре релизных коммита подряд вышли по-русски — `set-version.sh` печатал готовую строку «Версия X», и её копировали, не сверяясь с правилом. Подсказка в скрипте теперь английская, но виновата была не она одна, а то, что нарушить было нечему помешать.

Коммиты, написанные по-русски до этого решения, остаются как есть. Перевести их — это ещё одна перезапись истории со сменой всех SHA и force-push; делается только по отдельной просьбе.

## Current state

**The MVP is closed: it was walked end to end on a live run (11 August 2026)** — the window stayed out of a screen recording, a headset swapped mid-call was survived, both genres and `Solve on screen` answered, the answers came from the user's заготовки, and a full mock interview on claude-haiku produced no cut streams. The MVP pipeline runs end to end: both channels are captured, turns are cut on pauses, speech is recognised locally into a live transcript — and a suggestion is generated when the user presses a chord, never on its own. The suite is around **700 tests** in roughly a hundred suites (Swift Testing, target `GhostMeetTests`) — the order of magnitude is the point, not the exact figure: a run reporting a handful, or zero, is a broken host and not a pass.

Done: project skeleton and test target, microphone capture, turn segmentation, WhisperKit recognition with model selection, the overlay window, the `Them` channel (both backends, SCK by default), settings with per-provider keys, the full provider router (OpenAI-compatible family, Gemini, CLI tools) with streaming, screenshot and OCR on every request, the press-driven suggestion lifecycle (a new press supersedes the answer in flight), two genres of suggestion plus `Ask` and `Solve on screen`, global hotkeys and per-channel indicators, several named profiles with one selected per call and filled in either by hand or from a resume, the `Контекст собеседования` beside them, the readiness strip in the overlay header, markup in the suggestion card, and saving the call to a file — both channels and the answers in one list, each answer naming the **вид подсказки** it was asked for, marked leaks left out but counted in the header.

Every feature is a directory under `.scratch/`, and the truth about what is open lives in the tickets rather than here — a list of them in this file goes stale the week it is written. What is open right now:

```bash
grep -rL '^\*\*Status:\*\* done' .scratch/*/issues/*.md
```

What is left at the product level is the v1.0 list in [docs/GhostMeet.md](docs/GhostMeet.md). The background Summarizer is **deliberately not** on the critical path any more: a whole interview is ~10k tokens and fits in one request, so `{{#if summary}}` stays present and empty until a use case longer than an interview appears.

The audio investigation is over and its scaffolding is gone: no diagnostics object, no level probes, no environment flags of our own. What survived it are the fixes it found — `MicCaptureService.firstChannel`, `ProcessTap.DeliveryFormat`, `PCMMixdown`, the mic tap installed with `format: nil` — and their regression tests. Logging is lifecycle-only now: capture start and failure (`SessionEngine`), `Them` channel status (`SessionController`), recognition model phase (`SpeechModelStatus`). Nothing per frame, nothing anybody said. Keep it that way — a per-frame log in this app writes the conversation to disk.

```
GhostMeet/                      ← repo root
├── CLAUDE.md
├── README.md / README.ru.md    ← витрина репозитория, английский основной
├── CHANGELOG.md                ← Keep a Changelog; версии с 0.0.1, ретроспективно
├── docs/                       ← the authoritative spec (read before implementing)
├── scripts/                    ← set-version.sh → release.sh → make-dmg.sh
├── .github/workflows/          ← CI: сборка и тесты; ничего не подписывает
└── GhostMeet/                  ← SRCROOT
    ├── GhostMeet.xcodeproj
    ├── Info.plist              ← lives HERE, outside the source folder — see below
    └── GhostMeet/              ← file-system-synchronized source group
```

Both spec documents are written in Russian, and so is everything else in `docs/`, `CONTEXT.md` and `.scratch/` — that has not changed. Code identifiers and comments follow normal Swift conventions in English.

**In-app strings are a different question since 0.5.0, and the line is worth knowing before adding one.** The interface speaks two languages: the Russian text in the source *is the key*, and `Localizable.xcstrings` carries the English beside it. So a new visible string is written in Russian as usual — and then it has to reach the catalogue, or it stays Russian on an English screen without anything failing. Two rules follow.

- **`Text("Русский текст")` localises itself; `Text(строка)` does not.** A `String` built by a model — a phase, a summary, the wording of a failure — has to say `String(localized:)` at the point it is written, and a row helper that takes a `String` will silently skip translation (that is why `SettingsRow` takes a `LocalizedStringKey`).
- **Logs, prompts and stored values are deliberately not translated.** `ЗАХВАТ СТАРТОВАЛ` stays as it is, or searching the journal for the sentence somebody reported stops working. Prompt text stays Russian because the prompt is verified word for word against [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md) — `InterviewContext.Field` has `label` for the prompt and `screenLabel` for the screen precisely because of this, and mixing them up changes the prompt on an English machine only.

Three things enforce this, and none of them is a person reading the screen — 0.5.0 shipped with fifty Russian strings on an English window precisely because that was the only check. `scripts/find-untranslated.sh` reads the **sources** and refuses a literal that reaches a `String` without `String(localized:)`; it runs in CI before the tests and inside `make-dmg.sh`. `make-dmg.sh` also refuses a build whose English table did not reach the bundle, and a test refuses any English value that still contains Cyrillic.

Two traps found the hard way and worth knowing before writing a string. **A multi-line literal hides from the eye and hid from the first version of the guard** — the résumé warning lived in `"""…"""` and survived the whole translation. And **a number interpolated into `String(localized:)` is formatted for the locale**: an OSStatus of `-12345` comes out as «-12.345», which nobody can search for. Interpolate it as `\(String(code))` — a string carries no formatting.

## Build and run

All commands run from `GhostMeet/` (the folder containing `.xcodeproj`):

```bash
xcodebuild -project GhostMeet.xcodeproj -scheme GhostMeet -configuration Debug build
```

```bash
xcodebuild -project GhostMeet.xcodeproj -showBuildSettings -target GhostMeet
```

Run the whole suite (Swift Testing, target `GhostMeetTests`):

```bash
xcodebuild -project GhostMeet.xcodeproj -scheme GhostMeet -destination 'platform=macOS' test
```

Run a single test — `-only-testing:` takes `Target/Suite/testFunction`:

```bash
xcodebuild -project GhostMeet.xcodeproj -scheme GhostMeet -destination 'platform=macOS' test -only-testing:GhostMeetTests/SkeletonTests/testBundleIsWired
```

The scheme is **shared** (`xcshareddata/xcschemes/GhostMeet.xcscheme`) and committed — it lists the test target under both the build and test actions. Don't rely on Xcode's auto-created scheme; it lives in `xcuserdata`, which is gitignored.

When several builds run at once (parallel agents), give each its own `-derivedDataPath` — concurrent builds sharing the default DerivedData corrupt each other.

Verify what actually landed in the app bundle after touching Info.plist or deployment settings:

```bash
plutil -p ~/Library/Developer/Xcode/DerivedData/GhostMeet-*/Build/Products/Debug/GhostMeet.app/Contents/Info.plist
```

### Project configuration gotchas

- **Deployment target is macOS 14.4**, set at the *project* level (`MACOSX_DEPLOYMENT_TARGET`); the target inherits it, so the target's General tab shows the value without defining it. Do not raise it — Core Audio Process Tap requires 14.4.
- **App Sandbox is off** (`ENABLE_APP_SANDBOX = NO`). Deliberate: this is a local BYOK app that needs Process Tap and screen capture, not an App Store build.
- **All usage-description strings live in `SRCROOT/Info.plist`**, merged with the generated plist (`GENERATE_INFOPLIST_FILE` stays `YES`). Add new ones there, not as build settings — **`INFOPLIST_KEY_*` only works for keys Xcode knows**, and unknown ones like `NSAudioCaptureUsageDescription` / `NSScreenCaptureUsageDescription` are *silently dropped*: the build succeeds and the key simply never reaches the bundle. Always confirm with the `plutil` command above rather than trusting `-showBuildSettings`.
- **`Info.plist` must stay outside `GhostMeet/GhostMeet/`.** That folder is a `PBXFileSystemSynchronizedRootGroup` — anything inside is picked up automatically, and a plist there gets copied into `Contents/Resources/` as a stray duplicate. Same trap applies to any other non-source file.
- Because the source group is file-system-synchronized, **new `.swift` files are added to the target just by creating them on disk** — no pbxproj edit needed. Adding an SPM dependency, a target, or a scheme still means editing `project.pbxproj` by hand.
- **Give every concurrent build its own `-derivedDataPath`.** Parallel agents sharing the default DerivedData corrupt each other's builds.
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on, so `CGRect` / `CGSize` need an explicit `import CoreGraphics` even where `Foundation` is already imported. A standalone `swiftc -typecheck` without the flag will not reproduce the error.
- **Xcode 26 or newer.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is a Swift 6.2 build setting; on Xcode 16.x the project does not build. CI therefore pins `macos-26` and selects the newest installed Xcode — `macos-latest` still resolves to macOS 15, whose **default** Xcode is 16.4, and the build then dies before the first test while the failure reads as «упали тесты».
- **Never declare an `actor`'s conformance to a `nonisolated` protocol on the type itself — put it in an extension.** A conformance written on the declaration lets the type *infer* the protocol's isolation, and `nonisolated` is the one thing an `actor` cannot be, so the compiler rejects it with `'nonisolated' modifier cannot be applied to this declaration` — pointing at a file that contains no `nonisolated` anywhere. `SpeechRecognizer` is such a protocol, and `RecognizerSpy` in the test target was such an actor.

  Two things hid this for a long time. The **app** target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, where the inference does not happen — so `WhisperSpeechRecognizer`, an actor conforming to the very same protocol on its declaration, compiles fine; the test target has no such setting and was exposed. And it is **toolchain-dependent**: Xcode 26.4 (Swift 6.3.0) accepted it, while 16.4 (6.1) and 26.6 (6.3.3) both refused. A green local build proves nothing here — this exact construct passed 673 tests locally on the same commit CI could not compile.

  Aligning the targets by giving the test target `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` **was tried and is wrong**: it compiles, and then the host dies at launch — `Test run with 0 tests in 89 suites`, exit 65.

### «0 tests passed» — это падение, а не успех

`xcodebuild test` печатает `✔ Test run with 0 tests in N suites passed` и возвращает **65**, когда host-приложение умирает раньше первого теста. Сюиты при этом объявляются и «проходят» — их ноль тестов действительно не упал. Строка выглядит как успех, и один раз уже была за него принята.

Причина в тот раз: `NSHostingView.safeAreaRegions = []` — AppKit бросает исключение прямо в цикле отрисовки, приложение падает на старте. Правильный способ добраться до той же цели — `.ignoresSafeArea()` в самом SwiftUI-представлении.

**Второй раз это была загрузка модели.** Тест-хост — это само приложение, поэтому `recognition.prepare()` в делегате тянул WhisperKit на каждый `xcodebuild test`: сеть, сотни мегабайт и ANE за процессом, от которого тесты ждут миллисекунд. Host умирал посреди прогона, а падало при этом **каждый раз разное** — `waitUntil` и `modelWasAsked` по всему набору, — отчего диагноз три раза подряд звучал как «флак» и «машина загружена». Поэтому: **всё тяжёлое в пути запуска приложения должно пропускаться под тестами** (`AppDefaults.isRunningTests()`), как это делают подготовка модели и запрос обновлений. Проверка того же локально: полный прогон занимает ~3 секунды; если он идёт десять и больше, что-то тяжёлое снова стартует.

Правило простое: **смотреть на число тестов и на код возврата, а не на галочку.** Ноль тестов при полусотне сюит — всегда сломанный host, и `~/Library/Logs/DiagnosticReports/GhostMeet-*.ips` скажет, чем именно.

### Звук: молчаливые отказы и разрешения

**Правишь `Audio/` или объясняешь, почему «звук не работает», — сначала [docs/audio-traps.md](docs/audio-traps.md).** Там записаны два бага, которые в этом проекте уже стоили дней отладки, и оба выглядели одинаково: захват идёт, индикаторы горят, буферы приходят вовремя, каждый сэмпл — ноль, ни одного кода ошибки. Общий корень — **macOS сообщает один формат звука, а отдаёт другой**, и несовпадение никогда не ошибка, а всегда тишина. Там же — почему разрешения TCC привязаны к подписи и почему при странностях с микрофоном смотреть надо на неё.

Одно правило оттуда стоит знать не открывая: **заявленному формату звука здесь не верят — мерят то, что пришло.** Коды возврата не скажут ничего.

## Обязательные правила работы

Три правила, нарушение которых считается незакрытой работой, а не мелочью. Они появились из реальных ошибок в этом проекте.

### 0. Ветка на фичу; `main` и теги двигаются только под релиз

Работа идёт в ветках `feat/<что-делаем>`, отведённых от `main`. **Ветки пушатся свободно и без спроса** — ради этого и настраивался CI, а незаконченная работа на виду в открытом проекте нормальна.

**А вот `main` — нет.** В него вливается только законченная фича, и делается это по слову владельца, а не потому, что правка дописана. Тег и релиз режутся из `main` отдельным шагом. Разделение простое: ветки — это работа, `main` — то, что не стыдно выпустить, тег — то, что выпущено.

Отсюда же ответ на вопрос «не пора ли перевыпустить релиз, раз `main` ушёл вперёд»: **нет.** Релиз — снимок, а не текущее состояние; `main` впереди тега это норма, а не рассинхрон. Сделанное уезжает следующей версией.

- **Готовая фича заканчивается словами «готово, вливать?»**, а не слиянием.
- Полный прогон тестов — перед слиянием в `main`, целиком и с проверкой числа тестов. CI на ветке уже отработал, но он не гоняет то, что не запушено.

### 1. Документы правятся тем же изменением, что и код

**После каждой доработки — до того, как назвать её законченной — пройди по документам и приведи их в соответствие.** Не «когда-нибудь потом»: расходящиеся документ и код хуже отсутствующего документа, потому что им верят.

Что проверять каждый раз:

- `docs/GhostMeet.md` — спека продукта: возможности, стек, структура файлов, списки MVP/v1. **Структура файлов в ней — инструкция для агентов**, и если она врёт, следующий агент создаст файлы с несуществующими именами.

  **Списки MVP/v1 — часть документа, а не украшение, и галочки в них ставятся той же правкой.** Проверено на себе: тринадцать сделанных пунктов простояли неотмеченными до конца MVP, а строка «автоматический запуск подсказки по паузе» осталась в списке недоделанного через полгода после того, как ADR-0008 её отменил. Отменённое не откладывается в тот же список — оно вычёркивается со ссылкой на решение, иначе читатель считает его невыполненной работой.
- `docs/GhostMeet-Prompts.md` — авторитетные тексты промптов. Промпт в коде и промпт здесь обязаны совпадать дословно; правятся одним изменением.
- `CONTEXT.md` — глоссарий. Новое понятие в коде без термина в глоссарии — источник будущего расползания синонимов.
- `CLAUDE.md` — этот файл: состояние проекта, грабли, инварианты.
- `.scratch/<фича>/` — спека и тикеты той фичи, над которой идёт работа: статусы, критерии, комментарии о найденном. Спека правится тем же изменением, что и код: посылка, которую опровергло измерение, переписывается не молча — старая формулировка остаётся, а рядом встаёт то, что показали числа.
- **Ссылки между документами.** Относительные пути легко ломаются; из `.scratch/<фича>/issues/` до корня три уровня, а не два. Проверяй, что каждая ссылка ведёт в существующий файл.

Отдельно: если по ходу работы выяснился факт, который стоил времени — неочевидное поведение системы, ловушка API, причина молчаливого отказа, — он идёт в документы. Час отладки, не оставивший следа в тексте, будет потрачен снова.

### 2. ADR никогда не переписывается — выпускается новый

**Решение, однажды записанное, не редактируется и не удаляется.** Чтобы изменить его, напиши **новый** ADR со следующим номером, который явно говорит, какой ADR он заменяет, и добавь в старый одну строку `status:` со ссылкой на заменяющий. Эта строка и короткая врезка-предупреждение — единственные допустимые правки заменённого ADR.

Причина: ценность ADR не в том, что он описывает текущее положение дел, а в том, что он фиксирует **что было решено и на каком основании**. Переписав его, теряешь именно это — читатель больше не видит ни отменённого решения, ни причин, по которым оно казалось верным. В этом проекте так уже терялся ADR-0005, восстановленный потом по памяти.

Что можно без нового ADR: дописать наблюдение, которое **не меняет решения** (например, «проверено вживую, держится»). Что нельзя: менять сам вывод, условия, при которых он верен, или его последствия — это новый ADR.

Заменённый ADR остаётся в каталоге навсегда. Пример пары: [ADR-0005](docs/adr/0005-vpio-and-process-tap-cannot-coexist.md) и заменяющий его [ADR-0007](docs/adr/0007-vpio-and-process-tap-do-coexist.md).

## What GhostMeet is

A macOS always-on-top overlay that assists during video calls (Meet, Telemost, Zoom, Teams). It listens to two audio channels, transcribes locally, and answers via pluggable LLMs — while staying invisible to screen sharing.

**The MVP targets one scenario: a technical interview where the user is the candidate.** That is the tightest requirement set — latency is critical and `Solve on screen` is a primary mode rather than a bonus. The scenario also settled the loop: a candidate knows most answers, so suggestions are asked for, not delivered (ADR-0008). The old worry that reaching for a chord on camera is conspicuous weighs less than it looked — in a technical interview the hands are already on the keyboard. Other scenarios are relaxations of this one and are not designed for separately.

## Версии и релизы

Порядок выпуска, схема версий, что делает CI и почему нет нотаризации — **[docs/releasing.md](docs/releasing.md)**, целиком и в одном месте. Здесь этого нет намеренно: пересказ рядом с источником — это два описания одного порядка, и расходиться они начинают на первой же правке.

Достаточно знать три вещи, чтобы не сломать выпуск, не читая ничего:

- **`main` и теги двигаются только под релиз**, по слову владельца (правило 0 ниже).
- Версия живёт в `MARKETING_VERSION` **во всех четырёх конфигурациях** pbxproj; правит её `./scripts/set-version.sh`, руками — нет.
- **CI ничего не подписывает и не публикует.** Разрешения macOS привязаны к подписи, а сертификат у проекта личный; релиз собирает и подписывает машина разработчика.

## Where decisions live

Design decisions from the grilling session are recorded, not just implied by the code — read them before reopening a settled question:

- [CONTEXT.md](CONTEXT.md) — the glossary. `You`, `Them`, `Реплика`, `Подсказка`, `Профиль` have precise definitions; use those words and don't drift to synonyms.
- [docs/adr/README.md](docs/adr/README.md) — the index: one line per decision, which ones are superseded, and which to read for the task in hand. **Go through the index rather than the directory** — three of the eleven are superseded in whole or in part, and read cold they describe an app that no longer exists. The list is not repeated here on purpose: two copies of it would disagree within a month.

The spec in `docs/` has been reconciled with these; where an older reference project (cue) disagrees, the ADRs win.

## Architecture invariants

These are the decisions that shape everything else; changing one has ripple effects across the codebase.

**Two channels never mix.** `You` (user mic, plain AVAudioEngine) and `Them` (call participants, captured from the source app) each get their own buffer, their own independent STT pass, and their own label in the transcript. Channel membership is decided by *source*, never by meaning: everything from the mic is `You` even when the user reads someone else's question aloud.

**VPIO is never enabled** ([ADR-0009](docs/adr/0009-no-vpio-echo-is-ours-to-handle.md), which supersedes the «always on» half of [ADR-0007](docs/adr/0007-vpio-and-process-tap-do-coexist.md)). It used to be what stopped the interlocutor's voice leaking from the speakers into `You` — and it worked — but `setVoiceProcessingEnabled(true)` switches the *device* into its multi-channel mode, and every **other** process reading the built-in mic then loses 28–32 dB. Chrome is one of them: it takes the raw stream and does its own processing, so a browser call — the target scenario — has the candidate arriving at the interviewer 31 dB quieter, and the candidate never finds out. The cost is charged to a process that did not ask for it, which is what makes it unusable here, not the feature itself.

What replaces it is ours and layered: a route classifier decides whether the built-in mic can hear the built-in speakers at all, strict mode refuses to open a `You` turn while `Them` is sounding, and `LeakDedup` marks a `You` turn whose words match a simultaneous `Them` turn. Read ADR-0009 before re-enabling anything: the obvious workarounds (bypass, another device, short bursts) are all measured and all fail.

**Two implementations per external seam.** Capture, STT and LLM each have two or more backends behind one protocol, selectable in settings — see [ADR-0001](docs/adr/0001-swappable-backends-behind-protocols.md). Branching must not leak upward: `Speech` doesn't know where the audio came from, `Intelligence` doesn't know what transcribed it. Backends are built **one at a time** through the seam, not in parallel.

**ScreenCaptureKit is the default; Process Tap is the second backend.** The default was flipped on a measurement, not a preference: SCK delivers 1.5–2.5× more signal because voice-processing ducking hits the tap harder, and quiet audio is the product's main quality limit ([ADR-0006](docs/adr/0006-screencapturekit-default-for-them.md)). The spec's original case for the tap has mostly expired — both APIs are **app-level**, neither isolates a browser tab, and Screen Recording is needed anyway because every suggestion carries a screenshot. What survives is that the tap sees *any* process making sound, while SCK lists only windowed applications; that is why it stays.

**One profile in the prompt, several in storage.** The user keeps a `Профиль` per kind of interview — a team lead's and a full-stack senior's are different people on paper — and picks one before the call. `ProfileLibrary` holds the list and the selection; `SettingsStore.profile` is the selected one and is all the prompt layer has ever seen, so `SuggestionComposer`, `AssistPrompt` and the rest know nothing about a list. Two invariants hold at all times: the library is never empty, and the selection always points at an entry that exists.

Filling a profile in from a resume produces a value of that same `UserProfile` — never a parallel "profile from a resume". The model is asked to answer in exactly the shape `UserProfile.promptFragment` writes, which makes `UserProfile.parsed(from:)` its literal inverse; that is the whole defence against the two drifting apart. The profile's *name* is the one field that never reaches a model: it is a label for the picker, not a fact about the user.

The resume file itself is never stored — not on disk, not in `UserDefaults`, not in a log. It is read once, its text lives in a local variable for one request, and what survives is the profile the user approved. Before the button is pressed the screen names the provider that will receive it and says whether the text leaves the machine; `ProviderDestination` answers that from the *effective* base URL, and deliberately refuses to promise privacy for a CLI tool — `claude -p` forwards the prompt to its vendor exactly as an HTTP provider would, and the app cannot tell one tool from another.

**Local-first privacy.** STT is on-device (see [ADR-0002](docs/adr/0002-stt-engine-choice.md) — **WhisperKit, not MLX**); the LLM layer must support fully local providers (Ollama, LM Studio, llama.cpp server, MLX-LM) alongside cloud ones. BYOK, no backend server of our own — API keys live in Keychain only. Nothing is written to disk unless the user turns it on.

**Exactly one request is not the user's own, and it is the update feed** ([ADR-0010](docs/adr/0010-update-check-at-launch.md), narrowed by [ADR-0012](docs/adr/0012-sparkle-installs-the-update.md)). Everything else on the wire happens because a chord or a button was pressed. At launch the app asks the `appcast.xml` published beside the latest release and says so in one line if there is a newer version; the request carries an IP and the running version and nothing else, it is on by default because nothing else tells a machine it is out of date, and it is off with one switch — off meaning the updater is never built at all. It does not run under tests: the suite hosts itself inside the app, and every `xcodebuild test` would otherwise put a request on the wire — worse here than before, because this mechanism can replace the application the run is hosted in.

**Since 0.4.0 the app installs that update itself, through Sparkle** ([ADR-0012](docs/adr/0012-sparkle-installs-the-update.md)). The point is not the button: **an update the app installs does not get quarantined**, so `xattr -dr com.apple.quarantine` is needed on the first install and never again — measured, along with the fact that permissions survive a bundle swap because TCC keys on identifier plus certificate rather than on a version or a hash. **That makes the signature load-bearing:** change the certificate or `PRODUCT_BUNDLE_IDENTIFIER` and every installed copy asks for the microphone and screen recording again on its next update. Sparkle's own windows are all off — a custom `SPUUserDriver` writes single lines into the overlay instead (ADR-0004) — and nothing installs while listening, by the same rule as `SessionController.canQuit`.

**Silence is not uniform any more, and the boundary is load-bearing.** A request nobody asked for still fails silently: no network, no feed, a signature that does not verify at launch all end with no notice and no log line. But **the outcome of a press is always spoken**, failure included — a silent failed install leaves somebody certain they have updated, walking into an interview on the old build.

**Invisibility is on by default and can be switched off — from the window, never from settings** ([ADR-0011](docs/adr/0011-visibility-switch-in-the-window.md)). The reason is mundane: with `sharingType = .none` the window cannot be screenshot or recorded at all, so a demo required editing a constant and rebuilding. Four constraints hold it together and none is decoration: on by default, **never persisted** (a switch left on last night while recording must not surface at tomorrow's interview), locked — not overridden — while listening, and stated in an orange line for as long as it is off. The settings window follows the same switch. Turning it off also returns the overlay to the app's *own* screenshots, so the model starts seeing its previous answer.

**Invisibility.** The window uses `NSWindow` level + `collectionBehavior` for always-on-top and `sharingType = .none` (content protection) so it is excluded from screen capture — including from our own screenshots, which is what keeps the model from seeing its previous answer. The app runs as an accessory (`LSUIElement`), and whole-display sharing is explicitly out of scope ([ADR-0004](docs/adr/0004-invisibility-scope.md)). **Accessory mode takes «закрыть» with it** — no Dock icon, no menu bar, nothing in ⌘-Tab — so the panel keeps the standard red close button (top left, where macOS puts it) while miniaturise and zoom stay hidden, `windowShouldClose` turns it into a quit, and `SessionController.canQuit` refuses it while listening: the window sits a hand's width from chords pressed without looking, and a stray click would end the call with no undo. Until that button existed, quitting meant Activity Monitor, which is a fair reason to distrust a program that hears your microphone. Failures are surfaced **inside the window only** — a system notification banner would appear over the shared screen and give the app away.

### Audio → answer pipeline

1. **Capture** — mic via plain AVAudioEngine (no VPIO — ADR-0009); `Them` via Process Tap → Aggregate Device → IOProc (or SCK). Both survive a device-mode switch made by somebody else: `CaptureRecovery` listens for `AVAudioEngineConfigurationChange` and reopens the tap, because now that we no longer switch the mode, anyone else can — Phone, WhatsApp, Teams — and without the subscription the microphone dies silently. **`Them` also survives its own stream breaking** — `SCKCaptureService` re-attaches on `SCStream` failure, with the microphone's delays. Until 0.3.3 it only reported that one, and a live call paid for it: the stream died 1.1 s in, Chrome stayed alive so nothing woke the channel, and for 37 minutes the interviewer's voice went into `You` through the speakers while the transcript went on looking normal. Both leak defences are useless in that state by construction — strict mode waits for loud `Them` frames, `LeakDedup` compares against `Them` turns — so a dead `Them` is the one failure that must never be silent (`.scratch/them-recovery/`)
2. **Buffer + gate** — separate `you`/`them` PCM queues; a turn closes after **1.5 s** of silence, with a minimum length (~0.6 s), an RMS silence gate, and a ~10 s forced flush for pause-less monologues. The threshold used to be 800 ms because every extra 100 ms was 100 ms before the first token; with ADR-0008 it is no longer part of any latency budget, and the higher value is what stops a long question arriving in three pieces. **Do not lower it back on latency grounds**
3. **STT** — WhisperKit per channel, independently. Text that is *entirely* a known `Фантомная реплика` — the subtitle sign-off Whisper emits on a stretch with sound but no speech — is dropped here rather than written down (`PhantomSpeech`). The audio-side test would be better than a phrase list, and `no_speech_prob` **is not it**: WhisperKit declares the field and fills it with a literal zero
4. **Transcript** — append `Turn { channel, text, timestamp }`
5. **Context** — the whole call, capped at `TranscriptFormatter.characterBudget` (40 000 characters ≈ 13–16k tokens, over an hour of speech); adjacent turns of one channel less than `mergeGap` (3 s) apart are merged into one line, so a question split by a pause stops reading as two people. Overflow drops the oldest lines and says so. The background Summarizer is **not built** — at ~10k tokens for a whole interview it would compress what already fits — so `{{#if summary}}` is present in every prompt and always empty. Alongside goes the user's `Профиль` and the `Контекст собеседования`
6. **LLM** — one `LLMProvider` protocol behind an `LLMRouter`; cloud, local-HTTP, and CLI providers all conform to it. Streaming everywhere except the Summarizer.

**Nothing reaches the model until the user presses** ([ADR-0008](docs/adr/0008-hotkey-triggered-suggestions.md), which supersedes [ADR-0003](docs/adr/0003-proactive-suggestion-loop.md)). Capture, segmentation and recognition run on their own — steps 1–4 above fill the transcript continuously — but steps 5–6 happen only on a chord. A screenshot still travels with *every* request; it is taken at the press.

The reason is in the scenario, not in the code: a candidate knows most of the answers. Help is wanted when they don't know, don't remember, or aren't sure — a minority of questions. Answering the rest cost tokens, filled the feed and buried the model in crumbs. Read ADR-0008 before reopening this; it also records what the decision does *not* rule out.

**A press has to close the question first.** The user presses the moment the interviewer stops — before the pause threshold has elapsed, so the last phrase is not in the transcript yet. `SessionEngine` therefore force-closes the open `Them` turn, waits for recognition under a budget, and only then composes. That path must bypass `minimumTurnDuration`: `TurnSegmenter.close()` clears `samples` *before* rejecting a short turn, so a plain flush destroys a 0.4 s tail — exactly the end of the question. Recognition runs beside the screenshot, never after it.

Cancellation is narrower than it looks, and the boundary is load-bearing: a superseded request loses its *answer* — the stream, the screenshot being taken for it — and keeps its *words*. Speech recognition is never cancelled; those words belong in the transcript regardless of which answer survives. Only a new press supersedes anything. A `Them` turn no longer cancels anything at all, and `You` speech never did.

Two genres share that path and differ only in size: **коротко** (⌥⌘A, ~512 tokens) is the default, because a user who presses is already speaking and needs the missing piece rather than an essay; **подробно** (⌥⌘Z, 4k) is for a topic that is unfamiliar whole. `Solve on screen` is the third chord and reads no transcript at all.

The planned Swift file layout (`App/`, `UI/`, `Audio/`, `Speech/`, `Intelligence/{Context,LLM,Screen}/`, `Input/`, `Settings/`, `Utilities/`) is in [docs/GhostMeet.md](docs/GhostMeet.md) — follow it when creating files rather than inventing a new structure.

## Modes and prompts

Существующие режимы: два жанра подсказки (**коротко** ⌥⌘A и **подробно** ⌥⌘Z), `Ask`, `Solve on screen`. Заспецифицированы, но не построены: Follow-up, Recap и фоновый Summarizer.

**Авторитетные тексты промптов живут в [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md); прочитай его до правки кода, собирающего промпты, и правь тем же изменением, если промпт сдвинулся** — они обязаны совпадать дословно, и тест сверяет собранную строку с литералом из документа. Там же лежит разбор формулировок: почему запреты обходятся по букве, а образцы исполняются.

**[docs/lessons-from-live-runs.md](docs/lessons-from-live-runs.md) — то, что уже ломалось вживую за пределами промптов**, по слоям: транскрипт с нажатием и поток ответа с провайдерами. Читать по слою, который трогаешь, а не целиком. Цена незнания измерена и одинакова в обоих: ответ выходит связным, по теме и не про то, что спросили, — а отличить это от «модель не поняла вопрос» пользователь не может.

Одно правило оттуда несёт остальные и потому стоит здесь: **подсказку читают вслух.** Никаких обращений к собеседнику, никаких «давайте обсудим, какой вариант подходит», встречных вопросов, меню вариантов и извинений за незнание — всё это будет произнесено. Назвать причину в промпте важнее, чем перечислить запреты: услышав только «не предлагай варианты», модель обойдёт это по букве.

## Permissions

Declared in [GhostMeet/Info.plist](GhostMeet/Info.plist), not in the spec — the spec lists three, the project also declares `NSSpeechRecognitionUsageDescription` for the Apple Speech fallback. Before debugging permission behaviour read the TCC notes in [docs/audio-traps.md](docs/audio-traps.md): grants are keyed to the code signature, and the failure that looks least like a permission problem — an authorised microphone handing back pure silence — is exactly that one.

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature-slug>/` — in-repo, not in GitHub Issues, even though the repository now has a remote. See [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).

### Triage labels

The five canonical roles, unrenamed (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a `Status:` line in each issue file. See [docs/agents/triage-labels.md](docs/agents/triage-labels.md).

### Domain docs

Single-context: one `CONTEXT.md` and one `docs/adr/` at the repo root, both created lazily by `/domain-modeling`. See [docs/agents/domain.md](docs/agents/domain.md).

## Reference projects

The spec draws specific practices from open-source projects; consult them when implementing the corresponding layer: [cue](https://github.com/Blueturboguy07/cue) (dual-channel transcript, flush/RMS-gate constants, mode prompts, content protection), [CallCapture](https://github.com/bodharma/callcapture) / [Recap](https://github.com/RecapAI/Recap) / [AudioCap](https://github.com/insidegui/AudioCap) / [audiotee](https://github.com/makeusabrew/audiotee) (Process Tap), [Scripta](https://github.com/thehwang/Scripta) / [Muesli](https://github.com/Muesli-HQ/muesli) (local STT).
