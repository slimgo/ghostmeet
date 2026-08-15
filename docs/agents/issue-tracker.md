# Issue tracker: Local Markdown

Issues and specs (you may know a spec as a PRD) for this repo live as markdown files in `.scratch/`.

Work is tracked entirely in-repo, deliberately: the repository has a remote, but GitHub Issues are not used. A ticket and the code that closes it travel in one commit, and a checkout carries the whole record with it.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01` — never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading
- A **`Читать:`** line names the two or three documents this ticket actually needs — see below

## `Читать:` — the reading list of a ticket

Every ticket names, in one line, what has to be read before it is picked up, and
nothing more:

```
**Читать:** [спека](../spec.md) · [ADR-0009](../../../docs/adr/0009-no-vpio-echo-is-ours-to-handle.md) · `LeakDedup.swift`
```

The line exists because an agent that is not told what to read has two options and
both are bad. Read everything, and half the context window is gone before the first
edit — this repository is around 2 500 lines of documentation, and a ticket
typically needs under a tenth of it. Read nothing, and repeat a mistake somebody
already paid for: this project has ADRs precisely because its settled questions
look reopenable from the outside.

Two rules keep the line useful rather than decorative:

- **Three entries, not ten.** A reading list nobody can finish is a reading list
  nobody starts. If a ticket genuinely needs ten documents, it is two tickets.
- **Name the specific file, not the directory.** `docs/adr/` is not an answer;
  `ADR-0009` is. The point is to spare the reader a search, and a directory hands
  the search back.

`CLAUDE.md` and `CONTEXT.md` are never listed: the first is loaded into every
session anyway, and the second is the glossary, which is read the moment a term is
unclear rather than up front.

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` — the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.
