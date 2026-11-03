# Step one: understandable, observable and quiet

This is the implementation checkpoint for Phase 1 of [the work-hub plan](WORK-HUB-PLAN.md).
It does not add a server, mobile client, new transcription backend or public release.

## Implemented foundation

- Durable `ActivityRun` records with typed lifecycle states, parent relationships,
  provider/location/data disclosures and separately acknowledged problems.
- Durable stage transitions, existing causal `ActivityEvent` evidence and uncapped,
  filtered history pagination. Older events remain legacy evidence, not invented runs.
- Service status and daily check summaries; unchanged polling does not create runs.
- Event-driven UI updates, bounded progress writes, and no model-based telemetry.
- Restart reconciliation marks unfinished work interrupted or outcome-unknown. It
  does not replay uncertain external actions.
- Sticky monitoring failures suspend new automatic work without throwing through
  an active recording. Provider results are not retried because accounting failed.

Migrations v13–v16 are additive. No conversations, memory or indexed source data
is deleted by these migrations.

## Behaviour and interface

- Home, Chat, Capture, Library, History and Settings; last-section restoration.
- Global activity bar, current-work panel, menu-bar status and minimal-companion
  indicator. No status carousel or periodic animation timer.
- Home prioritises attention, current work, automatic services and results before
  goals. Detailed stages, outputs and technical disclosures are available on demand.
- One-time, default-off automatic-work review. Existing connection/provider settings
  remain saved. Manual chat/capture and ordinary conversation saving remain usable.
- Global pause closes automatic entry paths and stops observation. Cancellation is
  requested until acknowledged; already-started work remains visible.
- Review includes saved delivery backlog and bounded archive recovery. Focus sessions
  and held speech do not resume on launch or wake.
- News implementation/data are retained but registration, navigation, refresh,
  morning offers and narration entry points are archived.
- Model loading is demand-driven. Connection health checks are explicit, not a
  repeating UI probe. Library distinguishes configured, indexed and unavailable sources.
- Both keyword and vector retrieval enforce registered, available source boundaries.
- Routine updates stay in the app. Background failures are persistent, deduplicated
  attention items. System previews are generic; ordinary startup does not request
  notification permission.

## Instrumented boundaries

Startup/model preparation; chat/voice; tools and approval waits; capture teardown,
durable saving and summaries; manual/changed-file indexing and embedding work;
conversation archiving and consolidation; connector checks and intake; notification
delivery attempts; routines/focus; cloud CLI calls; model/voice installation.

Watchers are services, not permanently running jobs. Capture completion distinguishes
saved transcripts with pending summaries from fully completed captures. Run details
link to saved captures or conversations rather than duplicating their contents.

## Verification and release boundary

Current checkpoint: macOS Debug and optimized Release builds succeeded; 342 package tests in 32 suites
passed. The watcher test also passed separately after one full test-runner stall.
Synthetic main-window, history/review/detail/activity-panel and minimal-companion
checks ran without bootstrapping accounts or models. The minimal check verified
that no avatar renderer was mounted.

The user approved installation and restart. The Release app was installed with a
local rollback backup of the previous app and SQLite database. Normal-profile
startup completed successfully after migration to v16. Conversation, message,
memory, source-index and capture counts were unchanged; database integrity passed.
No automatic service was enabled, no operation remained active, and model/cloud
usage and delivery queue records were unchanged. One settled idle sample showed
zero CPU usage; this is not a battery benchmark. Human visual/interaction sign-off
on the installed interface remains the final acceptance check.

Package tests use isolated databases, synthetic connectors/providers and temporary
source folders. Coverage includes migration preservation, history beyond 300 records,
source quarantine in both recall paths, policy gates, cancellation, uncertain external
outcomes, provider/accounting no-retry behaviour, stage ordering and error deduplication.

The app includes a bootstrap-free `--monitoring-fixture` screenshot harness, guarded
by isolated state plus `AITVARAS_UI_TEST_MODE=1`. Scenarios: startup, idle, concurrent
work, approval wait, failure, paused services, unavailable monitoring and first review.
It initializes no engines, accounts, microphone or user database.

Before installation is considered verified, perform a supervised check of the real
main window, menu item, last-section restoration, pause/review controls and minimal
companion. Do not enable mail/cloud/external deliveries merely to demonstrate the UI.
Native vibrancy/selection controls may not flatten faithfully in in-process cached
screenshots; their appearance still needs the installed-app check.

No public repository or startup-at-login change is part of this checkpoint.
Completed changes are committed and pushed only to the private development
remote under the standing delivery rule in AGENTS.md. Installation requires
coordinating with the user so capture or voice work is not interrupted unexpectedly.
