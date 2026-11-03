# Aitvaras: agent rules

These are the shared rules for every coding agent (Claude Code, Codex, others)
and every human contributor. `CLAUDE.md` imports this file; tool-specific
notes live there. Directories with their own `AGENTS.md` add rules for that
area. Read the nearest one before editing.

## The project

Aitvaras is a local-first agentic AI assistant for macOS. It has a 3D
companion character and DE/EN voice. The product, targets, modules, bundle
identifier, state paths and assistant identity are all named **Aitvaras**,
after the Lithuanian household dragon (`docs/AITVARAS.md`).

| Doc | Role |
|---|---|
| `docs/DECISIONS.md` | Source of truth for product and architecture decisions (numbered D-entries). Read it before changing direction on anything; update it when a decision changes. |
| `docs/ROADMAP.md` | Milestone status. |
| `docs/MASTERPLAN.md` | The forward plan. |
| `docs/ARCHITECTURE.md` | Module map. |
| `docs/TESTING.md` | Test layers, isolated profiles, manual checklist. |
| `docs/README.md` | Index of all other docs. |

Machine-specific context (paths, accounts, hardware, homelab) goes in a
gitignored `CLAUDE.local.md` / `AGENTS.local.md`, never in tracked files.

## Commands

Use `make` targets so every agent runs the same thing:

| Command | What it does |
|---|---|
| `make setup` | Once per clone: enables the repo's git hooks (`.githooks/`). |
| `make test` | `swift test` on the AitvarasKit package. Works without Xcode. |
| `make node-test` | Offline contract tests for the Node sidecar helpers. |
| `make app` | `xcodegen generate` plus a Debug app build into `.build-xcode`. |
| `make privacy` | Privacy and secret sweep over tracked files. |
| `make check` | privacy + node-test + test. Run it before every commit. |
| `make smoke` | check + app. Run it before every PR that touches `App/` or `project.yml`. |

Run a single suite with `swift test --filter <Suite>`. The app needs full
Xcode 27 (Xcode 26.6's compiler crashes on the app target); the package
also builds with Xcode 26. Both `-skipMacroValidation` and
`-skipPackagePluginValidation` are required; `make app` passes them.

## Hard rules

- **Local only.** No cloud LLM APIs, ever. Subprocess sidecars (Python TTS,
  Claude Code / Codex CLIs on the user's subscription) are fine. Never add an
  API-key fallback.
- Aitvaras may only modify Calendar/Reminders items she created herself.
- Aitvaras must never be able to send email (D20): mail tools are
  read/search only.
- Every side effect goes through AgentCore's autonomy policy (`read` /
  `reversibleWrite` / `confirmable`) and is written to the activity log with
  provenance. Connectors never bypass this.
- Memory discipline: pipeline-extracted sensitive facts are quarantined
  (`needsReview`) until approved. Superseded facts are invalidated, never
  deleted; hard deletion is a user action.
- Secrets (cookies, tokens, bot tokens) live in the profile-scoped macOS
  Keychain, never in the DB, files, logs or test output.
- Character aesthetic: rigged 3D figure, serious, cyber only as accents. Not
  anime, not a mascot, not abstract or hologram.
- Swift 6 strict concurrency; engines and connectors are actors.
- GRDB stores UUID columns in its own encoding: never compare or insert UUIDs
  in raw SQL via `.uuidString`; use record APIs. The FTS mirror tables
  (`ragFTS`, `factFTS`) are the deliberate exception.
- Target hardware is Apple Silicon with 32+ GB. The model budget is ~20 GB
  total; never plan for dense 70B-class models.

## Public repository hygiene

This repository is public. Everything you commit, including commit messages
and PR text, is published.

- Never commit installation-specific values: credentials, tokens, cookies,
  email addresses, usernames, hostnames, IP addresses, Home Assistant
  entity/device/area names, personal filesystem paths, or identifiers copied
  from a live service. Docs, fixtures and tests use clearly synthetic values
  and reserved domains (`example.invalid`, `192.0.2.0/24`, `/home/user`).
- If live verification needs real values, inject them at runtime and make
  sure commands and logs never print them.
- Commits are authored with the maintainer's GitHub noreply address. No
  co-author or "generated with" attribution lines in commits, PRs, issues or
  comments; the hooks and CI reject them.
- `make privacy` must pass. If it flags something, fix the content; don't
  widen the exclusions.

## How work flows (several agents at once)

`main` is always releasable and protected: changes land through a PR whose CI
is green. There are no required reviews, so a PR is mostly a CI gate plus a
record.

1. **Claim.** Work comes from a GitHub issue where possible. Label it
   `agent:claude` / `agent:codex` (or assign yourself) before starting, and
   check that nobody else holds an overlapping issue.
2. **Isolate.** One task = one branch = one worktree:
   ```sh
   git fetch origin
   git worktree add ../Aitvaras-<topic> -b <agent>/<topic> origin/main
   ```
   Branch prefixes: `claude/`, `codex/`, `fix/`, `feat/`, `docs/`, `chore/`.
   When you run the app, use your own profile:
   `AITVARAS_STATE_DIR=$(mktemp -d)` plus
   `AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1`. Never use the default profile.
3. **Commit small.** Focused, descriptive commits (imperative subject ≤ 72
   characters, body says *why*). Stage only your own work. Never sweep in
   unrelated pending changes or another agent's untracked files.
4. **Stay current.** Rebase on `origin/main` before opening the PR and again
   if it falls behind. Never force-push `main`; force-push your own branch
   only with `--force-with-lease`.
5. **Ship.** `make check` (plus `make app` for UI work), then
   `gh pr create --fill` and `gh pr merge --auto --squash`. The PR merges
   itself when CI passes. Fix red CI yourself; don't disable checks.
6. **Clean up.** Remove the worktree after merge (`git worktree remove`).

Small doc-only fixes may go straight to a PR without an issue.

### Collision hotspots

Parallel branches tend to collide in a few places. Rules for each:

- **DB migrations** (`Sources/AitvarasStore/Database.swift`) are numbered
  `vN-topic` and run in registration order. Take the next free number
  *when you rebase*, append at the end, and never renumber or edit a
  migration that is already on `main`.
- **Decisions.** A new `D<n>` entry takes the next free number at rebase
  time. If someone else took it first, renumber yours and its references.
- **`project.yml` / `Package.swift`:** keep the diff minimal; one dependency
  change per PR.
- **Shared docs** (`ROADMAP.md`, `TESTING.md`): append to the relevant
  section instead of rewriting others' sections. Session logs, overnight
  notes and checkpoint diaries don't belong in docs. Put them in the PR
  description or the issue.

## Definition of done

- `make check` passes locally and CI is green.
- New behavior has tests, including the failure path (engine down, garbage
  output, duplicate input, bogus IDs). A pipeline test that covers only the
  happy path is incomplete.
- UI changes build (`make app`) and were checked in an isolated profile
  (`docs/TESTING.md`, Layer 3) when behavior is visible.
- Docs that describe the changed behavior are updated in the same PR,
  including `DECISIONS.md` when a decision changed.
- The PR description states what was verified and what wasn't.

## Boundaries

- Don't change repository settings, branch protection, releases or secrets
  unless the maintainer asks for that specific action.
- Don't create tags or releases; releases are cut by the maintainer
  (`CONTRIBUTING.md`).
- Don't delete user data, worktrees or branches you didn't create.
