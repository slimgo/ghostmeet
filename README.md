# GhostMeet

[![CI](https://github.com/slimgo/ghostmeet/actions/workflows/ci.yml/badge.svg)](https://github.com/slimgo/ghostmeet/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/slimgo/ghostmeet?display_name=tag&sort=semver)](https://github.com/slimgo/ghostmeet/releases)
[![Platform](https://img.shields.io/badge/macOS-14.4%2B-black)](https://github.com/slimgo/ghostmeet)

An always-on-top macOS overlay that assists during a video call. It listens to **two audio
channels**, transcribes them **on device**, and answers through whichever LLM you point it at —
while staying out of screen sharing.

Русская версия — [README.ru.md](README.ru.md).

> **Status: 0.3.0.** The MVP is closed and was walked end to end on a live call. It is a personal
> BYOK tool, not a product: there is no backend of ours, no account, and no notarised build.

---

## What it does

- **Two channels that never mix.** `You` is your microphone; `Them` is the audio of the
  application running the call. Channel membership is decided by *source*, never by meaning —
  everything from the mic is `You`, even when you read someone else's question aloud.
- **Local speech recognition.** WhisperKit on the Apple Neural Engine, one pass per channel,
  cut into turns on pauses. Nothing is sent anywhere to be transcribed.
- **A suggestion only when you ask for one.** Capture, segmentation and recognition run
  continuously and fill a transcript; the model is called only when you press a chord
  ([ADR-0008](docs/adr/0008-hotkey-triggered-suggestions.md)).
- **The screen travels with every request.** A screenshot plus Vision OCR, taken at the press —
  which is what makes `Solve on screen` work at all.
- **Invisible to screen sharing.** The window is excluded from capture via `sharingType = .none`,
  including from the app's own screenshots, so the model never sees its previous answer. A switch
  in the header turns that off — the only way to screenshot or record the app itself. It is on at
  every launch, never remembered, and locked while a session is listening
  ([ADR-0011](docs/adr/0011-visibility-switch-in-the-window.md)).
- **Any provider.** Anthropic, OpenAI-compatible endpoints, Gemini, local servers (Ollama,
  LM Studio, llama.cpp, MLX-LM), and CLI tools — all behind one protocol, keys in Keychain.

The target scenario is one: **a technical interview where you are the candidate.** That is the
tightest requirement set — latency matters and `Solve on screen` is a primary mode. Everything
else is a relaxation of it.

## How it works

```
 mic ─────────────► You buffer ─┐
                                ├─► turn segmenter ─► WhisperKit ─► transcript
 SCK / Process Tap ► Them buffer┘         (pause, RMS gate, safety flush)
                                                                    │
                            press ⌥⌘A / ⌥⌘Z / ⌥⌘X ──────────────────┤
                                                                    ▼
                                       screenshot + OCR ─► prompt ─► LLM ─► card
```

A press force-closes the open `Them` turn before composing — you press the moment the interviewer
stops, which is *before* the pause threshold elapses, so without it the last phrase of the
question would be missing. Recognition is never cancelled: those words belong to the conversation
regardless of which answer survives.

## Requirements

- macOS **14.4 or later** — Core Audio Process Tap needs it.
- Apple silicon recommended: speech recognition runs on the Neural Engine.
- An API key for a cloud provider, or a local model server.

Four permissions are requested, each for one thing: **microphone** (`You`), **audio capture**
(`Them`), **screen recording** (screenshots and `Solve on screen`), **speech recognition** (the
Apple Speech fallback).

## Install

Download the DMG from [Releases](https://github.com/slimgo/ghostmeet/releases), drag the app to
Applications, then remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/GhostMeet.app
```

**The build is signed but not notarised, and that command is not optional.** The project has an
Apple Development certificate, not a Developer ID, so Gatekeeper refuses the app until the flag is
cleared. The signature is real and stable, which matters more than it
looks: macOS permission grants are keyed to the signature, and an ad-hoc-signed build would
re-prompt for the microphone and the screen on every update.

The app runs as an accessory — **no Dock icon and no ⌘-Tab entry.** Launch it from Spotlight or
from the Applications folder, not from Launchpad, where it does not appear.

## Build from source

**Xcode 26 or newer.** The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a
Swift 6.2 build setting; on Xcode 16.x it does not build at all.

The Xcode project lives one level down, at `GhostMeet/GhostMeet.xcodeproj`:

```bash
xcodebuild -project GhostMeet/GhostMeet.xcodeproj -scheme GhostMeet -configuration Debug build
```

Run the suite (Swift Testing, target `GhostMeetTests`):

```bash
xcodebuild -project GhostMeet/GhostMeet.xcodeproj -scheme GhostMeet -destination 'platform=macOS' test
```

Package a signed DMG:

```bash
./scripts/make-dmg.sh
```

Two traps worth knowing before you touch the project file:

- `GhostMeet/GhostMeet/` is a **file-system-synchronized group** — a new `.swift` file joins the
  target just by existing. Any *non-source* file dropped in there is copied into the bundle as a
  stray resource, which is why `Info.plist` sits beside the project rather than inside it.
- Usage-description strings must go in that real `Info.plist`. `INFOPLIST_KEY_*` only works for
  keys Xcode knows, and it drops unknown ones such as `NSAudioCaptureUsageDescription` **without a
  warning** — the build succeeds and the app ships with no access to the screen.

## Privacy

- Speech recognition is on device. Audio never leaves the machine.
- API keys live in the Keychain, never in the repository or in settings files.
- Nothing is written to disk unless you turn it on.
- A resume used to fill in a profile is read once and never stored — not on disk, not in
  `UserDefaults`, not in a log. Before you press the button, the screen names the provider that
  will receive the text and says whether it leaves the machine.
- Logging is lifecycle-only. There is no per-frame logging anywhere, deliberately: in this app a
  per-frame log writes the conversation to disk.
- **Saving a call is the one thing that writes to disk, and only you can start it.** The button
  under the transcript builds a Markdown file — both sides of the conversation and the model's
  answers — and hands it to a save panel, so the file exists where you pointed rather than in a
  folder of ours. It is the whole conversation in plain text; treat it accordingly.
- **One request is not yours: the update check.** At launch the app asks GitHub for the latest
  published version and shows one line if it is newer. It carries an IP address and the running
  version, nothing else, and the answer is a page anyone can open. On by default because there is
  no updater and no other way to learn a new build exists; one switch in settings turns it off, and
  off means no request at all. See [ADR-0010](docs/adr/0010-update-check-at-launch.md).

## Limits

- **Whole-display sharing is out of scope**, by decision, not by omission — see
  [ADR-0004](docs/adr/0004-invisibility-scope.md). Share a window or a tab.
- Both `Them` backends work at **application** granularity. Neither can isolate the browser tab
  with the call from the rest of the browser.
- The build is not notarised, and will not be without a paid Developer ID.
- `SpeechAnalyzer` (macOS 26) is faster but has no Russian locale, so it is scoped to
  English-language calls and is not built yet.

## Where the decisions live

This repository is as much a design record as a codebase. Read these before reopening a settled
question:

| | |
|---|---|
| [docs/GhostMeet.md](docs/GhostMeet.md) | the product spec — features, stack, file layout, roadmap |
| [docs/GhostMeet-Prompts.md](docs/GhostMeet-Prompts.md) | the authoritative prompt texts, matched word for word by a test |
| [CONTEXT.md](CONTEXT.md) | the glossary: `You`, `Them`, `Реплика`, `Подсказка`, `Профиль` have precise definitions |
| [docs/adr/](docs/adr/) | eleven architecture decisions, superseded ones kept for the reasoning they carry |
| [CHANGELOG.md](CHANGELOG.md) | what landed, when, and why |

Two rules govern changes here: documents are corrected by the same change that touches the code,
and **an ADR is never rewritten** — to change a decision you write the next one and link back.
Both are spelled out in [CLAUDE.md](CLAUDE.md).

The spec and the decision records are written in Russian; code identifiers and comments follow
normal Swift conventions in English.

**The app's interface is in Russian.** Worth knowing before you download it: the buttons say
«Слушать» and «Настройки». What the model *answers* is not forced to any language — a suggestion
follows the language of the call, so an English-language interview is answered in English today.

## Releasing

Releases are cut locally, because the signing identity stays on one machine:

```bash
./scripts/release.sh 0.2.0
```

The script refuses a dirty tree, checks that the version matches the project and has a section in
the changelog, runs the tests, builds and signs the DMG, tags, and uploads. CI on GitHub builds
and tests every push but never signs. See [docs/releasing.md](docs/releasing.md).

## License

[MIT](LICENSE). The interview packs and benches under `.scratch/` are part of the repository and
carry the same licence; the models you point the app at have their own terms, and the API keys are
yours.
