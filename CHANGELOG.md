# Changelog

All notable changes to GhostMeet are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The minor number goes up when
the app gains a capability it did not have before; the patch number carries fixes and refinements
of what is already there. Breaking changes go in a minor too, and are named as such in the notes.
The major number becomes `1` when the v1.0 list in [docs/GhostMeet.md](docs/GhostMeet.md) is
closed — see [docs/releasing.md](docs/releasing.md) for the whole release order.

Versions below `0.1.0` were reconstructed from the commit history after the fact: the project ran
unversioned from its first commit until the MVP closed, and the milestones are recorded here
rather than invented. Each one is tagged at the commit where that body of work landed.

Design decisions referenced below live in [docs/adr/](docs/adr/); the product spec is
[docs/GhostMeet.md](docs/GhostMeet.md).

## [Unreleased]

### Added

- **A dead `Them` channel now moves to the other backend by itself.** When capture
  fails, the app switches ScreenCaptureKit ⇄ Process Tap and says so in one line
  instead of leaving the channel silent. The fallback happens once per run — a
  second failure is the machine's answer, not something to keep retrying — and it
  never undoes a backend the user picked by hand.

### Fixed

- **Pronunciation brackets are tidied up in the suggestion card.** The prompt asks
  for `nginx (энджин-икс)` and mostly delivers it; the leftovers were a bracket
  repeating the Russian word it followed («кластер (кластер)») and an inverted pair
  («(кубернетис) Kubernetes»), both of which are read aloud and both of which make
  the reader say a word twice. They are now fixed where the card is built, and
  deliberately not by an eleventh rewording of the rule — see
  [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md) §6 for why. Formulas like
  `O(n log n)`, brackets inside code blocks and ordinary Russian asides are left
  exactly as they were, and the saved call keeps the model's raw answer.

## [0.5.1] — 2026-08-18

### Fixed

- **Half the interface stayed Russian on an English window.** The turn-segmentation
  fields, the warning about where a résumé is sent, the line about the audio route,
  every capture and provider failure — around a hundred strings in all. The cause is
  the one already written down in CLAUDE.md and stepped on anyway: `Text(строка)` is
  not localized, only `Text(ключ)` is, and a literal that reaches a `String` needs
  `String(localized:)`. Two shapes hid from the first pass — strings built inside
  `String`-returning properties, and multi-line `"""…"""` literals.

  Checking this by eye is what let 0.5.0 out, so it is not checked by eye any more:
  `scripts/find-untranslated.sh` reads the sources and refuses a literal that reaches
  a `String` unlocalized. It runs in CI before the tests and inside `make-dmg.sh`.

- **A number inside a localized string was formatted for the locale.** An OSStatus of
  `-12345` was shown as «-12.345» — grouped as though it were a quantity, and
  unsearchable. Error codes are interpolated as strings now.

### Added

- **A «Перезапустить» button beside the language picker.** Changing the interface
  language takes effect on the next launch — that is the price of doing it through
  `AppleLanguages`, and it buys strings that a `SwiftUI`-only path would have left
  in the old language. What was missing was a way to pay it: the screen said
  «применяется после перезапуска» and left the user to close and reopen the app by
  hand. During a call the button refuses, for the same reason an update does.

## [0.5.0] — 2026-08-18

### Added

- **The interface speaks English as well as Russian.** It follows the system language and can be
  switched in settings; the change takes effect on the next launch.

  This is the language of the *window*. What the model answers is a different question and has not
  changed: a suggestion follows the language of the call, because it is read aloud to the
  interviewer rather than to you. An English interview is answered in English whatever the window
  says.

- **The settings window is five pages instead of one scroll nine sections long** — profile, sound,
  recognition, model, about. Fields no longer change width with what is in them, and labels are
  aligned to the left rather than pushed against the middle of the window.

### Changed

- **One prompt rule now follows the call rather than being unconditional.** In a Russian call the
  model is told to put a Russian pronunciation after every Latin term — `nginx (энджин-икс)` —
  because Latin cannot be read aloud inside a Russian sentence. In an English call that rule is not
  sent at all: the answer is English, all of it is Latin, and a Cyrillic gloss in the middle of a
  spoken English sentence is not a nuance but an unreadable line.

## [0.4.0] — 2026-08-17

### Added

- **GhostMeet installs its own updates.** A new version is no longer the whole first install over
  again. The window shows one line — «Вышла версия …» — and one press downloads the image, verifies
  its signature and replaces the app. No dragging into Программы, no terminal.

  **The point is the quarantine, not the button.** Until now every install — and therefore every
  update — needed `xattr -dr com.apple.quarantine` typed into a terminal. That is a wall a
  non-technical user does not climb: they see «программу нельзя открыть», they do not open a
  terminal, and they stay on the old version forever. Quarantine is applied by whoever downloads the
  file: a browser does, an application does not. So an update the app installs never carries it, and
  the command is needed exactly once, for the first install
  ([ADR-0012](docs/adr/0012-sparkle-installs-the-update.md)).

  Microphone and screen-recording grants survive an update: macOS recognises the app by its
  signature and bundle identifier, not by its version.

  **0.4.0 itself still has to be installed by hand.** 0.3.3 has nothing to update with, so the first
  automatic update is the one *after* this version.

- **A «Проверить сейчас» button in settings.** Until now a switch just turned on meant nothing until
  the next launch, while looking as though it meant something.

### Changed

- **The updates switch is named for what it does** — «Проверять и ставить обновления» instead of
  «Проверять новую версию при запуске». It was always the consent for the request; it is now the
  consent for the install as well, and a switch that understates what it permits is worse than no
  switch.

  Off means what it meant, only more strictly: **no request at all.** With the switch off the
  updater is never built — not built and quiet, not built.

- **Nothing about updating happens during a call.** The app already refuses to quit while listening;
  installing is the same restart, only not asked for by a human, and the refusal now covers it
  whole. The update line is not shown during a call at all: it carries the button that replaces the
  application, and the window sits a hand's width from chords pressed without looking.

- **No window outside GhostMeet's own.** The update mechanism ships a full interface of windows and
  system notifications; all of it is off, and everything updating has to say is said on one line
  inside the app's window ([ADR-0004](docs/adr/0004-invisibility-scope.md)).

- **The old version check is gone rather than kept alongside.** Exactly one request in this app is
  not the user's own, and it is now the update feed
  ([ADR-0010](docs/adr/0010-update-check-at-launch.md)). The optional system profiling the mechanism
  is capable of is turned off — and checked against the built application on every release, rather
  than against a constant of our own.

- **A failed update now says how it ended.** «Every failure is silence» still holds for the request
  nobody asked for. But the outcome of a press has to be named: a silent failed install leaves
  somebody certain they have updated, walking into an interview on the old build.

## [0.3.3] — 2026-08-15

### Fixed

- The `Them` channel comes back when its stream breaks, instead of staying silent for the rest of
  the call. Found live and painfully: the stream died 1.1 seconds after it started («сбой
  трансляции из‑за прерванного подключения к приложению»), Chrome stayed alive so nothing woke the
  channel, and every word the interviewer said for the next 37 minutes was recorded in `You` —
  reaching the microphone through the speakers, exactly as designed, because a channel is decided
  by the source of its audio. The transcript did not look broken; it looked normal and named the
  wrong speaker throughout.

  Re-attaching after a source change and after the browser restarting was already handled — a
  stream that simply broke was the one event the service only reported. It now retries on the
  microphone's delays and, if the channel really is gone, says so once.

- A silent `Them` says what it costs, not what the framework noticed. The window did show
  «Произошел сбой трансляции…» that evening and it was read straight past, which is the right
  reaction to a sentence that carries no consequence. During a call the notice now leads with
  «Собеседника сейчас не слышно — его слова пишутся как ваша речь» and keeps the technical reason
  behind it. This matters more than a status line usually would: while `Them` is dead, both
  defences against channel leak are inert by construction — strict mode waits for loud `Them`
  frames, and the text deduplication has no `Them` turns to compare against.

## [0.3.2] — 2026-08-15

### Fixed

- Lines nobody said no longer appear in the transcript. Handed a stretch of audio with sound but no
  speech in it — a breath, a keystroke, a headset click — Whisper answers with a phrase frequent in
  its training material, and one 37-minute call collected four of them: `Thank you.` twice, a bare
  `you`, and `Продолжение следует...`. Recognised text that is *entirely* one of those known
  phrases is now dropped, and the turn stays in the transcript without words like any other
  unrecognised one. Speech that merely contains such a phrase is kept untouched, and `Спасибо.` —
  said constantly, and as a whole turn — is deliberately not on the list.

  The one in the `Them` channel is why this is a fix and not a tidy-up: a second interviewer had
  just asked about liveness and readiness probes, and the invented phrase took that question's
  place. An answer built on a transcript missing the question comes out coherent, on topic, and
  about something else, which is indistinguishable from the model misunderstanding.

- Every test fixture now waits on the one shared budget, and the budget is 30 seconds. The three
  provider suites were the last holdouts at two seconds, and they fell during this very release —
  `TestWait` had said they would be converted when a failure showed up, and one did. Eight seconds
  then turned out to be too short as well, on a machine sitting at `load average` 25 with nothing
  of ours on it: eleven waits timed out while the same suite run alone finished in 0.312 s. A wait
  limit measures nothing, so it is now picked for the slowest imaginable machine rather than the
  fastest.

- CI is green on `main` again, for the first time since `0.2.0`. The wait that `0.3.1` raised in one
  fixture was too short in three others, and the runner is slower than this machine: every red run
  since `0.2.0` was the same handful of `modelWasAsked` waits timing out, in different tests each
  time — which is what made it read as a flake rather than one cause.

  The four engine fixtures now share one documented budget instead of each keeping a number of its
  own. Two of them said eight seconds and two said two, and nobody had chosen that: one simply
  fell behind. A constant that lives in one place has nothing to drift from. The provider fixtures
  keep their own, shorter waits — they wait on a stubbed stream rather than on the press path, and
  they have never failed.

## [0.3.1] — 2026-08-15

### Added

- **A saved call says what each answer was asked for.** Until now every answer in the file looked
  alike, though pressing can ask for four different things: the missing piece at ~512 tokens, a
  subject unfamiliar whole at 4 000, a typed question, and the task on screen — which reads none of
  the conversation the rest of the file is made of. Reading back an answer that ignores the
  question above it is bewildering until the words «задача с экрана» explain it.

  `Ask` carries the question itself, because there is no `Them` turn above such an answer to say
  what it was about. A failed press records its kind too: the press happened either way.

  The kind is a value of the context layer that `App` maps its `SuggestionAsk` into, never the
  reverse — the store of what the model said must not learn what a prompt is (ADR-0001). It is
  optional, so an answer that does not say is still written as plain «Подсказка» rather than being
  given a kind nobody asked for.

### Fixed

- Ten timing-sensitive tests no longer fail on a busy machine. The release script runs the suite
  twice — once for `--dry-run`, once for real — and the second run starts right after a Release
  build and a disk image, which is the most loaded the machine gets all cycle. The whole suite
  stretched from 1.7 to 3.4 seconds and a two-second wait in one of the fixtures ran out; the same
  suite alone passes in 0.117 s. The sibling fixture had always allowed eight seconds for the same
  operation, and the two disagreeing was an oversight rather than a decision. A wait in a fixture
  measures nothing — the loop exits the moment its condition holds — so the longer bound is free on
  working code and only ever spends time on broken code.

## [0.3.0] — 2026-08-14

### Added

- **Saving a call to a file** — the first user request this project has had. A button under the
  transcript writes both sides of the conversation and the model's answers into one Markdown file,
  in the order they happened, with a header naming the profile, the provider and the source app.

  Turns marked as speaker leakage are left out, and **the number dropped is stated in the header**.
  That line is not decoration: `LeakDedup` needs five matched words before it marks anything, so a
  short leak is never marked at all — and a silent clean-up would make «протечек не было»
  indistinguishable from «фильтр их не увидел».

  Cut, superseded and failed answers are saved with their reason rather than skipped: half an
  answer is what the user actually read out loud.

  Nothing is written anywhere until the save panel returns a location. Until this feature the app
  wrote nothing to disk at all, and that is still true of everything else.

### Fixed

- The test suite stopped killing itself, and with it two days of red CI. A wait that timed out on a
  cold machine let its test carry on into an array nothing had filled; `Array` traps on the index,
  the trap takes the process, and every suite that had not started yet reports «Test run with 0
  tests» — a line that reads as success. Whichever timing-sensitive test lost the race first
  decided which part of the suite looked broken, which is why the cause appeared to move every run.
  Those waits now use `#require`, which stops its own test instead of the host.
- The app no longer loads a speech model when it is being used as a test host. It was fetching
  WhisperKit on every `xcodebuild test` — network, hundreds of megabytes and the Neural Engine —
  behind a process the suite expects to answer in milliseconds. The local suite went from 10–14
  seconds to under two.

### Changed

- CI runs on every branch rather than only on `main`, keeps the crash report when the host dies,
  and states the toolchain it used. Work happens in branches now; `main` and tags move under a
  release.

## [0.2.0] — 2026-08-14

### Added

- A visibility switch in the overlay header
  ([ADR-0011](docs/adr/0011-visibility-switch-in-the-window.md)): one press puts the window back
  into screen capture. It exists because with `sharingType = .none` the app cannot be screenshot or
  recorded at all — a demo previously meant editing a constant and rebuilding. On by default, never
  written to disk, locked (not overridden) while listening, and announced in an orange line for as
  long as it is off. The settings window follows the same switch.

  Note the cost, stated in the button's tooltip: a visible window is back in the screenshots
  GhostMeet takes for itself, so the model starts seeing its own previous answer. The switch is
  there to record a demo, not to run a call with.

### Changed

- The author's name is gone from the repository — the copyright line, a file header, and a test
  fixture. What no file edit can reach is named where it matters: the commit history and the code
  signature of the published disk image both still carry an address.

## [0.1.0] — 2026-08-12

The MVP, walked end to end on a live interview on 11 August 2026: the window stayed out of a
screen recording, a headset swapped mid-call was survived, both suggestion genres and
`Solve on screen` answered, and a full mock interview produced no cut streams.

### Added

- Versioning: `MARKETING_VERSION` starts at `0.1.0`, a changelog, retroactive tags, and a release
  script that builds, signs, and publishes a DMG.
- An update check at launch ([ADR-0010](docs/adr/0010-update-check-at-launch.md)): one request to
  GitHub for the latest published version, and one line in the window when it is newer than the
  build in hand, linking to the release page. It ships in this first release on purpose — a build
  without it would be the last one its owner ever hears about. On by default because the app is
  handed over as a disk image with no updater; off with one switch in settings, and off means no
  request at all. Every failure is silence, and the line goes away as soon as listening starts.
- A DMG for colleagues (`scripts/make-dmg.sh`) that verifies the signature and all four
  permission strings before packaging, and ships instructions for the quarantine flag.
- Seven interview packs by specialisation for manual testing — each runs a whole interview aloud
  and waits for the candidate to answer.
- A quit path. Accessory mode has no Dock icon and no ⌘-Tab entry, so until now quitting meant
  Activity Monitor. The panel keeps the standard red close button, and `SessionController` refuses
  it while listening — the window sits a hand's width from chords pressed without looking.

### Changed

- The three chords pressed during a call moved into one cluster under the left hand (`⌥⌘A`,
  `⌥⌘Z`, `⌥⌘X`): the thumb holds `⌥⌘` and the fingers reach all three without moving the wrist.

### Fixed

- A press no longer answers the previous question in silence. The recognition budget expiring was
  invisible: the interviewer asked, the user pressed, and the model answered what came before with
  an answer that read as entirely normal. The timeout now surfaces as a notice above the answer.
- Two questions in a row with nothing of the user's between them no longer arrive as one line.
  `TranscriptFormatter` merges adjacent turns of one channel, and it cannot hear the difference
  between one question split by a pause and two unanswered questions — the press is what tells them
  apart, and the merge no longer crosses it. The current question is now named on its own line
  right before the ask.

## [0.0.6] — 2026-08-10

Prompt hardening, all of it measured on real model runs rather than guessed.

### Added

- Cut answers are named out loud. An answer that ran out of budget or whose stream died
  mid-sentence used to settle as complete — indistinguishable from a model that answered briefly,
  which the user discovers while reading half a sentence aloud. `SuggestionCutoff` carries the
  three shapes (budget, connection, empty) and the card renders the reason under the text, never
  instead of it.

### Changed

- A question outside the profile's stack is answered rather than declined. Asked about the
  JavaScript event loop with Go in the profile, the model replied "that's outside my stack" and
  asked a counter-question, three runs out of three. Knowledge of a topic is not a fact about the
  user, and the press happened *because* the candidate does not know.
- The pronunciation rule was rewritten positionally, with no forbidden example in it. Each earlier
  redaction forbade a broken bracket by printing one — and twelve spoiled brackets out of
  twenty-one came back, four of them verbatim copies of strings that existed only as prohibitions.
- "He has already started answering" became a fact the app checks rather than an assertion the
  prompt makes: a press force-closes the open `Them` turn, so the interviewer has just stopped and
  the candidate may still be silent.

### Fixed

- A stream ending normally without a sentinel no longer raises a cutoff alarm.
- Gemini reported every finished answer as a dropped connection. `decode(line:)` returned a single
  event where one chunk can carry two facts — for Gemini a short answer is one chunk with text
  *and* `finishReason` — so the reason was never read and the stream ended with no terminal event.

## [0.0.5] — 2026-08-07

### Changed

- **VPIO is never enabled** ([ADR-0009](docs/adr/0009-no-vpio-echo-is-ours-to-handle.md)). System
  echo cancellation did stop the interlocutor's voice leaking from the speakers into `You` — and it
  switched the *device* into multi-channel mode, costing every **other** process reading the
  built-in mic 28–32 dB. Chrome is one of them, so a browser call had the candidate arriving at the
  interviewer 31 dB quieter, and never finding out.

### Added

- Three layers of our own in its place: a route classifier that decides whether the built-in mic
  can hear the built-in speakers, a strict mode that refuses to open a `You` turn while `Them` is
  sounding, and text dedup that marks a `You` turn matching a simultaneous `Them` turn as leakage.
- Capture survives a device-mode switch made by somebody else: `CaptureRecovery` listens for
  `AVAudioEngineConfigurationChange` and reopens the tap. Now that we no longer switch the mode,
  anyone else can — and without the subscription the microphone dies silently.
- A local bench page that sends the app's real prompts to several models at once, streaming, with
  time to first token and actual cost per press.

## [0.0.4] — 2026-08-06

### Changed

- **Nothing reaches the model until the user presses**
  ([ADR-0008](docs/adr/0008-hotkey-triggered-suggestions.md), superseding ADR-0003). A candidate
  knows most of the answers; help is wanted when they don't. Answering everything cost tokens,
  filled the feed, and buried the model in crumbs.
- The suggestion is the user's own next sentence, not advice addressed to them. A live run showed
  the model writing "you should use a Hash Map" instead of the line to say out loud.

### Added

- Two genres that differ in size, not content: brief (`⌥⌘A`, ~512 tokens) for the missing piece
  when the user is already speaking, detailed (`⌥⌘Z`, 4k) for a topic unfamiliar whole.
- A press force-closes the open `Them` turn and waits for recognition under a budget — the user
  presses before the pause threshold elapses, so without it the last phrase of the question is
  missing from the prompt.
- `Контекст собеседования` beside the profile: stories from practice, why this company, money
  expectations, questions for the employer.
- Markup in the suggestion card — lists, emphasis, inline and block code — parsed afresh on every
  stream fragment, so half-written markup renders sanely.

## [0.0.3] — 2026-08-05

The MVP feature set, complete end to end for the first time.

### Added

- The full provider router: OpenAI-compatible family, Gemini, Claude, CLI tools, local servers —
  all behind one protocol with streaming and cancellation, keys per provider in Keychain.
- ScreenCaptureKit as the default `Them` backend
  ([ADR-0006](docs/adr/0006-screencapturekit-default-for-them.md)); the Process Tap stays as the
  second one. The default flipped on a measurement: SCK delivers 1.5–2.5× more signal.
- A screenshot with Vision OCR attached to every request.
- Global hotkeys on Carbon `RegisterEventHotKey` — a global event monitor would have needed the
  Accessibility permission, a fifth prompt for a keyboard spy.
- Per-channel indicators and the readiness strip in the overlay header.
- `Ask` and `Solve on screen`.
- Several named profiles with one selected per call, filled in by hand or parsed from a resume.
  The resume file is never stored — read once, held in a local variable for one request.

## [0.0.2] — 2026-08-04

### Added

- Dual-channel capture: `You` from the microphone, `Them` from the source application via Core
  Audio Process Tap. The two never mix — separate buffers, separate recognition, separate labels.
- Turn segmentation: a turn closes after a pause, with a minimum length, an RMS silence gate, and
  a forced flush for pause-less monologues.
- WhisperKit recognition behind a protocol, with the model chosen in settings.
- The always-on-top overlay with `sharingType = .none`, accessory mode, and a live transcript.
- Settings with per-provider keys, and the first streamed suggestion from Claude.

## [0.0.1] — 2026-08-03

### Added

- The project skeleton: Xcode project targeting macOS 14.4 (Core Audio Process Tap needs it), the
  test target, and four usage-description strings in a real `Info.plist` — `INFOPLIST_KEY_*` drops
  keys Xcode does not know, silently.
- The design record: [CONTEXT.md](CONTEXT.md) as the glossary, ADRs 0001–0004, the product spec,
  and the MVP ticket set for one scenario — a technical interview where the user is the candidate.

[Unreleased]: https://github.com/slimgo/ghostmeet/compare/v0.3.3...HEAD
[0.3.3]: https://github.com/slimgo/ghostmeet/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/slimgo/ghostmeet/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/slimgo/ghostmeet/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/slimgo/ghostmeet/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/slimgo/ghostmeet/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/slimgo/ghostmeet/compare/v0.0.6...v0.1.0
[0.0.6]: https://github.com/slimgo/ghostmeet/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/slimgo/ghostmeet/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/slimgo/ghostmeet/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/slimgo/ghostmeet/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/slimgo/ghostmeet/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/slimgo/ghostmeet/releases/tag/v0.0.1
