# Testing strategy

Aitvaras is an always-on assistant with local models, OS permissions and
personal state — exactly the kind of app that degenerates into "the developer
clicks around and hopes". This document defines the layers that replace that,
and how to run each one. The design goal: **everything that can be verified
without a human ear or a TCC dialog is verified by a command.**

## Layer 1 — package tests (`swift test`)

The core logic lives in the SwiftPM package (AitvarasKit) and tests without
Xcode:

```sh
swift test                       # full suite
swift test --filter Consolidator # one suite
```

Conventions:

- **In-memory database per test** — `Stores(db: try AitvarasDatabase(url: nil))`
  runs the full migration chain, so schema changes are exercised on every run.
  Migration behavior itself is tested end-to-end by deleting a row from
  `grdb_migrations` and re-opening (see `migrationImportsLegacyMemoriesIntoFacts`).
- **Deterministic fakes instead of models** — `ScriptedEngine` (canned
  responses per call, `<<THROW>>` marker to simulate a dying engine) and
  `FakeEmbedder` (topic-marker vectors so "semantic" matches are assertable)
  live in `Tests/AitvarasCoreTests/TestSupport.swift`. Model *quality* is not
  unit-testable; model *plumbing* (parsing, fallbacks, idempotence, gating,
  provenance) is — and that's where the bugs live.
- **Every pipeline tests its failure path**: engine down, garbage output,
  duplicate input, bogus IDs from the model. A pipeline test that only covers
  the happy path is considered incomplete.
- MLX generation cannot run under `swift test` (Metal library only resolves
  inside app bundles). Those paths run in Layer 3's self-test instead.

## Layer 2 — app-target build (compile verification)

The SwiftUI app compiles headlessly; run after any `App/` change:

```sh
xcodegen generate    # only after adding/removing files
xcodebuild -project Aitvaras.xcodeproj -scheme Aitvaras -configuration Debug \
    -derivedDataPath .build-xcode \
    -skipMacroValidation -skipPackagePluginValidation build
```

Both `-skip*Validation` flags are required (plugin/macro validation hangs or
fails outside interactive Xcode).

## Layer 3 — isolated live profiles (`AITVARAS_STATE_DIR`)

All persistent state (database, logs, connector manifests, models) resolves
through `AitvarasPaths`. Setting `AITVARAS_STATE_DIR` relocates the entire profile,
so a live app can be exercised **without touching real memories** — by you,
or by an agent driving the app on your behalf:

```sh
export AITVARAS_STATE_DIR=/tmp/aitvaras-test     # throwaway profile
export AITVARAS_SHARE_MODELS=1                # reuse downloaded model weights
.build-xcode/Build/Products/Debug/Aitvaras.app/Contents/MacOS/Aitvaras \
    --seed-demo-state
```

- `--seed-demo-state` fills an **empty** profile with a fictional persona
  ("Alex", physics student with a homelab — see `StateFixtures`): facts in
  every state (current, superseded, quarantined), entities, open questions,
  activity history, a goal. It refuses to touch a database that already has
  facts, so it can never pollute a real profile.
- The real profile in `~/Library/Application Support/Aitvaras` is untouched;
  delete the temp directory afterwards and nothing remains.
- Keychain items are currently NOT namespaced per profile — connector tokens
  are shared. Don't run token-mutating connector tests against an isolated
  profile expecting isolation there.
- In-bundle model runtime check: `Aitvaras --selftest` (MLX generation,
  the one thing Layer 1 can't cover).

## Layer 4 — smoke script (the pre-push gate)

```sh
./scripts/test-smoke.sh
```

Runs Layer 1 + Layer 2 and the tracked-file privacy sweep from
`scripts/prepare-public-release.sh` (pattern check only, no branch creation).
Green smoke = safe to push.

## Layer 5 — manual checklist (the irreducible human part)

These need ears, permission dialogs, or external accounts. Run after changes
to the respective subsystem, with the app installed normally:

| Area | Check |
|---|---|
| Voice input | ⌥Space-hold starts listening; German + English utterance transcribed; barge-in interrupts TTS |
| TTS | Neural voice on (Setup): German reply quality; Apple fallback when sidecar stopped |
| Mail | New mail appears in activity log triaged; urgent mail pushes to Telegram when away; mail stays unread |
| Calendar/Reminders | "erstell mir einen Termin morgen 10 Uhr" creates the event in the Aitvaras calendar; Aitvaras refuses to edit foreign events |
| Memory | "merk dir, dass …" → fact appears in Memory view with *you said* badge; correction in the editor supersedes with history |
| Consolidation | Next morning: Activity shows a `consolidationRun` digest (or a loud FAILED entry — never silence) |
| Permissions | Fresh macOS user: Setup checklist flows through mic/speech/calendar/reminders/mail grants in order |

## What an agent session should do

For Claude Code (or any agent) working on this repo: Layers 1–2 after every
change set; Layer 3 with a temp profile when behavior needs a live app; never
launch the app against the default profile; never store test tokens in the
Keychain. The demo persona is fictional on purpose — assertions in agent-run
live tests should reference it (Alex/TU München/homelab), which doubles as a
guard that the real profile was not loaded.
