# Testing strategy

## Unified chat and provider controls

The direct CLI backends in `AitvarasAgents` have offline executable replay tests
(`ClaudeBackendTests`, `CodexBackendTests`). Every sanitized recording under
`Tests/AitvarasCoreTests/Fixtures/agents` is replayed through the real process
transport, comparing outgoing JSON frames. Additional cases cover complete
Claude content blocks and native IDs, subscription refusal, browser login,
Codex thread multiplexing, mode changes, rate limits, stale approvals, exact
integer/string request IDs, duplicate and late replies, disconnect/reconnect,
malformed output and oversized lines. These tests neither launch installed
providers nor send model prompts. Native history discovery remains unsupported
until M5; the backends are not yet connected to the app.

`AgentConformanceTests` exercises `AgentActionCoordinator` with both fake
providers, including executable hook/approval replies and real Claude
recording replays: Ask offers one native permission card, Accept edits
continues Write/Bash without cards, and Plan allows its plan-file write and
internal ToolSearch before requesting plan approval. Recorded hook envelopes
with injected forbidden tools are denied in every mode. Additional cases
cover bookkeeping tools, explicit whitelists, permission grants in Plan, modes,
approve/deny, duplicate requests and answers, stale scopes, audit failures,
shutdown during pending approvals and audit writes, forbidden service actions,
unknown requests and uncertain outcomes. A real in-memory Store is also used
as the audit sink. Claude interruption tests put an assistant execution error
and terminal result before the interrupt acknowledgement to reproduce Stop
races. The supervisor runs live-provider and host-only checks separately.

`AgentChatStoreTests` and `AgentTurnStoreTests` exercise fresh and upgraded
schemas, UUID foreign keys, duplicate native identities, cross-chat rejection,
legacy identity preservation, monotonic delivery, partial output and recovery
without replay. `AgentSessionManagerTests` use both generated provider executables
and controllable runs: two same-provider chats, view detachment, scoped Stop,
capacity, idle resume, failures before/after the durable barrier, duplicate input,
stale input/generation callbacks, startup interruption and bounded shutdown with
subsequent sends. Reducer checks include stable canonical message IDs, tools,
thinking, hook observations, usage, rate limits and outcomes. Snapshot streams
coalesce updates; provider event streams remain lossless.

Host acceptance for this foundation still needs a private database copy upgrade,
a real force-quit during delivery, parallel real chats, idle resume, and application
quit cancellation once the manager is wired into the UI. The package tests do not
establish those UI or live-provider properties.

Live acceptance still needs the official CLIs and an isolated synthetic project
to verify subscription authentication, browser completion, native persistence,
hook coverage and sandbox enforcement. Offline replay cannot establish those.

One workspace chat now displays local and app-owned Codex/Claude messages in one
bounded timeline. Backend thread IDs are internal, not another user-facing
conversation selector. The chat-level Local/Codex/Claude segmented control has
an adjacent settings gear; its single panel initially selects that backend and
can switch tabs without changing the active provider. Claude uses the selected
official subscription profile and must never silently route to another backend.

The M4.1 Local candidate is opt-in with
`AITVARAS_LOCAL_CHAT_BACKEND=codex-oss`; unset or `agent-loop` retains
LocalBackend. `CodexOSSConfigurationTests` checks exact app-server arguments,
loopback/proxy restrictions, explicit installed-model selection, metadata-only
discovery, unavailable service, missing executable, cloud/remote model refusal,
provider/model mismatch before prompt delivery, unsupported actions and no
fallback after turn failure. Codex tool/approval/interrupt recordings are
replayed with a synthetic Ollama provider/model selection; they are not live
Ollama recordings. A real Store/manager test verifies fresh ephemeral Local
threads and completed context on each Send. No test loads a model.

The host M4 gate must build the app, use a fresh isolated profile and a synthetic
project, enable the candidate switch and select Local with an installed local
model. If connectors are disabled, `AITVARAS_AGENT_TEST_PROVIDERS=real` is still
required to permit this explicit provider test. Verify the installed app-server
accepts the pinned configuration, inspect inference locality, test real tool
approval and denial, Stop, two Sends and provider switches, and measure total
model memory against the budget. Stop Ollama and confirm Unavailable and no
fallback; restart it and refresh status. Review light/dark and minimum-window
states. Default adoption and M4.2 resource coordination remain host decisions.

## Claude subscription adapter checkpoint

Run `node scripts/test-claude-interactive.mjs` for no-provider helper contracts,
then package tests and an app build. `--claude-workspace-check --uishot <path>`
uses an injected transport and synthetic in-memory data; require
`AITVARAS_UI_TEST_MODE=1`, a fresh `AITVARAS_STATE_DIR`, and
`AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1`. It exercises account isolation,
history consent, durable delivery, partial text, cancellation, unknown outcomes,
canonical message deduplication and failed-refresh preservation. It does not
sign in, read a real account or send a model prompt. `--claude-ui-fixture`
provides a separate visual fixture using the same isolation guards.

Store tests cover v25 upgrades, immutable profile/session/message identity,
independent revision-bound file grants, complete-history handover and canonical
snapshot corrections without journal completion. Transport fixtures cover
bounded framing, environment sanitization, durable acknowledgements, account
drift and crash-safe worker ownership. Live subscription acceptance must use
only a separately authorized synthetic project after offline checks pass.

## Earlier unified-chat checkpoints

Local-to-Codex selection requires confirmation before enabling shared history
for that chat. Switching sends nothing. Explicit Send checks the account if
needed, then prepares a new owned thread only when required. Recent completed
chat history is included in the first prompt of a fresh backend thread; failed
or uncertain Codex turns stay visible but are excluded from model context.
Imported histories, files, captures and other chats never enter this projection.
History is bounded to 16,000 characters and the wire prompt to 64 KiB, preserving
the user's unsent draft on preparation refusal. The stored user message remains
the original text, not a duplicated history envelope.

Package tests cover projection scope, ordering, limits and incomplete outcomes.
The app Codex check covers no-history-without-approval, approved handoff context,
original-message persistence and the UTF-8 wire bound in addition to prior
streaming/ownership/stop checks. The existing account-status diagnostic succeeded
after the runtime-artifact fix; it did not send a model prompt. See
[UI menu audit](UI-MENU-AUDIT.md) for the broader source-level UI review and
remaining visual-verification recommendations.
This checkpoint passed 487 package tests in 51 suites, 19 no-provider helper
contracts, synthetic shared-chat handoff/turn checks, capture lifecycle checks,
single-main-window checks and 84 sidebar geometry combinations. Native runtime
artifact checks also repeated startup and no-model thread creation on disposable
profiles with networking denied. A real account-status check returned signed-in
with available models; real model response generation was not tested.

## Interactive Codex prototype

`--codex-workspace-check --uishot /tmp/codex-workspace-check.png` uses an injected
synthetic transport and an in-memory database. As with other app diagnostics,
both `AITVARAS_UI_TEST_MODE=1` and a new `AITVARAS_STATE_DIR` are mandatory; set
`AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1` too. It checks local-only opening,
reviewed context, durable owned-ID binding, streamed partial output, follow-ups,
acknowledged stopping, uncertain-outcome blocking, stale context and metadata-only
Activity. It invokes no CLI, sign-in, model, account, device or external service.

The simplified flow additionally verifies that explicit first Send creates one
owned conversation and one turn, a follow-up reuses it, and unapproved project
settings, empty prompts and invalid models do not reach the transport. Saving
project settings is the single approval action, not a checkbox or session sheet.
Store tests cover atomic instructions/folders/provider saving and stale editors,
including concurrent provider changes and project renames. UI review should
confirm one modal level, project settings reachable from the project menu,
an editable composer before the first conversation, and draft retention after
a refused first Send. No UI simplification grants files, tools or imported IDs.
This checkpoint passed 483 package tests in 50 suites sequentially, the focused
policy/session tests and the synthetic app-level composer check. A concurrent
build/test run hit two timing assertions; both passed on an isolated recheck and
the complete sequential run. No live provider prompt was used.

`--codex-ui-fixture --uishot /tmp/codex-ui.png` renders the same interactive view
with a synthetic completed conversation. This is a layout check, not a live
provider test. Layer-backed screenshots are not a substitute for supervised
installed-app visual review.

The native runtime has a separate private profile, Keychain-only authentication,
strict version/schema/config gates and an owned-ID registry. Check the helper's
synthetic tests as well as the older native loopback proof below. No production
provider override exists. Live authentication, quota, catalog/tool selection and
native multi-turn persistence must be tested only after explicit approval; do not
describe those as verified by the app fixture.

`node scripts/check-codex-interactive.mjs` runs 17 no-cloud helper contract tests.
Its optional `--native-preflight <absolute executable>` runs a clean,
unauthenticated startup with all native network access denied; it never starts a
login or turn. Swift transport tests generate small Node fixtures to verify
framing/UTF-8, binding acknowledgement, environment isolation and safe errors.

`node scripts/check-codex-keychain.mjs` tests the macOS Keychain correction using
only a unique temporary nonsensitive item, immediately deleted, with network
denied. It verifies that the same sandbox denies private-home reads and allows
the owned profile. No existing credential items are read and no Keychain default
settings are changed.
The native text-isolation proof now has five scenarios, including a contaminated
HOME protected by this filesystem boundary. The real OAuth retry is supervised;
these checks do not sign in or use a paid model.

For the sidebar regression, run `--sidebar-window-check --uishot /tmp/sidebar.png`
under the same isolated guards, with and without `--hide-sidebar-fixture`, and
with each `--open-capture`, `--open-chat`, `--open-history` and `--open-setup`
route. The explicit window-level toolbar item must be present in both states.
Shown-state checks seed populated projects/chats, cycle all sections at four
window sizes (including a tall narrow window) and all activity-dock placements,
and assert the actual button
center and project-column origin as well as the 50-point icon rail and
246-point Chat workspace. The root must fill the window and stay left-aligned;
the footer cannot widen the complete sidebar. Geometry probes and test route/dock
switching are isolated-profile diagnostics only, with no production refresh work.
The rail stays below the title bar. Verify clicking the toggle and title-bar
appearance visually after installation; the probe checks mounting, not pixels.

The Keychain boundary now permits metadata-only access to ancestors of its
allowed profile/OS paths; contents and directory listings remain denied there.
This is required when the profile is inside the user's home, not just under a
temporary root. Add `--profile-in-home` to the native preflight to exercise a
fresh synthetic in-home profile with spaces in its path. The Keychain probe also
uses that layout and tests canonicalization. It never uses an existing login.

The ancestry/rail regression checkpoint passed 480 package tests, 17 helper
contracts, all five native synthetic-provider isolation scenarios, in-home
native startup with networking denied, Keychain write/delete and denied content
and directory-listing probes. Release workspace and section-cycling rail checks
passed. A direct account-status check on the existing profile also completed
without starting sign-in or inference; it reported signed out. OAuth completion
and the first real provider conversation still require supervised verification.

Checkpoint results: 479 package tests in 50 suites passed, as did 16 helper
contract tests, the deny-network native preflight, optimized Release build,
owned-workspace fixture, capture lifecycle, native-history regressions and all
eight sidebar route/visibility probes. Appearance inheritance/reset passed after
explicitly updating existing windows as well as the app override. The installed
binary matched Release, startup succeeded, and all pre-update conversation,
message, capture, capture-target, project/chat and native-evidence identities
were retained. Startup created no dedicated Codex profile or owned session/turn.
No live authentication or model request was performed. Visual sidebar review
and the first authenticated native conversation remain supervised checks.

## Capture idle-sleep and frontier-safety checkpoint

Serial package suite: 475 tests in 49 suites. Native capture lease tests use
injected assertions, covering audio/display policy, partial acquisition rollback,
idempotent release and owner lifetime. The isolated `--capture-lifecycle-check`
also exercises failure before inputs, cancelled/suspended startup, stop, device
failure, quit, save retry and a pre-forced-sleep checkpoint with a gap warning.
These checks open no audio/screen inputs and invoke no model.
The separate isolated `--capture-sleep-native-check` briefly acquires/releases
the actual macOS idle-system/display assertions without opening inputs. It
does not force sleep, close a lid or test physical continuity during sleep.

Owned frontier-session tests cover v20 upgrade preservation, same-title identity,
review/context invalidation, imported-ID rejection, turn reservations, terminal
state integrity, acknowledged cancellation/completion, restart reconciliation
without replay and unresolved-work protection against automatic chat archival.
They do not create a provider session or enable an interactive app feature.

`node scripts/check-codex-text-isolation.mjs /absolute/path/to/codex` is a manual
macOS/native compatibility proof with a loopback-only synthetic provider. It
checks clean context, a contaminated-home negative control, exact advertised
tool names, and native rejection of fabricated file/shell calls. No credentials,
account, real model service or subscription quota are used. See
[FRONTIER-CODEX-PROOF.md](FRONTIER-CODEX-PROOF.md) for limitations and required
authenticated follow-up gates. Never ship its test provider override as fallback.

Debug and optimized Release builds passed. Release capture lifecycle, native
power-assertion, native-history, appearance and four workspace fixtures passed.
After approved installation, the binary matched the verified Release build,
startup/v21 migration succeeded, and pre-update conversation/message/capture,
capture-target and native-evidence IDs were retained. The new owned-session and
provider-turn tables remained empty: installation starts no provider work.
Physical recording through display sleep and the user's visual review remain
supervised checks; no live lecture or frontier account was used here.

## Quick appearance control

The sun/moon control at the bottom of the main navigation rail offers Light,
Dark and System. Its preference is profile-scoped; System clears the app-wide
AppKit override so separate capture/companion panels follow macOS again.
Package tests cover missing/invalid values and all three persisted choices.
Run `--appearance-check --uishot /tmp/appearance-check.png` with the same isolated
profile and UI-test guards below to check native-window inheritance and reset.
This diagnostic opens no devices/providers and exits without writing an image.

## Structured workspace checkpoint A1

See [NEXT-WORKSPACE-PLAN.md](NEXT-WORKSPACE-PLAN.md) for the checkpoint boundary.
The full package suite passes with `swift test --skip-update --no-parallel`:
403 tests in 41 suites. A concurrent run stalled in existing voice/stream-timeout
tests after the workspace suites passed; the serial run completed in full.
Debug and optimized Release app builds pass. The installed app is not replaced
by these build or isolated-profile checks.

Workspace tests cover additive upgrade preservation, atomic assignment, stable
provider identities, primary/temporary lifecycle, manual restoration grace,
context/tool isolation and assignment while legacy memory inference is pending.
The last case verifies that no global facts, episode, entity or deduplication
fingerprint can be written after the source chat becomes project-scoped.

Bootstrap-free app checks use an isolated `AITVARAS_STATE_DIR`,
`AITVARAS_UI_TEST_MODE=1` and `AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1`:

- `--workspace-fixture primary --uishot /tmp/workspace-primary.png`
- `--workspace-fixture empty --light-fixture --uishot /tmp/workspace-empty.png`
- `--workspace-fixture archived --uishot /tmp/workspace-archived.png`
- `--workspace-fixture unassigned --light-fixture --uishot /tmp/workspace-unassigned.png`
- `--workspace-fixture primary --recent-fixture --uishot /tmp/workspace-recent.png`
  opens the rail on the shared cross-project list

Every scenario first checks empty-project routing, rejected input, busy selection,
archive/message retention, project hotkey voice refusal, read-only voice history,
assignment without copying message identities and persisted selection restoration.
No real profile, device input, model, connector or cloud account is started.
Snapshots show the workspace surface directly; full-window cached rendering can
omit AppKit-backed navigation, and layer-backed colors/text may be incomplete.
Use these for structural checks, not final visual approval. A supervised
installed-app review is still required before claiming appearance is verified.

## One chat transcript and handover (D30)

`AgentHistoryReconciliationTests` covers native open/resume with executable
Claude and Codex fixtures, streamed-row identity, external continuation,
parent-branch selection, corrections/deletions, atomic rollback, duplicate IDs
and failed/inconsistent refreshes. `AgentHandoverTests` covers normalized and
legacy context beyond a UI page, UTF-8 byte limits and omission counts, revision
receipts, exact-envelope stripping, and unknown delivery. Lifecycle/Stop tests
retain their transport scripts and inject journal-backed history fixtures.

Host acceptance for this path: open a native chat, Send, continue it in its CLI,
reopen it in Chat, then switch providers and Send again. Verify one copy of every
message and inspect the collapsed handover. Repeat after a native edit or branch
change, with light/dark appearance and the minimum window size. The sandbox
package suite cannot compile or visually verify `App/ChatModel.swift` or
`App/Views/AgentChatView.swift`.

`WorkspaceHandoverTests` cover what a thread has not seen: a new thread is
caught up on everything other threads wrote; after a delivered handover only
newer messages travel; undelivered and uncertain turns never do; over budget
the newest messages are kept and the rest counted; messages sharing a
timestamp follow timeline order, not their IDs; and a recorded handover is
never handed on again.

The handover regression checks also cover 1,005 missed messages (all omissions
counted), an older missed message behind more than 400 own-thread entries, and
embedded/pasted handover markers. Native projection tests require exact recorded
send/turn/wire evidence before hiding an envelope; another native turn or an
edited message must retain its complete text. These checks use isolated stores,
not real histories or providers.
Exact watermark identity must also survive corrected native timestamps; only a
missing watermark permits the conservative timestamp fallback (including ties).

`--codex-workspace-check` keeps an Aitvaras-only thread across Local turns and
checks the delta, an empty delta, a second thread being caught up on the first,
and the byte limit. `--codex-native-workspace-check` checks consented handover
inside a native message, its record after acknowledgement, and that Aitvaras
shows only the typed text. `--codex-ui-fixture --open-chat` renders a chat with
a handover line. All use synthetic transports; no provider is contacted.

## Native history checkpoint A2 (in progress)

Read-only native Codex and Claude Code history: discovery, preview, reviewed
import and separate read-only source panes. The reader suites drive synthetic
fixtures and the app-level checks stage synthetic pages, so no live provider,
account or native session is contacted by these checks.

The four `--workspace-fixture` scenarios above now also cover refused import
into a hidden project with the reviewed preview retained, imported source
identity by provider/host/external ID, the saved continuation cursor, local
paging of saved text, separation of imported text from the local chat and its
message store, and refusal to re-home a linked native session into another
project.

Live discovery against installed Codex and Claude Code and provider pagination
over real histories remain separate from these synthetic checks. Reviewed
folder/provider ceilings are covered by A2b below; enforced execution sandboxing
and native trust review are not implemented yet.

### Native import hardening

Full serial package suite: 449 tests in 45 suites. Debug and optimized Release
app builds pass, as do the Release app's synthetic native-history check and four
workspace scenarios. Added coverage includes shared
preview/storage ordering, conflicting message revisions, source-version/fence
changes, non-advancing cursors, bounded complete refresh, transactional rollback,
explicit fork versus spawned-parent provenance, and operation lifecycle handling.
The v19 upgrade preserves old evidence and leaves complete-refresh/provenance
claims unknown until explicitly established; a v18-to-v19 on-disk upgrade test
checks retained message identities, revisions and legacy parent references.

Run the bootstrap-free app check with an isolated `AITVARAS_STATE_DIR`,
`AITVARAS_UI_TEST_MODE=1`, `AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1` and:

`--native-history-fixes-check --uishot /tmp/native-history-fixes.png`

This checks filter changes (including changing away and back during a read),
same-count preview changes and stale consent, conflicting preview rejection,
imports in Activity/History, refreshed tail edits beyond the first page, cached
revision updates, and Activity Stop remaining pending until cancellation is
acknowledged without mutating the saved snapshot. Readers are synthetic; there
are no accounts, recordings, models, SDK downloads or native-session writes.
The check exits with its result and does not produce a screenshot.

The installed Release startup and v19 migration were checked after a local
database/app backup. Existing conversation, message, native-message and revision
identities were retained. This did not exercise live provider history or replace
the user's visual review of the installed controls.

History operations report generic purpose/provider/data categories, not native
titles, paths or transcript content. Test telemetry-storage failure separately:
it must never replay a provider operation. Quit waits for native helper cleanup;
a refused quit may enable new explicit work but never replay cancelled work.

### Boundary/context and capture-target checkpoint A2b

Full serial package suite: 457 tests in 46 suites. New tests cover safe defaults,
bounded metadata-only context, reviewed ceilings never granting tools/cloud,
stale review rejection, change-and-revert invalidation, direct folder mutation,
malformed policy fail-closed behavior, stable capture links, atomic rollback,
deletion cleanup and on-disk v19-to-v20 preservation. The earlier v16 upgrade
fixture also runs through v20 without assigning old records.

The workspace fixtures additionally verify that policy review enables no
execution and that linked capture text stays outside the local prompt. Add
`--inspect-context` or `--inspect-boundaries` to `--workspace-fixture primary`
for structural inspector/review UI snapshots (same isolated-profile guards).

`--capture-lifecycle-check` now also exercises targeted empty reservation,
archive before the first real checkpoint, same-title/UI-switch isolation,
failed final save and retry, recovered link preservation, quit checkpoint and
safe empty-reservation cleanup. No recording devices or providers are opened.

Capture association is a local database reference, not automatic Markdown
delivery, message insertion, retrieval eligibility or provider export. Provider
ceiling choices are saved policy metadata only; scoped file execution is still
disabled. Native cached screenshots remain structural checks, not visual approval.

Debug and optimized Release builds passed, along with Release capture/native
checks, four workspace scenarios and both inspector fixtures. After approved
installation, the running binary matched the Release build, startup and v20
migration succeeded, and the pre-install backup's conversation, message,
capture, native-message and revision IDs were all retained. Existing captures
were not assigned to projects. No live recording or provider run was used for
verification; installed visual usability still needs the user's review.

## Step-one observability checkpoint

See [STEP-ONE-OBSERVABILITY.md](STEP-ONE-OBSERVABILITY.md) for current monitoring,
review-gate and verification boundaries. Its quiet notification/wake behaviour and
News archiving supersede the historical News and spoken-wake checks below.

The bootstrap-free native UI harness supports `--monitoring-fixture` with `startup`,
`idle`, `active`, `waiting`, `failure`, `paused`, `unavailable` or `review` in an
isolated profile with `AITVARAS_UI_TEST_MODE=1`. Use `--open-history` and
`--expand-history-fixture` for grouped stage history, or `--open-setup
--open-background-review` for the one-time review. No live provider invocation is
needed. Cached native screenshots do not replace supervised installed-app checks.

Aitvaras is an always-on assistant with local models, OS permissions and
personal state: exactly the kind of app that degenerates into "the developer
clicks around and hopes". This document defines the layers that replace that,
and how to run each one. The design goal: **everything that can be verified
without a human ear or a TCC dialog is verified by a command.**

## Capture reliability and companion checks

See [CAPTURE-REFINEMENT.md](CAPTURE-REFINEMENT.md) for the optional source-audio
retention exception and the native local second-pass workflow. Current full suite:
386 tests in 39 suites.

Additional bootstrap-free checks (same isolated-profile and UI-test guards):

- `--capture-audio-lifecycle-check --uishot /tmp/audio-check.png`: synthetic
  source buffers, source retention, text durability, explicit deletion and discard.
- `--capture-refinement-check /tmp/synthetic-speech.aiff --uishot /tmp/asr/check.png`:
  uses already-installed pinned Qwen/Whisper weights, not live inputs. Add
  `--german-speech-fixture --two-source-fixture` to verify German and source offsets.
  Only synthetic recordings are authorized for agent-driven runs. It writes a
  report without transcript content. A network-denied sandbox run verifies offline
  operation independently of download UI.
- `--activity-style-check --uishot /tmp/style.png`: static gradient icon alpha and
  palette checks; no engines or accounts. Main fixtures support
  `--dock-placement bottomDock|sidebarFooter|minimized`.

Earlier capture checkpoint: 358 package tests in 35 suites, plus Debug and optimized
Release app builds. The following app diagnostics require both an isolated
`AITVARAS_STATE_DIR` and `AITVARAS_UI_TEST_MODE=1`; they bypass normal bootstrap.

- `--capture-lifecycle-check --uishot /tmp/capture-check.png`: simulate stalled
  OCR, final buffered speech from two sources, obsolete callbacks, failed saving
  and retry. No microphone, screen, provider or account is started.
- `--companion-ui-fixture compact|subtitles|chat --uishot /tmp/companion.png`:
  synthetic capture, independent visibility toggles, retained draft/history and
  no avatar renderer. Add `--light-fixture` for the light appearance.
- `--speech-stop-check /tmp/synthetic-speech.aiff --uishot /tmp/speech-check.png`:
  feed an explicitly supplied synthetic file through already-installed German
  Apple speech assets and verify bounded finalization. No microphone or asset
  download. The input is a diagnostic fixture, not a live-audio persistence path.
- `--avatar-efficiency-check /tmp/avatar-check.json`: count actual rendered
  frames across active, idle, hidden, occluded and sleep-state transitions.
  `scripts/check-avatar-renderer.sh` runs the same check in a minimal host with
  no engines or user state (`docs/character/dragon-runtime/README.md`).

The capture stop/save and synthetic speech checks passed in the Release build.
Cached native screenshots can misrepresent glass and layer-backed controls;
use them for structure/state checks, then review appearance in the installed app.
Do not start a live lecture, cloud call or connector solely to demonstrate the UI.

## Layer 1: package tests (`swift test`)

The core logic lives in the SwiftPM package (AitvarasKit) and tests without
Xcode:

```sh
swift test                       # full suite
swift test --filter Consolidator # one suite
AITVARAS_LIVE_TESTS=1 swift test --filter NewsFeedTests.liveDefaultTopicsReturnDiverseCataloguedResults
AITVARAS_RUN_LIVE_CLI_TESTS=1 swift test --filter CLILiveIntegrationTests
```

Conventions:

- **In-memory database per test**: `Stores(db: try AitvarasDatabase(url: nil))`
  runs the full migration chain, so schema changes are exercised on every run.
  Migration behavior itself is tested end-to-end by deleting a row from
  `grdb_migrations` and re-opening (see `migrationImportsLegacyMemoriesIntoFacts`).
- **Deterministic fakes instead of models**: `ScriptedEngine` (canned
  responses per call, `<<THROW>>` marker to simulate a dying engine) and
  `FakeEmbedder` (topic-marker vectors so "semantic" matches are assertable)
  live in `Tests/AitvarasCoreTests/TestSupport.swift`. Model *quality* is not
  unit-testable; model *plumbing* (parsing, fallbacks, idempotence, gating,
  provenance) is, and that's where the bugs live.
- **Every pipeline tests its failure path**: engine down, garbage output,
  duplicate input, bogus IDs from the model. A pipeline test that only covers
  the happy path is considered incomplete.
- MLX generation cannot run under `swift test` (Metal library only resolves
  inside app bundles). Those paths run in Layer 3's self-test instead.
- Live CLI tests are opt-in because they consume Claude/Codex subscription
  quota. They use fictional memory evidence and throwaway workspaces, verify a
  real file side effect for each delegated provider, run the full Consolidator
  parse/persist path, create and locally validate a connector manifest, and
  review a fictional routine without changing its execution—once with each
  provider.

## Layer 2: app-target build (compile verification)

The SwiftUI app compiles headlessly; run after any `App/` change:

```sh
xcodegen generate    # only after adding/removing files
xcodebuild -project Aitvaras.xcodeproj -scheme Aitvaras -configuration Debug \
    -derivedDataPath .build-xcode \
    -skipMacroValidation -skipPackagePluginValidation build
```

Both `-skip*Validation` flags are required (plugin/macro validation hangs or
fails outside interactive Xcode).

## Layer 3: isolated live profiles (`AITVARAS_STATE_DIR`)

All persistent state (database, logs, connector manifests, models) resolves
through `AitvarasPaths`. Setting `AITVARAS_STATE_DIR` relocates the entire profile,
so a live app can be exercised **without touching real memories**: by you,
or by an agent driving the app on your behalf:

```sh
export AITVARAS_STATE_DIR=/tmp/aitvaras-test     # throwaway profile
export AITVARAS_SHARE_MODELS=1                # reuse downloaded model weights
.build-xcode/Build/Products/Debug/Aitvaras.app/Contents/MacOS/Aitvaras \
    --seed-demo-state --open-news
```

- `--seed-demo-state` fills an **empty** profile with a fictional persona
  ("Alex", physics student with a homelab; see `StateFixtures`): facts in
  every state (current, superseded, quarantined), entities, open questions,
  activity history, a goal. It refuses to touch a database that already has
  facts, so it can never pollute a real profile.
- Demo seeding also disables external integrations for that process: no Mail,
  Calendar, Reminders, shared Keychain accounts, custom APIs or network tools
  are registered during bootstrap. For a safe empty profile without fixtures,
  set `AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1` explicitly.
- The real profile in `~/Library/Application Support/Aitvaras` is untouched;
  delete the temp directory afterwards and nothing remains.
- Keychain items are currently NOT namespaced per profile; connector tokens
  are shared. A plain `AITVARAS_STATE_DIR` override therefore does not disable
  integrations—also use the safe-mode variable above for agent-driven runs.
- In-bundle model runtime check: `Aitvaras --selftest` (MLX generation,
  the one thing Layer 1 can't cover). Diagnostic modes do not run the normal
  app bootstrap in parallel. During the Naomi → Aitvaras transition, shared
  model discovery can read complete weights from the legacy folder without
  moving the real profile.
- `MLXIntegrationTests` require both an Xcode-hosted test bundle and the
  explicit `AITVARAS_RUN_MLX_TESTS=1` opt-in. Downloaded weights alone never
  enable them under `swift test`, where a missing Metal library is process-fatal.
- Native-window visual QA without Screen Recording permission:
  `AITVARAS_UI_TEST_MODE=1 Aitvaras --open-news --uishot /tmp/news.png`. The
  app renders its own main window after bootstrap and exits. The seam refuses
  to run unless both the explicit test flag and `AITVARAS_STATE_DIR` are set.
  Use `--open-shortcuts` to render the learned-workflow review screen instead.
- Minimal-companion QA: with the same isolated-profile variables, use
  `--open-companion --test-companion-switch --uishot /tmp/companion.png`.
  This bypasses bootstrap entirely. It checks minimal startup without an
  avatar view, switches to Avatar and back, verifies renderer detachment,
  panel sizes and lower-right anchor preservation. The screenshot captures
  minimal startup separately: native `cacheDisplay` does not reliably flatten
  layer-backed controls after removing a Metal view from the same host.
  It never starts inference, connects accounts or requests access.

## Layer 4: smoke script (the pre-push gate)

```sh
./scripts/test-smoke.sh
```

Same as `make smoke`: the tracked-file privacy sweep
(`scripts/check-privacy.sh`), the offline Node helper contracts, Layer 1 and
Layer 2. Green smoke = safe to open a PR. CI runs the same checks on every
PR (`.github/workflows/ci.yml`); `main` only accepts green PRs.

## Layer 5: manual checklist (the irreducible human part)

These need ears, permission dialogs, or external accounts. Run after changes
to the respective subsystem, with the app installed normally:

| Area | Check |
|---|---|
| Companion modes | Setup → Companion → Minimal overlay shrinks the panel immediately. Text input, voice toggle, volume and Option–Space still work. Only the status/drag handle moves the panel, never the slider or text field. The overflow menu retains recording, language and optional focus controls. Switch back to Avatar and confirm the previous character remains selected; restart and confirm the display choice persists. Minimal mode must contain no SceneKit view. |
| Voice input | ⌥Space-hold starts listening; German + English utterance transcribed; barge-in interrupts TTS |
| TTS | Neural voice on (Setup): German reply quality; Apple fallback when sidecar stopped |
| Mail trust | Mail from a new sender appears as held in Activity and Connections → Message safety without triage/Telegram; asking chat to read it returns only a held status; trusting its exact address permits later quarantined triage/read; mail stays unread |
| Phishing boundary | An approved sender's message containing instructions to read Memory/Knowledge or open a URL cannot access those tools; event/reminder proposals appear only as confirmation cards |
| Calendar/Reminders | "erstell mir einen Termin morgen 10 Uhr" creates the event in the Aitvaras calendar; Aitvaras refuses to edit foreign events |
| Memory | "merk dir, dass …" → fact appears in Memory view with *you said* badge; correction in the editor supersedes with history |
| Cloud controls | In Models → Cloud agents, verify all four features independently offer Local, Automatic, Claude and Codex and that changing each selection immediately updates the exact data-leaving-the-Mac and tool-access disclosure. Make calls in two features and verify each disclosure group shows only its own recent history. Prompts/responses must never appear in ledger rows. Set a small monthly call limit in an isolated profile and verify the next excess call is refused. |
| Local usage | Complete one MLX and one Ollama turn. Models → On-device model usage must show token credits per engine and role; supported engines use exact counts and any fallback estimate is labelled. No prompt, response or tool content may appear in `localModelUsage`. |
| Consolidation | Under Models → Nightly memory, verify Automatic/Fixed/Off, time, wake delay, power policy and Run now apply immediately and that last successful / next eligible / waiting reason remain readable. Automatic defaults to a 04:00 boundary, waits ten minutes after a post-boundary launch/wake, catches up when a sleeping Mac returns, and runs only once for that boundary; low battery/plugged-only must defer without losing the job, with the half-hour poll as backup. Select Local, Claude, Codex or automatic without restarting, then verify Activity shows a `consolidationRun` digest (or a loud FAILED entry, never silence). Its detail identifies engine/fallback; automatic failure retries without a modal question, while discovered questions wait in Memory. Signing out or forcing invalid CLI output must use the local engine without losing episodes. |
| CLI delegation | Connections reports missing versus signed-out versus ready CLI state. Select Claude and then Codex under Models → Delegated tasks and run one confirmed throwaway task with each; each may write only in the selected workspace and must return a non-empty result. Claude permission denials must be failures, not exit-0 success. |
| Connector creation | Select Claude and then Codex under Models → Connector creation. Draft from fictional public documentation and verify the same Aitvaras policy/data disclosure applies, no credential is included, invalid output is rejected locally and the manifest still requires user review before activation. |
| Wake briefing | Sleep the Mac for more than five minutes after enabling any desired sources. Receive one known-sender and one unknown-sender test message while asleep, then wake/unlock: the companion appears once with a short count-only recap; no subject/body/URL is spoken, individual catch-up alerts do not burst, the unknown sender remains held, and Activity contains one `wakeBriefing`. A second wake signal must not repeat it. A sleep under five minutes must produce no recap. A synthetic source flood over 200 items must be disclosed as a partial catch-up. |
| News | In a fresh isolated profile, confirm the editable AI tools & workflows, International politics and Germany starter tabs appear, then add a custom topic with each importance/interval option and refresh it. Confirm every story names a catalogued publisher, available images render, original links open, SPIEGEL+ stays in the signed-in browser, Listen/Stop follows the visible article, and no News rows appear in Activity or Memory. Set the morning offer two minutes ahead: it appears once, individual refreshes remain silent, and restarting the app that day does not repeat it. Chat/voice “open my news” should select News and answer from the delimited `news.*` result. |
| Home Assistant | Connect with an installation-local base origin and a long-lived token. A wrong URL/token must remain on the setup sheet and not replace a working connection. Connections health must reflect a real `/api/` probe; repeated UI refreshes after a 401/403 must not make another request or trip HA's IP ban. Ask for a friendly entity name: Aitvaras should search first, then use the exact id; compact output must omit latitude/longitude-like attributes. Light on/off may run as reversible writes, while a non-`light.*` id must fail before any request. Disconnect and confirm both local URL state and the Keychain token are removed. |
| Learned shortcuts | Repeat one exact reversible command three times (for example, an enabled Home Assistant `light.*` off command). Confirm **Shortcuts** shows trigger → exact tool/arguments, then repeat it: the companion must show “Shortcut · no AI”, the model must not enter thinking state, and Activity must show `shortcutTaken → toolExecuted`. Similar but non-identical wording must use the normal agent. Pause the shortcut and verify it no longer matches. Review/edit its phrase and JSON arguments, then resume. |
| Suggested automation | Repeat the same fixed reversible workflow at a similar time on the required test dates or seed an isolated fixture. Confirm the schedule is labelled **Needs approval** and does not run. Activate it from the visible workflow card, verify one run in its ten-minute window and no duplicate on a second scheduler pass. Dismiss another proposal and verify nightly learning does not recreate it. |
| Cloud routine review | In an isolated profile, enable Claude and then Codex for Shortcut & automation review. Create a fictional candidate and verify only its title/explanation gain a reviewed badge; phrase, schedule, tools, arguments, risk and approval state remain byte-for-byte unchanged. Local-only must create the same executable candidate without any cloud call. |
| Permissions | Fresh macOS user: Setup checklist flows through mic/speech/calendar/reminders/mail grants in order |

## Unified project-chat shell (M2)

The Chat tab uses `ChatModel` and the application-owned `AgentSessionManager`
for project chats. Opening or switching chats/providers sends no message;
status checks and the authenticated backend model list never prompt or sign in.
Send persists the exact wire input and bounded catch-up before delivery. Its
acceptance callback clears the original composer immediately after the journal and
transcript are saved, before provider startup; auth failure never restores that
text into the draft. Sign-in retries use the saved entry (including attachments).
An unavailable native-history reader retains the canonical transcript without
blocking Send; passive read failures do not create an inline alarm. Malformed or
conflicting history still blocks a send that cannot safely reconcile it.
`AgentSessionManagerTests` covers acceptance, auth failure/retry, preflight
rejection/sidebar failure, and missing or unavailable native history.
`ChatSettingsTests` sends after provider and chat switches using a cached catalog.
Restart restores the transcript and provider choice; drafts remain per chat for the app lifetime. Model, effort
and mode are saved when chosen; restored models and efforts are validated against
the provider catalog on each selection and before Send. Existing unassigned chat, voice, shortcuts,
capture targets and memory archiving keep their legacy paths. Legacy project
history migration is still M5 work.

For provider E2E, always set `AITVARAS_STATE_DIR` to a disposable profile.
`AITVARAS_AGENT_TEST_PROVIDERS=real` enables the new real backends even with
`AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1` or `AITVARAS_UI_TEST_MODE=1`.
Personal connectors remain disabled by the provider-test configuration itself.
`AITVARAS_FAKE_CLAUDE` and `AITVARAS_FAKE_CODEX` may instead name absolute fake
executable paths. A fake-only configuration enables only the named providers;
it never falls back to a real provider. These overrides require isolation and
do not relax any legacy client guard. Normal launches need none of these flags.

Host verification: generate/build the app, create a project chat, send through
Claude, switch to Codex without sending, then Send and inspect the single
catch-up disclosure. Switch to Local and reply, stop a streaming turn, revisit
another chat to check draft retention, quit/reopen to check transcript/provider
restoration, and verify imported history remains reachable.
Check both appearance modes at 800×500, a long Markdown/code reply, collapsed
thinking/tools, Return to send and Shift-Return for a newline. Scroll upward
during streaming: new text must not pull the transcript back to the bottom.
Projects list their chats directly, with primary chats pinned first and scoped
running/needs-you/failed dots. Rename, pin, archive and restore from row menus.
Project chats expose no context inspector, boundary review or setup flow.
Review section 4 of `UNIFIED-CHAT-PLAN.md` in empty, streaming, approval, failed and
signed-out states, in light/dark and at 800×500. The composer card and transcript
must share a centred column; assistant text has no bubble. Check visible paperclip,
worktree and Send/Stop symbols, ring-only gauges with tooltips, stationary control
slots and keyboard access to the horizontal strip at minimum width. Inline errors
and Sign in must fit above the window edge. Chat's dock must remain absent on an
idle fresh profile and after a manual provider failure; start automatic work to
check that the visible dock consumes height without covering the composer. Other
tabs retain their dock and attention presentation.

Settings → Providers has one row per provider: status icon, known usage gauge
and Sign in (Local needs no login). Model choices come from the backend; effort
is hidden for models without it, and Local omits effort and mode. Unknown gauges
are absent. In a signed-out temporary profile, Send must show one inline sign-in
action. Verify the browser URL, Cancel, a five-minute timeout and successful
completion followed by one automatic send. The maintainer must complete the
real browser login once for each provider. Accepted text stays in the transcript
through cancellation and restart; opening Chat never initiates login. Only a journal entry still
`prepared`, never `deliveryUnknown` or `acknowledged`, is eligible for retry.
A single durable intent per profile is bounded to 64 KiB and five minutes;
changing chat/provider, settings or the draft invalidates it. Native profile,
session and any opaque account ID exposed by the CLI must still match. An
existing native session without an exposed account identity requires an explicit
Send after login; its account cannot be proven unchanged.
`ChatSettingsTests` and `ProviderSignInTests` cover these policies against an
in-memory store, including cancellation, timeout, drift, failed persistence and
duplicate completion. The sandbox package checks do not compile the app or verify real authentication, Liquid Glass or accessibility.

Thinking and tool rows (M3.1) stay collapsed to one line by default. Expanding a
row shows a scrollable detail area capped at 240 points. Each thinking item,
tool input, partial argument preview and output retains at most 32 KiB of UTF-8
text, with an explicit truncation marker. Streaming output accumulates per
native item; final output replaces its preview. Complete thinking replaces its
streamed text. `TranscriptReducerTests` replays both providers and checks
interleaving, multi-block replies, stable identities and bounds.

Native permission requests (M3.2) create one inline Allow/Deny card each and
mark the originating chat with its needs-you dot. The command or file is
visible without expanding JSON. Home attention and Chat Suggestions project
the same live pending requests; either surface answers through the coordinator
and cannot execute the action independently. Hooks alone never create cards.
Permission, plan and question cards have no automatic timeout. They stay pending
until answered, cancelled or resolved by the provider (including turn end),
denied by Stop, or cleared on exit or restart. Raw provider requests are not
persisted as executable Suggestions; Activity keeps scoped provenance without
raw arguments. `AgentApprovalTests`
covers cross-chat replies, concurrent clicks, cancellation through fake
executables, waiting past the former accelerated expiry deadline, Stop, rejected
replies, restart and failed durable audit writes.

Host verification for M3.1/M3.2: with each real provider in an isolated profile,
expand thinking and two interleaved tools while output streams, then collapse
and scroll upward. Check stable rows, bounded details, keyboard expansion and
Allow/Deny at minimum window size in light/dark appearances. Request a harmless
file edit and command; Deny must prevent execution, Allow must execute once,
and the pending card/dot must clear from transcript, Suggestions and Home.
Leave a permission, plan or question card unanswered for more than ten minutes;
it must remain actionable, and Stop must still deny it and record the ending.
Navigate to another running chat while answering; verify only the originating
request changes. Check Activity provenance and expiry on provider exit/restart.
App compilation, real CLI behavior and these visual checks require the host.

Plan and question cards (M3.3/M3.4) use the same scoped coordinator. Plans
render Markdown with Approve and Keep planning. Claude's recorded
`PostToolUse` for the approved `ExitPlanMode` reports `permission_mode: default`;
only that acknowledgement changes the saved mode to Ask. Codex's completed
native `plan` item creates a review card after its read-only turn; approval
starts an implementation turn with Ask permissions, and `turn/start` must
acknowledge it before the saved mode changes. Informational `turn/plan/updated`
and ordinary assistant replies never authorize execution. The available Codex
schema has no collaboration-mode field on `turn/start`; host verification must
check that the installed CLI actually produces a native plan item in this path.
Keep planning preserves Plan mode; Stop interrupts a pending review.

Question cards show option buttons and a request-local draft. Every question
requires an answer before Submit. Claude supports multiple selections and free
text; Codex allows free text for `isOther` or a question without options, and
preserves `isBlocking`. Secret free text uses a secure field. Replies are
validated again at the coordinator and backend; malformed questions, unknown
IDs, empty required answers, stale cards and duplicate replies are rejected.
Cancel closes the native request with an unsupported response because neither
protocol defines a question-denial payload.

`AgentPlanTests` covers the recorded Claude acknowledgement and both fake
executables for approve/reject, failed transitions, Stop and stale plans.
`AgentQuestionTests` covers draft validation, schema flags, multiple questions,
both reply formats, cancellation and late answers. On the host, build the app
and check both cards with real providers: keyboard selection/Submit/Cancel,
free text and multiple selections, minimum size, light/dark, chat switching,
and a failed approval. Confirm no execution before approval and one continuation
afterwards, with the composer mode and saved settings following acknowledgement.

Follow-ups and Stop (M3.5/M3.6): Send and Stop remain adjacent during a turn;
Return and Command-Return submit follow-ups. Claude writes them to native stdin
in order and shows Queued on each pending message. Codex uses `turn/steer` with
`expectedTurnId` and a local message ID; output stays with the original active
turn. Every input has its own delivery barrier and journal row linked to the
active input. Duplicate IDs, wrong providers and busy plan reviews cannot replace
that turn. A rejection before delivery leaves its active approval card intact.

Stop denies pending approval cards and waits at most 1.4 seconds for the native
turn end.
If that does not arrive, transport disposal has a further 300 ms grace. Partial
output and native session IDs survive, queued inputs become interrupted, and the
next explicit Send continues the same native session without replaying them.
Codex shares one app-server: forced transport disposal interrupts all its runs;
an acknowledged Stop affects only its own chat. `AgentFollowupTests`,
`AgentInterruptTests` and `AgentTurnStoreTests` cover ordering, duplicate/scoped
inputs, busy providers, failed barriers, fast completion, stale steer responses,
Stop before delivery/during output/approval, absent acknowledgements/results,
queued cancellation and continuation through real process pipes.

Host verification: on both real providers, send two follow-ups during a long
turn and verify native queue/steer behavior, delivery labels and output ownership.
Stop during output and while an approval is pending; measure under two seconds,
then Send and verify the same native session. Repeat with two background chats,
a queued Claude input, and a provider that stops responding. Check Send/Stop and
keyboard shortcuts at minimum size in light/dark, queued labels after restart,
and that interrupted inputs are never resent without another explicit Send.

Attachments and completions (M3.7/M3.8): `AgentAttachmentTests` covers immutable
snapshots, size/count/type limits, cancellation before delivery, native text/image
encoding on initial and follow-up sends, failed snapshot saves, exact retry and
no attachment transfer through context handover. `AgentComposerInputTests` covers
absent/malformed catalogs, duplicate/disabled skills, project search boundaries,
filename quoting and explicit selection through fake CLI pipes. The checked-in
Claude initialize recordings omit commands; a missing catalog must stay unavailable.

Host verification: build the app and use an isolated profile. Drag and paste files
and images, attach through the paperclip, remove chips, cancel the file picker,
send an image alone, and reject oversized/unsupported files. Change a source file
after selection and verify the original bytes arrive on both real providers,
including follow-ups and a sign-in retry. Switch chat/provider before imports
finish and verify the originating composer retains ownership. Type `@` and `/`,
search, use arrows/Return/Escape and Tab, and verify one popover level, filename
escaping, installed command/skill lists and native invocation. Confirm native MCP
and project instructions remain available. Review minimum size, light/dark,
accessibility identifiers and streaming layout. These checks require the host;
package tests do not compile App views or establish live CLI conformance.

Git workspaces and changes (M3.9–M3.11): `AgentWorktreeTests`,
`AgentChangesTests`, `AgentGitActionTests` and `AgentGitProviderMappingTests` use
disposable repositories and fake executables to cover durable creation, failed
preflight/collisions, duplicate creation, foreign ownership, multi-folder mapping,
provider resume arguments, staged/untracked/deleted/renamed files, unusual names,
binary/large previews, stale bytes/index state, native hook failure, policy/audit
failure and cancellation during a commit. Commit/discard use literal pathspecs
and leave unrelated checkouts intact. Failed hooks may leave reviewed files
staged; interrupted operations are reported, never automatically retried.

Host verification: build the App target, then in an isolated profile create a
project on a disposable committed git repository. Confirm worktree defaults off,
is offered only for git, and both providers resume the recorded cwd after restart.
Test multiple folders and failed creation without any fallback edits. Make real
edits and verify the inspector appears only with changes, file selection, colored
unified diffs, keyboard navigation and narrow-window layout in light/dark. Commit
with a user message and verify the intended files and normal hooks. Cancel and
accept the single native Discard confirmation in an owned worktree; confirm the
original checkout, foreign worktrees, ignored files, branch and worktree survive.
Confirm Discard is disabled on ordinary checkouts. Edit externally between review
and click, fail a hook and interrupt git; verify a single inline error and safe
refresh. These checks need the host and do not follow from package tests alone.

Background chat lifecycle (M3.12): `AgentLifecycleTests` replays the checked-in
Claude/Codex interrupt recordings and uses fake executables for parallel running
chats, scoped approval/status, subscriber detach/reattach, active archive,
restore/continuation, invalid IDs and metadata, failed writes, activity ordering
and automatic-expiry protection. A disk-backed database is reopened after quit;
startup launches no provider, keeps partial output and native identity, and only
the next explicit Send resumes. Crash recovery covers prepared, uncertain and
acknowledged inputs without replay. Queued Claude inputs retain interrupted
labels durably.

Host verification: build the App target and use an isolated profile. On both
real providers, run two chats, switch between them, close/reopen the main window
and verify output and approval dots continue independently. Rename an active
chat; archive one while streaming and one awaiting approval, then answer or
Stop from Archived. Confirm the composer blocks Send until Restore. Quit during
streaming and with a queued follow-up, relaunch and verify interrupted status,
partial output, retained title/archive state and same-session continuation on
the next Send without replay. Cancel quit through a failed capture save and
confirm Send works again. Check keyboard and VoiceOver access to rename,
archive/restore and status at minimum window size in light/dark; confirm no
streaming layout jumps. Native rename/archive propagation is not claimed.

Native history discovery (M5.1/M5.2): `AgentNativeHistoryTests` exercises
Claude JSONL with recorded message content in synthetic persisted envelopes,
version labels, unknown records/blocks, pagination, corrupt/truncated files,
missing directories and wrong profiles. Fake Codex executables assert read-only
`thread/list`/`thread/read` requests, native archive filters and cursors, unknown
items, unavailable executables, malformed results and unsupported partial
history. `AgentNativeIdentityTests` covers repeated discovery, provider/profile/
host collisions, symlink aliases, nested and ambiguous roots, folder boundaries,
worktree ownership, atomic failure and preservation of existing chats/settings
and legacy evidence. Manager discovery must read every page before mapping and
must never start a run.

Host verification: build the app, use an isolated app profile and disposable
native sessions, and verify that sessions from every registered project folder
appear once without a link/import step. Check aliases, overlapping roots and
owned worktrees, restart discovery, read a preview and Send on both providers;
confirm native identity and cwd remain the same. Verify the sidebar refresh and
inline preview Retry with keyboard and VoiceOver in light/dark and at minimum
window size. Compare existing saved evidence before/after discovery on a private
DB copy. Real Claude persisted-file envelopes and installed Codex history
responses require host conformance; the stream recordings alone do not prove
those on-disk envelopes. Full external-history reconciliation belongs to M5.3.

## What an agent session should do

For Claude Code (or any agent) working on this repo: Layers 1–2 after every
change set; Layer 3 with a temp profile when behavior needs a live app; never
launch the app against the default profile; never store test tokens in the
Keychain. The demo persona is fictional on purpose; assertions in agent-run
live tests should reference it (Alex/Example University/homelab), which doubles as a
guard that the real profile was not loaded.

## Unified chat legacy compatibility (M5.5)

`UnifiedChatMigrationTests` reconstructs a populated pre-unified v27 database,
opens it through the current migrations twice and compares legacy rows, IDs,
revisions, conversation ownership and capture targets. It also covers saved reads
with a missing separate provider profile/executable, imports beyond one page,
read-only projections, uncertain outcomes, archive reads and context/memory scope
guards. No test opens credentials or migrates provider profiles.

Host gate: migrate a local private DB copy, check owned and linked text plus
collapsed imported sources in Chat, and inspect saved-source details. Check both
appearances and keyboard expansion at minimum window size. Confirm unavailable
old provider profiles do not block saved reads. Keep the copy and screenshots
local; package tests do not compile the App target or verify this visual gate.


## Companion, Activity and capture compatibility (M6.1–M6.2)

`AgentSessionManagerTests` drives fake CLI processes to verify Activity Stop by
input identity with two chats running, including a stale click after continuation.
`AgentTurnStoreTests` covers atomic Activity/journal failure, recovery and the
single explicit resend identity. `AgentApprovalTests` checks that provider audits
appear under that input's Activity row and Stop expires its Suggestions and cards.
`CommandRoutineTests` checks both typed and voice shortcuts with provenance.

`WorkspaceScopeTests` runs managed Local through AgentLoop with fake inference,
including a fabricated tool request. It checks that captures and shared facts
never reach the prompt, tools never execute, capture targets survive rename and
archive, and global archiving/recovery never learns from the managed chat.
`WorkspacePolicyTests` and `UnifiedChatMigrationTests` retain the existing
capture-target, scope-failure and upgrade checks. `ConsolidatorTests` excludes
project git and current/legacy provider audits from nightly personal-memory evidence.

Host checks in an isolated profile (package tests do not compile App):

- Open a project chat in the companion with the main window closed. Check its
  shared transcript, draft, provider controls, approvals and Stop. Collapse and
  reopen while streaming; switch chats and confirm only the selected chat drives
  the thinking animation. Review narrow layout, keyboard focus and both appearances.
- Run two provider chats, switch to another chat, and Stop one from Activity.
  The other must keep running. Stop a managed Local turn from Activity too.
- In Unassigned, check typed and voice shortcuts, microphone/typed speech,
  barge-in and saved voice history. Project voice remains unavailable; a hotkey
  or typed speech action must not send project text to global voice history.
  Local replies, voice and capture second-pass inference must respect contention.
- Open Chat Details → Captures, reopen a saved capture, and use its Open Chat
  control while another provider chat runs. Include an archived target. Opening
  must retain target IDs and must not attach or send the transcript.
- Check capture checkpoint/final-save retry and failed quit cancellation. After
  cancelling quit, send new input explicitly; old input and approvals must not
  replay. Run the existing capture synthetic checks and private DB-copy gate.

Legacy adapters and their diagnostic views remain until the M6.3 UI gate passes.

## Debug in-process chat self-drive

Set `AITVARAS_SELF_DRIVE` to a scenario JSON file and
`AITVARAS_SELF_DRIVE_OUTPUT` to a local artifact directory. Also set
`AITVARAS_STATE_DIR` to a disposable profile and
`AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1`; missing isolation refuses startup.
Launch the Debug executable in the background without `open` or an activation
request. Release builds exclude the driver and helpers. Self-drive bypasses the
normal scene, companion and hotkeys, prohibits application activation and hosts
MainWindow in a nonactivating panel at alpha zero with mouse events ignored.

**Host gate first:** run `UITests/self-drive/probe.json` without VoiceOver or
Accessibility, Automation or Screen Recording grants. Inspect its results and
trees for identifier discovery, a successful press, and a typed composer value
observed by the text wait. Check `probe-composer.png` for rendered content.
Independently watch another app retain keyboard focus and the pointer stay still
through launch and termination; no permission or password prompt may appear.
The driver sets `AXEnhancedUserInterface` on its own application object, which makes
SwiftUI build its accessibility tree inside this process; it reads SwiftUI's nodes by
selector because they do not formally adopt the protocol. Screenshots draw the window
background themselves. Package tests do not prove these runtime assumptions. A failed probe blocks
relying on self-drive coverage; preserve the artifacts to fix the adapter.

The format is `{"steps":[{"action":"press","identifier":"chat.new"}]}`.
Actions: `press` by identifier; `type` appends `text` to the composer;
`waitFor` takes exactly one `identifier` or case-insensitive visible `text`,
a `timeout` in seconds, optional `absent:true`, `within` subtree identifier and
`caseSensitive:true`; `screenshot` and `dumpTree`
take a safe artifact `name`. Every step accepts an optional settling `delay`.
Results contain one index/action/status/reason entry per step and checkpoint
atomically after each step; failures continue. Press uses in-process accessibility
then window-local mouse events; a later wait must verify its effect. Typing goes through the
field's own editor, because the accessibility setter skips the SwiftUI binding. PNGs cache
the content view, and dumps walk only the window's accessibility children.
Setup/output errors write `startup-error.txt` when possible. Missing results,
startup errors or failed steps fail a run regardless of process exit status.
Keep artifacts local: they can contain chat content.

`UITests/self-drive/golden-path.json` uses transcript-scoped reply checks and
case-sensitive catch-up checks. Prompts spell the expected word backwards or refer
to the previous answer, so composer text cannot satisfy them.
`AITVARAS_AGENT_TEST_PROVIDERS=real` enables real CLI subscription turns with
personal integrations disabled. Set debug-only `AITVARAS_SELF_DRIVE_PROJECT` to an
existing disposable folder: SelfDriver registers the project before the scenario,
without creating chats. Set optional debug-only `AITVARAS_SELF_DRIVE_CODEX_MODEL`
to a cheap model ID advertised by the installed CLI; only new Codex sessions use
that choice. Codex steps run before the final Claude steps. Every Send checks
that its text is absent within `chat.composer.input`; the shell step waits for its
Allow card and then for the successful completed tool row in the transcript.
The scenario sends six Codex chats plus a final Claude chat, checks one-click switching,
Show more and a real waiting-approval sidebar icon plus the Chat badge. `$project`
and `$chat1`/`$chat2` resolve IDs observed during the scenario. Setup uses the
in-window `gearshape` button and the visible AI providers card.

`picker-probe.json` separately dumps the new composer's tree and attempts the
project menu. Native menu presses report unsupported failures; they are excluded
from the golden path rather than presented as successful interaction. The host
must inspect the provider segments' identifiers and press effects and the project
menu's real accessibility subtree. Use XCUITest for native menu selection.
The original XCUITest stays as the final check for native
menus, file panels, drag and drop, real focus and system-rendered screenshots.
Self-drive covers in-process chat controls, bindings, turns, approvals and Stop
only after the host gate passes. The supervisor must regenerate/build the App
on the host; the recursive App source entry includes the new file without a
project configuration change.
