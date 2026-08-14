# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Язык общения

**Всегда отвечай пользователю только на русском языке** — все объяснения, вопросы и отчёты о выполненной работе. Идентификаторы в коде и комментарии в коде — на английском, по обычным конвенциям Swift.

**Сообщения коммитов и описания PR — на английском.** Репозиторий публичный, и история — такая же его витрина, как README: читают её те же люди и по той же ссылке. Стиль при этом не меняется — заголовок-утверждение о том, что стало правдой, и тело с причиной, а не перечень тронутых файлов.

Коммиты, написанные по-русски до этого решения, остаются как есть. Перевести их — это ещё одна перезапись истории со сменой всех SHA и force-push; делается только по отдельной просьбе.

## Current state

**The MVP is closed: it was walked end to end on a live run (11 August 2026)** — the window stayed out of a screen recording, a headset swapped mid-call was survived, both genres and `Solve on screen` answered, the answers came from the user's заготовки, and a full mock interview on claude-haiku produced no cut streams. The MVP pipeline runs end to end: both channels are captured, turns are cut on pauses, speech is recognised locally into a live transcript — and a suggestion is generated when the user presses a chord, never on its own. **656 tests** across 87 suites (Swift Testing, target `GhostMeetTests`).

Done: project skeleton and test target, microphone capture, turn segmentation, WhisperKit recognition with model selection, the overlay window, the `Them` channel (both backends, SCK by default), settings with per-provider keys, the full provider router (OpenAI-compatible family, Gemini, CLI tools) with streaming, screenshot and OCR on every request, the press-driven suggestion lifecycle (a new press supersedes the answer in flight), two genres of suggestion plus `Ask` and `Solve on screen`, global hotkeys and per-channel indicators, several named profiles with one selected per call and filled in either by hand or from a resume, the `Контекст собеседования` beside them, the readiness strip in the overlay header, and markup in the suggestion card.

Two ticket sets are done and awaiting human review: `.scratch/interview-mvp/` (the original MVP) and `.scratch/hotkey-first/` (the switch to hotkey-triggered suggestions and three ideas taken from cue — question kinds inside the prompt, interview context above the profile, markup in the card). What is left is the v1.0 list in [docs/GhostMeet.md](docs/GhostMeet.md). The background Summarizer is **deliberately not** on the critical path any more: a whole interview is ~10k tokens and fits in one request, so `{{#if summary}}` stays present and empty until a use case longer than an interview appears.

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

Both spec documents are written in Russian. Keep docs and in-app user-facing strings consistent with that; code identifiers and comments follow normal Swift conventions in English.

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

### Silent audio failures

Two independent bugs in this project produced *identical* symptoms — capture running, indicators lit, buffers arriving at the right rate, every sample zero, not one error code anywhere. Both came from the same root: **macOS reports one audio format and delivers another**, and the mismatch is never an error, only silence.

- **Microphone.** With VPIO on, the built-in mic presents **seven** channels — processed mono plus the raw mic-array elements. `AVAudioConverter` has no channel map for folding seven into one, so it returns silence without complaining. Take channel 0 (the processed one) yourself; never ask a converter to downmix >2 channels.
- **Process Tap.** The tap *reports* interleaved stereo and *delivers* two separate channel buffers. `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` returns nil on a layout mismatch — silently — so every frame vanishes while the IOProc runs perfectly. Derive the format from `AudioBufferList.mNumberBuffers`, not from what the tap claims.

The lesson generalises: **in this codebase, never trust a reported audio format — measure what actually arrived.** When audio "doesn't work", the first move is to log frame counts, RMS and buffer layout; return codes will tell you nothing. `MicChannelExtractionTests` guards the first case.

VPIO also **ducks all other system audio** while capturing, and quietens the very audio `Them` is trying to recognise — `voiceProcessingOtherAudioDuckingConfiguration = .min` was the fix. None of this is live any more (ADR-0009 turned VPIO off), and it is written down because the multi-channel trap it caused is *not* gone: any other application can put the device into that mode, and the mic tap must survive it.

### Permissions and TCC

Four usage strings are declared: microphone (You channel), audio capture (Them channel via Process Tap), screen capture (Solve on screen), speech recognition (Apple Speech fallback). Note that macOS shows **no purpose string** for the Screen Recording prompt — `NSScreenCaptureUsageDescription` is declared for completeness, but the user will never read it.

The app is signed with a **stable Apple Development identity** (personal team). This matters more than it looks: TCC grants are keyed to the signature, and while the project was ad-hoc signed every rebuild produced a new identity — macOS then re-prompted, or worse, reported the microphone as authorised and handed the app pure silence. If permissions start behaving oddly, check the signature first. Hardened Runtime is off; if it is ever enabled, microphone access will additionally require the `com.apple.security.device.audio-input` entitlement.

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
- `.scratch/interview-mvp/` — тикеты и спека: статусы, критерии, комментарии о найденном.
- **Ссылки между документами.** Относительные пути легко ломаются; из `.scratch/interview-mvp/issues/` до корня три уровня, а не два. Проверяй, что каждая ссылка ведёт в существующий файл.

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

Семантическое версионирование с **0.1.0**; пока мажорная — ноль, ломающее несёт минорная. Версия живёт в `MARKETING_VERSION`, **во всех четырёх конфигурациях** pbxproj (два таргета × Debug/Release), и расхождение ловится в трёх местах — `set-version.sh`, CI и `release.sh`. Порядок выпуска и его основания — [docs/releasing.md](docs/releasing.md).

```bash
./scripts/set-version.sh 0.2.0   # версия в проекте + номер сборки
#   ← раздел ## [0.2.0] в CHANGELOG.md, затем коммит
./scripts/release.sh 0.2.0       # проверки → тесты → DMG → тег → публикация
```

Версии `0.0.1`–`0.0.6` реконструированы задним числом по истории: проект шёл без версий до закрытия MVP. Это запись вех, а не выпущенные сборки — DMG собирался только для `0.1.0`.

**CI собирает и прогоняет тесты, но ничего не подписывает и не публикует.** Разрешения macOS привязаны к подписи, сертификат у проекта личный (Apple Development), и его закрытая часть в secrets означала бы, что подписывать этим именем может всякий, кто получит доступ к репозиторию. Релиз собирает и подписывает машина разработчика.

## Отдать сборку коллегам

```bash
./scripts/make-dmg.sh
```

Собирает Release, проверяет подпись и наличие всех четырёх строк разрешений в `Info.plist`, кладёт в `dist/` образ с приложением, ярлыком «Программы» и инструкцией. Отдельно от `release.sh` нужен для сборки без тега — показать коллеге промежуточное состояние.

**Нотаризации нет и не будет без Developer ID** — у проекта только сертификат Apple Development, и `spctl` такую сборку отклоняет. Подпись при этом настоящая и стабильная, и это важнее ad-hoc: разрешения macOS привязаны к подписи, при ad-hoc каждая новая сборка спрашивала бы микрофон и запись экрана заново. Цена — карантин, снимается одной командой, и она напечатана и в выводе скрипта, и в файле внутри образа:

```bash
xattr -dr com.apple.quarantine /Applications/GhostMeet.app
```

Стенды для тестирования собираются отдельно — `python3 .scratch/interview-packs/build.py` даёт семь паков по специализациям и архив; см. [.scratch/interview-packs/README.md](.scratch/interview-packs/README.md).

## Where decisions live

Design decisions from the grilling session are recorded, not just implied by the code — read them before reopening a settled question:

- [CONTEXT.md](CONTEXT.md) — the glossary. `You`, `Them`, `Реплика`, `Подсказка`, `Профиль` have precise definitions; use those words and don't drift to synonyms.
- [docs/adr/](docs/adr/) — [0001](docs/adr/0001-swappable-backends-behind-protocols.md) swappable backends, [0002](docs/adr/0002-stt-engine-choice.md) STT engine choice, [0004](docs/adr/0004-invisibility-scope.md) the limits of invisibility, [0006](docs/adr/0006-screencapturekit-default-for-them.md) SCK as the default `Them` backend, [0008](docs/adr/0008-hotkey-triggered-suggestions.md) suggestions on a hotkey, [0009](docs/adr/0009-no-vpio-echo-is-ours-to-handle.md) no VPIO, ever, [0010](docs/adr/0010-update-check-at-launch.md) the update check at launch, [0011](docs/adr/0011-visibility-switch-in-the-window.md) the visibility switch in the window. Superseded ones stay in the directory for the reasoning they carry: [0003](docs/adr/0003-proactive-suggestion-loop.md) (by 0008), [0005](docs/adr/0005-vpio-and-process-tap-cannot-coexist.md) (by [0007](docs/adr/0007-vpio-and-process-tap-do-coexist.md)), and 0007 in its «VPIO always on» half (by 0009 — the rest of it still holds).

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

**Exactly one request is not the user's own, and it is the update check** ([ADR-0010](docs/adr/0010-update-check-at-launch.md)). Everything else on the wire happens because a chord or a button was pressed. At launch the app asks GitHub for the latest published version and says so in one line if it is newer; the request carries an IP and the running version and nothing else, it is on by default because the app is delivered as a disk image with no updater, and it is off with one switch. **Every failure is silence** — no network, a rate limit, a repository with no releases, an unparsable tag all end with no notice and no log line. It does not run under tests: the suite hosts itself inside the app, and every `xcodebuild test` would otherwise put a request on the wire.

**Invisibility is on by default and can be switched off — from the window, never from settings** ([ADR-0011](docs/adr/0011-visibility-switch-in-the-window.md)). The reason is mundane: with `sharingType = .none` the window cannot be screenshot or recorded at all, so a demo required editing a constant and rebuilding. Four constraints hold it together and none is decoration: on by default, **never persisted** (a switch left on last night while recording must not surface at tomorrow's interview), locked — not overridden — while listening, and stated in an orange line for as long as it is off. The settings window follows the same switch. Turning it off also returns the overlay to the app's *own* screenshots, so the model starts seeing its previous answer.

**Invisibility.** The window uses `NSWindow` level + `collectionBehavior` for always-on-top and `sharingType = .none` (content protection) so it is excluded from screen capture — including from our own screenshots, which is what keeps the model from seeing its previous answer. The app runs as an accessory (`LSUIElement`), and whole-display sharing is explicitly out of scope ([ADR-0004](docs/adr/0004-invisibility-scope.md)). **Accessory mode takes «закрыть» with it** — no Dock icon, no menu bar, nothing in ⌘-Tab — so the panel keeps the standard red close button (top left, where macOS puts it) while miniaturise and zoom stay hidden, `windowShouldClose` turns it into a quit, and `SessionController.canQuit` refuses it while listening: the window sits a hand's width from chords pressed without looking, and a stray click would end the call with no undo. Until that button existed, quitting meant Activity Monitor, which is a fair reason to distrust a program that hears your microphone. Failures are surfaced **inside the window only** — a system notification banner would appear over the shared screen and give the app away.

### Audio → answer pipeline

1. **Capture** — mic via plain AVAudioEngine (no VPIO — ADR-0009); `Them` via Process Tap → Aggregate Device → IOProc (or SCK). Both survive a device-mode switch made by somebody else: `CaptureRecovery` listens for `AVAudioEngineConfigurationChange` and reopens the tap, because now that we no longer switch the mode, anyone else can — Phone, WhatsApp, Teams — and without the subscription the microphone dies silently
2. **Buffer + gate** — separate `you`/`them` PCM queues; a turn closes after **1.5 s** of silence, with a minimum length (~0.6 s), an RMS silence gate, and a ~10 s forced flush for pause-less monologues. The threshold used to be 800 ms because every extra 100 ms was 100 ms before the first token; with ADR-0008 it is no longer part of any latency budget, and the higher value is what stops a long question arriving in three pieces. **Do not lower it back on latency grounds**
3. **STT** — WhisperKit per channel, independently
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

Modes that exist: the two genres of suggestion (**коротко** ⌥⌘A and **подробно** ⌥⌘Z), `Ask`, `Solve on screen`. Spec'd but unbuilt: Follow-up, Recap, and the background Summarizer. **The authoritative prompt texts live in [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md); read it before touching prompt-building code, and update it in the same change if a prompt shifts** — the two must match word for word, and a test compares the assembled string against the literal from that document.

Text shared by both genres lives in `PromptFragment` and is substituted into each — `voice` (the register frame plus a «не так / а так» pair), `outOfStack`, `pronunciation`, `questionKinds`, `channels`: two literals that must stay identical would drift on the first edit.

**A question outside the profile's stack is still answered.** `outOfStack` exists because the model resolved a real contradiction the wrong way: the prompt forbids inventing facts about the user, the profile says «Go», and asked about the JavaScript event loop the model replied «это вне моего стека» and asked the interviewer a counter-question — three times out of three. The product decision, and it is not negotiable: **knowledge of a topic is not a fact about the user.** The press happened *because* the candidate does not know; refusing to answer removes the product. «Это не мой стек» is the candidate's line to say, and only after they have the content. Do not «simplify» the closing line back to a single ban — it carries this whole contract now.

Measured alongside it, and still open: on an out-of-stack question the register slips too. The answer comes back nominal («setTimeout с нулём уходит в очередь макрозадач») instead of first person, on every run, while in-stack questions keep «я бы взял». A first-person example inside `outOfStack` did not transfer it.

**Two questions in a row with nothing of the user's between them used to arrive as one line — and that is what the first live run actually broke on.** Capture and recognition were fine; the user watched the right question appear in the window, pressed, and got an answer to the previous one. `TranscriptFormatter` merges adjacent turns of one channel because a question broken by a pause otherwise reads as several people — and it cannot tell «one question split by a pause» from «two different questions nobody answered in between», since by sound they are identical. The press is what tells them apart: the user pressed, so the earlier question is dealt with. `Turn.isBeforePress` marks the boundary and the merge never crosses it.

Merging aside, nothing said **which** line was the current question. With one question that is obvious; with two the model guesses, and it guessed the earlier one. `PromptFragment.currentQuestion(in:)` now names it on its own line right before the ask — the strongest position in the message — and is omitted entirely when the interlocutor has not spoken yet.

**The recognition budget expiring used to be silent, and that is how the first live run broke.** A press force-closes the open `Them` turn and waits up to `SessionEngine.recognitionBudget` (4 s) for the words; over budget the request goes out **without** them, which is right — waiting longer costs the thing the press was for. What was wrong is that nothing said so: the interviewer asked, the user pressed, and the model answered the *previous* question with an answer that looked entirely normal — coherent, on topic, just not about what was asked a second ago. `wait(upTo:)` returns whether the work finished in time and the return value was discarded; it now becomes a `Suggestion.notice` above the answer. The words are not lost either way — recognition is never cancelled — so the next press already has them.

**A cut answer is not a failure, and until now it was not anything at all.** An answer that ran out of budget, or whose stream died mid-sentence, settled as `.complete` — indistinguishable on the card from a model that answered briefly, which the user discovers while reading half a sentence out loud. `SuggestionCutoff` carries the three shapes (`.budget`, `.connection`, `.empty`), every wire format detects its own, and the providers throw it **after** the fragments so the text survives; `SessionEngine` settles it as `Suggestion.State.cut`, which the card renders under the answer rather than instead of it. Note the counter in each read loop: falling out of the loop at all means the provider never closed the stream, and zero delivered characters means the model said nothing — the second closes the old «reasoning models return an empty completion at 512 tokens» note.

**`decode(line:)` returns a *list* of events, and the first version of this change did not — which broke Gemini completely.** One chunk can carry two facts: vLLM and half the gateways put `finish_reason` on the same chunk as the closing fragment, and for Gemini that is not an edge case but the normal shape — each SSE chunk is a whole `GenerateContentResponse`, and a short answer is one chunk with text *and* `finishReason`. Returning a single event and checking the text first meant the reason was never read; since that dialect has no `[DONE]`, the stream then ended with no terminal event and **every finished answer was reported as a dropped connection**. The `MAX_TOKENS` branch was unreachable in live traffic for the same reason. Adversarial review caught it before the app ever ran — the test helper was building `"parts":[]`, a shape Google does not send, so all 25 Gemini tests agreed with the bug.

**A refusal that arrives after any text becomes a cutoff, and the conversion lives in the read loop** — the only place that knows whether anything was delivered. The card renders `.failed` *instead of* the answer, so a moderation filter tripping on the last chunk, a gateway erroring mid-stream, or a CLI tool taking a SIGTERM would erase a half-read suggestion from under the user while they were speaking it. `SuggestionCutoff.stopped(reason)` keeps the text and puts the reason under it.

**«Он уже начал отвечать вслух» is a fact, not a framing — and the app knows it.** The short genre asserted it unconditionally, in the opening paragraph of the system prompt and again in the closing line of the user message. It is false in exactly the case the app is built around: a press force-closes the open `Them` turn, so the interviewer has just stopped and the candidate is still silent. Both cases are real (the press flushes `You` too), so `TranscriptFormatter.hasStartedAnswering` decides and `BriefPrompt` carries both redactions. Dropping the claim was the wrong fix and was not taken — it is what stops the genre restarting the answer from the top, the original live complaint, so the «не с начала» half survives in both.

Measured alongside: with a half-finished `You` line in the transcript, models restate what the candidate has already said — gpt-5.4-mini opened with a verbatim copy of the user's own line in both runs, claude with an ellipsis. Hence «не повторяя сказанного мной» in the closing ask and «продолжай с неё и не пересказывай её» in the opening. **The defect is invisible without a `You` turn**, which is why months of bench runs never showed it — and why the bench now switches redaction along with the checkbox.

**A prohibited example is a demonstration, not a prohibition — and the pronunciation rule proved it three times.** Each redaction forbade a broken bracket by printing it («и „бакеты (бакеты)“ — мусор», «не оригинал латиницей („промис (promise)“)», «не по слогам („мак-ро-таск“)»), repaired the shape it named, and taught the neighbouring one. The third was measured on five models at once: **twelve spoiled brackets out of twenty-one, and four of the twelve are verbatim copies of strings that existed only as prohibitions.** «микротаски (микротаски)» came back from three different models.

The rule that replaced them is positional — the alphabet test sits *inside* the trigger («сразу за латинскими буквами — и только за ними»), so it never fires on Cyrillic instead of firing and being told not to — and it contains no negative example at all. `BriefPromptTests.thePromptShowsNoBrokenBracket` guards the class rather than the wording: it scans both assembled genres for a bracket with Cyrillic to its left and a single word inside, which is the shape of all three failures and of no legitimate parenthetical in the prompt.

Note the boundary with the pair below, because it is not a contradiction: a «не так / а так» pair works when both halves are whole sentences from somebody else's conversation — a copied one is visible. A two-word bracket is not; it drops into an answer and reads as the model's own. **Show the wrong thing only when copying it would be obvious.**

**The register frame is load-bearing and was measured, not guessed.** A live run showed the model writing *to* the user («Используйте Hash Map», «это позволит вам») instead of *for* them, and skipping the pronunciation brackets on everything it judged ordinary — three of fourteen terms got one. What fixed it was showing rather than forbidding: the frame states that the output is the user's own next sentence, a wrong/right pair demonstrates the register, and every escape hatch («только там, где произношение неочевидно») was deleted. Keep the pair, the opening frame and the closing repeat — they are there because the prompt is read by whatever model the user picked, and the weakest of them obeys examples but routes around bans.

Cross-cutting rules from that file that are easy to get wrong:

- Never crash or bail on an empty transcript — substitute a placeholder like `(пусто)` and still answer, or, where the document's template guards the block with `{{#if transcript}}`, omit it entirely. Never send a bare heading: that reads to the model as "nothing was said", which is a different and usually wrong claim
- Don't force Russian: response language follows the language of the Them/You turns or the user's question
- Every mode that reads the conversation now reads the same window — the whole call — because the sizes 12 / 14 / 20 were budgets for a Summarizer that does not exist. `Solve on screen` still reads none of it. Token budgets differ: ~512 for the short genre, 2k for `Ask`, 4k for the detailed genre and `Solve`
- Every mode attaches the screenshot to the *user* message and also passes the Vision-framework OCR text, which is the only thing a text-only provider ever learns about the screen
- The optional `resume_context` block at the end of that file is **not optional here** — it carries the user's `Профиль` and ships in the MVP. Without it the model suggests experience the user doesn't have, which is a worse failure than a slow answer. The one exception is `Solve on screen`, whose answer goes into an editor rather than into a sentence said out loud — see note 5 of the prompt document
- **The suggestion is read aloud, and every prompt rule follows from that.** No addressing the interviewer, no "let's discuss which option fits", no counter-questions, no menu of options, no apologising for not knowing — all of it would be spoken. Naming the reason in the prompt matters more than listing the bans: told only "do not offer options", a model routes around it by the letter

## Permissions

Declared in [GhostMeet/Info.plist](GhostMeet/Info.plist), not in the spec — the spec lists three, the project also declares `NSSpeechRecognitionUsageDescription` for the Apple Speech fallback. See the TCC notes above before debugging permission behaviour.

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature-slug>/` — in-repo, not in GitHub Issues, even though the repository now has a remote. See [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).

### Triage labels

The five canonical roles, unrenamed (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a `Status:` line in each issue file. See [docs/agents/triage-labels.md](docs/agents/triage-labels.md).

### Domain docs

Single-context: one `CONTEXT.md` and one `docs/adr/` at the repo root, both created lazily by `/domain-modeling`. See [docs/agents/domain.md](docs/agents/domain.md).

## Reference projects

The spec draws specific practices from open-source projects; consult them when implementing the corresponding layer: [cue](https://github.com/Blueturboguy07/cue) (dual-channel transcript, flush/RMS-gate constants, mode prompts, content protection), [CallCapture](https://github.com/bodharma/callcapture) / [Recap](https://github.com/RecapAI/Recap) / [AudioCap](https://github.com/insidegui/AudioCap) / [audiotee](https://github.com/makeusabrew/audiotee) (Process Tap), [Scripta](https://github.com/thehwang/Scripta) / [Muesli](https://github.com/Muesli-HQ/muesli) (local STT).
