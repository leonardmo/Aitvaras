# Aitvaras: private work hub, durable context and distributed execution

**Phase 3 chat execution is superseded by
[UNIFIED-CHAT-PLAN.md](UNIFIED-CHAT-PLAN.md) and D31/D32.** Use that plan's
current-status section for the implemented direct CLI UI and still-open gates;
the adapter approach here is historical. Other product phases remain plans.

Consolidated plan — 2026-10-19. **Planning only; not an implementation or runtime-verification claim.**

Implementation detail and subsequent accepted refinements are tracked in
[NEXT-WORKSPACE-PLAN.md](NEXT-WORKSPACE-PLAN.md): structured projects/primary chats,
native coexistence, durable archived knowledge, standard RAG components and the
checkpoint delivery sequence. That document identifies which slice is built.

This is the detailed product and delivery plan linked by `ROADMAP.md`. It
supersedes the delivery priorities in `MASTERPLAN.md`, `FUTURE.md` and
`MOBILE-COMPANION.md`, while preserving their historical rationale. Existing
implementation decisions remain in force until an implementation explicitly
revises them. No deployment, migration, provider use or public publication is
authorized merely by an item appearing here.

## 1. Product purpose

Aitvaras is the durable workspace above AI harnesses and individual projects:

- Capture lectures, meetings and useful source material into the right files.
- Preserve work history, decisions, artifacts, unfinished tasks and provenance.
- Supply relevant, permission-scoped context to the next Claude, Codex or local
  session, without making the user explain the project again.
- Show what matters next, what is running, what finished and what needs help.
- Schedule and execute work on explicitly permitted devices, including an
  always-on host when the Mac is offline.
- Provide access through the Mac app and later an installable browser dashboard.

The aim is not to out-reason frontier models with a local chatbot, reproduce
every provider UI, or turn every event into a personal-memory fact. Frontier
models provide difficult reasoning. Ordinary software provides reliable
coordination. Local models provide private, offline and bounded processing.

Keep the existing study dashboard and study-file workflow. They remain the
specialist study interface and authoritative file organization; Aitvaras adds
execution management, context and links above them, not a competing dashboard.

### Non-negotiable boundaries

1. Normal Claude/Codex project use remains possible outside Aitvaras.
2. Existing subscriptions first; no silent paid API or provider fallback.
3. Local-only data never becomes cloud-eligible because it was summarized,
   embedded, copied into a task, or retrieved by another tool.
4. Capture, observation and mail access are explicit, scoped and stoppable.
5. The Mac remains independently useful if the coordinator is unavailable.
6. No automatic project-wide file synchronization, public changes, or external
   actions simply because an agent proposed them.
7. Prefer a small working vertical slice, then user review, over a large rewrite.

## 2. Delivery order

| Phase | User-visible result | Gate before advancing |
| --- | --- | --- |
| 1. Simplify and establish trust | A smaller, understandable Mac app | No mystery background work, data sources or warning icons |
| 2A. Reliable transcription | A real lecture/meeting produces recoverable Markdown in the chosen folder | Real capture and recovery tests, including unplugged use |
| 2B. Visual evidence | Optional screenshots, OCR and local visual descriptions aligned with audio | Useful visual context without excessive continuous compute |
| 3. Projects, history and frontier sessions | Continue work across Codex/Claude with a shared evidence-backed knowledge layer | Native workflow compatibility and privacy-scoped recall verified |
| 4. Distributed tasks and schedules | Mac and always-on workers execute managed tasks independently | Offline, restart, retry and concurrent-write tests pass |
| 5. Installable dashboard | Phone access to approved history, tasks, approvals and results | Mac-offline access works without pretending local files are online |
| 6. Private assistance and optional mobile capture | Focus/mail pilots, then an optional native Android companion | Measured usefulness and explicit privacy/energy budgets |

Introduce stable IDs, provenance, privacy fields and export/recovery contracts in
Phase 1. Do not postpone these until the knowledge phase, but do not build a
distributed database or full RAG redesign before urgent transcription ships.
Prototype the provider lifecycle in Phase 3 before investing in the full server
or dashboard. Phase 4 includes a minimal status/approval interface; polished
mobile UX follows in Phase 5 rather than blocking independent execution.

## 3. The history and knowledge contract

### Preserve evidence, not just summaries

Use distinct layers with links between them:

1. **Work ledger:** projects, tasks, provider sessions, execution attempts,
   user-visible messages, actions, approvals, decisions, timestamps, outcome
   evidence, usage and artifact references. This is the durable record.
2. **Source library:** authorized transcripts, documents, selected file versions
   and imported conversation material. Preserve original content where authorized,
   or clearly record that only a reference/summary is available.
3. **Derived knowledge:** cited summaries, accepted decisions, current project
   checkpoints, open questions, and reviewable personal facts. Separate proposals,
   observations and assertions; retain corrections and supersession history.
4. **Retrieval indexes:** lexical and vector indexes built from eligible sources.
   These are disposable and rebuildable; an embedding is not the only copy.

"Keep track of everything" means a durable record of authorized work conducted
through Aitvaras and supported, explicitly connected harnesses. It does not mean
secretly observing every app, collecting credentials/hidden reasoning, claiming
access to unsupported histories, or retaining raw recordings forever. Show
connector coverage, last import and failures so missing history is not invisible.

Do not rely on summaries alone: a later question may need a detail omitted from
them. Stable source/event IDs and artifact hashes support deduplication, recovery
and citations. Backups and restore tests are part of continuity, not optional
polish. Keep secrets out of records, prompts, analytics and ordinary logs.

### Retrieval must be scoped before searching

For each prompt:

1. Resolve the task/project, current user request, execution permissions and
   destination provider/device.
2. Restrict eligible sources by project, purpose, privacy and trust policy before
   lexical/vector retrieval. Apply the same policy to tool reads and artifacts.
3. Combine current structured state with hybrid search over eligible evidence;
   use temporal validity, source quality and optional local reranking.
4. Build a bounded context packet with objective, constraints, decisions,
   progress, relevant evidence, uncertainties and next action.
5. Record the included source IDs/versions and show a readable "Context used"
   view. Allow excluding sources or disabling shared recall for a session.

Default to the current project. Cross-project recall is an explicit scope, not a
global search of personal data. A project handover is not the model's hidden
reasoning or a transferable live process. Important tasks carry a concise
checkpoint even when retrieval is available; semantic search alone is not a
guarantee that every critical constraint will be found.

Personal facts remain distinct from work history. A temporary deadline, lecture
claim or generated hypothesis must not automatically become a lifelong fact
about the user. Generated text and imported mail/web content remain untrusted
evidence, not instructions or authority to execute tools.

### Retention, privacy and control

- Attach provenance, allowed execution devices, cloud-inference permission and
  synchronization scope to source records and their derivatives. Treat titles,
  summaries and embeddings as potentially sensitive too.
- Distinguish local device, private server, synchronized user devices and external
  model provider. A private server is still a separate trust boundary.
- Local-only captures/observation/mail are excluded from frontier context,
  unattended cloud consolidation and cloud-readable tool/filesystem paths.
- Raw focus samples and optional focus screenshots are transient by default.
  Durable work history does not imply permanent surveillance history.
- Keep raw capture audio locally for seven days by default, independently from
  transcript retention. Do not put temporary audio in automatically synced study
  folders. Referenced capture images follow the chosen capture/project policy.
- Offer searchable source history, export, correction, archive and deletion.
  Deletion invalidates derived summaries, context caches and indexes; document
  backup expiry and that already-sent provider requests cannot be recalled.
- Preview outbound context and destination. Existing explicit unattended grants
  must be narrow, inspectable and revocable; no new broad grants during migration.

## 4. Phase 1 — simplify the existing app and establish trust

Keep a small primary navigation: **Today, Capture, Projects/Chats, Library**.
Only surface functioning sections; do not add empty destination screens. Put
connections, permissions, provider setup and diagnostic detail in Settings.

### Work

- Archive News from normal navigation and disable its automatic refresh/offers.
  Preserve its code/data for possible later revival; do not delete user data.
- Keep the minimal companion and avatar opt-out. Pause further avatar expansion;
  no 3D rendering when disabled/hidden and no unnecessary model/TTS prewarming.
- Move experimental curiosity, broad situational awareness, optional homelab and
  similar features out of the core path. Existing enabled workflows require an
  explicit migration decision, not silent removal.
- Make setup goal-based: capture first; frontier connection when wanted; private
  automation only when enabled. Request permissions at the point of use.
- Separate model readiness, provider sign-in, memory-consolidation errors,
  source health and capture status. Each warning says what is affected and how
  to fix it; a background failure must not look like a broken chat model.
- Reconcile the RAG source registry and index. Quarantine unregistered/missing
  sources from automatic recall pending review; show stale/changed sources and
  support controlled reindex. Do not silently reauthorize legacy indexed files.
- Inspect memory with provenance/review controls. Propose cleanup rather than
  wiping it or assuming all existing facts are junk.
- Establish versioned project/source/capture IDs and privacy metadata compatible
  with later work/session records. Reuse the existing store where appropriate.
- Add an optional lightweight menu-bar presence and start-at-login control.
  Closing a window may leave explicitly enabled services running; Quit really
  stops monitoring. No root daemon or always-loaded large chat model.
- Planned follow-up: change the dragon menu-bar icon to an accent colour while
  work is active, returning to the monochrome template when idle. Derive this
  from the shared activity state, not merely from enabled background services.
  Keep recording/listening explicit in the status menu; colour is an additional
  cue, not the only status explanation. Maintain contrast in light/dark menu bars
  and use event-driven updates without blinking, animation or extra polling.
  This indicator change is planned only, not implemented.

### Acceptance

The user can tell what is running, what it can read, why something is waiting,
and what will leave the device. News is absent from the main workflow. Hidden
avatar/disabled features cause no periodic inference or rendering. Existing
history is preserved, and the app is useful without completing every setup item.

## 5. Phase 2 — transcription first

### 2A: minimum dependable capture release

Do not wait for server coordination, a complete knowledge system or advanced
vision. Support lectures, meetings, presentations and general capture sessions.

- Input modes: **microphone only**, system audio only, system + microphone,
  and optional screen-only capture. Allow device selection and a visible audio
  level/health check. Do not label microphone audio as a specific speaker.
- Optional, local speaker diarization can later assign anonymous speaker IDs
  within each source (including multiple room or online speakers). Keep source
  and speaker identity separate, mark uncertain/overlapping speech, and make the
  extra processing explicitly opt-in. The current live pipeline separates audio
  sources but does not perform diarization or retain raw audio for later analysis.
- For in-person capture, do not require screen permission. Online capture should
  scope system/window audio deliberately and avoid capturing Aitvaras itself.
- Explicit start/consent, pause, stop and clear user-visible recording state.
  A discreet compact UI is appropriate; hiding recording from participants or
  bypassing system privacy indicators is not.
- Show partial/final transcript preview, elapsed time, current input and dropped
  audio/error status. Use media timestamps, not callback-arrival timestamps.
- Persist segmented local audio and transcript checkpoints with bounded queues;
  drain/finalize on stop. Recover after app crash, device disconnect or disk-full
  failure, with visible gaps rather than silently invented continuity.
- Select project/module and destination before recording, remembering the last
  confirmed destination. Calendar/course suggestions are suggestions only.
  For study exports use the established `01 Lectures/Transcripts/` convention;
  session-based courses use `01 Sessions/`. Preserve legacy folder layouts.
- Save Markdown automatically and atomically, plus versioned JSONL events and
  referenced assets. Include language, capture ID, source channels, relative
  timestamps, gaps, processing status and revisions. A speech transcript and
  generated interpretation must be distinguishable.
- Keep temporary audio in private local storage for seven days, show expiry and
  permit early deletion or explicit extension. No automatic audio upload/sync.
- Provide recovery/history and retryable processing. Successful capture does not
  require a successful summary or any loaded conversational model.

Offer three understandable profiles:

1. **Live & efficient:** default live preview with a measured low-energy backend.
2. **Live + quality pass:** live capture, then optional improvement when plugged
   in; preserve original transcript and record the revised version.
3. **Capture now, process later:** explicitly no live transcript, but visible
   audio capture/health and a durable pending-processing job.

Compare the existing Apple SpeechAnalyzer path with native Apple-Silicon options
such as FluidAudio/Parakeet and WhisperKit. Start with the working baseline,
benchmark representative German/English lecture audio and technical vocabulary,
then select the quality/energy tradeoff. Measure accuracy, latency, sustained
memory, battery/thermals and long-session stability; do not promise "most
accurate" and "low battery" from model size or vendor benchmarks alone.

**2A gate:** complete a realistic lecture-length test on battery and an online
session; exercise denied permissions, mute/device loss, sleep, interruption,
restart, disk pressure, final flush and correct-folder export. Do not promise
capture while the Mac is asleep. Deliver the usable capture slice for user
review before adding 2B.

### 2B: aligned visual evidence and optional local interpretation

- Opt-in selected window/display only; exclude unrelated windows where possible.
- Save selected slide/screen changes, OCR and relative image references aligned
  to the audio timeline. Detect small formula/number changes, not just word-set
  similarity. Keep capture rates, storage and power bounded.
- Preserve diagrams/formulas as images even when OCR is poor. Optionally run a
  compact local vision model on meaningful changes, or defer that work until
  plugged in. Benchmark a candidate such as Qwen3-VL-4B; no accuracy guarantee.
- Keep extracted text, local visual descriptions and spoken words separate,
  with source/time/confidence and uncertainty. Never invent spoken explanations
  for a diagram. Visual-model failure must not stop audio capture.
- Do not build PDF matching/merging into live capture. Existing downloaded slides
  can be combined later by the established study workflow.
- Queue any frontier post-processing with a reviewable prompt/file manifest and
  explicit approval. Do not automatically turn a lecture into personal facts,
  ingest it into global RAG, create cards, or launch all study-generation skills.

**2B gate:** an LLM can reconstruct what was said and which visual evidence was
visible at that time from Markdown/events/assets, without watching a video.

### 2C: discuss the tutorial while capture continues

- Allow questions about the ongoing tutorial, lecture or meeting without
  stopping recording, including an explicitly selected frontier model. Use the
  expandable companion chat or the main app; keep recording health visible.
- Ground each request in a timestamped snapshot of the available transcript and,
  when authorized and implemented, selected screen keyframes, formulas and
  relevant course files. State the context cutoff and distinguish provisional
  live recognition from finalized or later-refined text. Link answers to source
  times/images; do not pretend the model has seen the whole ongoing session.
- For a frontier request, show the provider, execution destination and exactly
  which transcript range, images and files will leave the device. Require an
  explicit scoped grant; no automatic continuous streaming of capture data.
  Further context sharing must stay within that grant or ask again. Local-only
  sessions must remain usable without uploading anything.
- Preserve conversational follow-ups separately from the factual transcript.
  Generated answers must not become recorded speech or silently enter memory/RAG.
  Use text responses by default so assistant audio does not contaminate capture.
- Prioritize uninterrupted audio/checkpoint saving over chat inference. Bound
  context assembly and local model contention; defer optional processing if
  needed. Provider failures, cancellation or hiding chat must not stop capture.
- Keep the conversation available after recording ends, with its source snapshot
  references intact. Later transcript corrections must not silently rewrite the
  evidence an earlier answer used. Reuse scoped context/session interfaces for
  phase 3 without requiring the complete project hub first.

**2C gate:** ask and follow up during a simulated ongoing capture using local and
simulated frontier providers; verify continued recording, visible context cutoff,
reviewable outbound data, no unapproved uploads and independently saved chat.

## 6. Phase 3 — one project workspace across Claude, Codex and local work

### Projects and task context

- Add a project registry with roots/host mappings, allowed sources, instructions,
  sessions, work items, artifacts and current checkpoint. The source registry is
  not a substitute for filesystem execution permission.
- Today shows selected priorities, deadlines, next actions, recent completions,
  blocked work and source health. Existing study tasks and selected Reminders
  lists keep their original ownership/IDs. Calendar supplies availability, not
  inferred commitments. Aitvaras owns quick-capture tasks and its own run state.
- Create a versioned shared instruction/skill document for agent behaviour:
  project scope, context format, evidence, privacy, uncertainty, output paths,
  completion checks and escalation. It is not an authority to bypass approvals.
  Register existing project hooks/MCP/config only after explicit trust review.

### Supported session adapters, not transcript hacks

- First prove Codex app-server start/resume/history/events/approval/interrupt.
  Capability/version-check the installed client. Use persistent sessions for
  interactive work, keeping existing isolated one-shot features separate.
- Add Claude through its supported CLI/SDK lifecycle with streaming, explicit
  session IDs, resume, permission prompts and interruption. Preserve official
  user authentication; never copy provider tokens into the coordinator/browser.
- Keep native clients usable. Start with opt-in read-only discovery/import and
  "Open in original tool". Enable bidirectional control only after verifying
  session identity, history fidelity and exclusive active-turn ownership.
- Imported history is attributed to its original provider, not fabricated as
  actions performed by another agent. Report unsupported/native-only features.
- Same-provider continuation may resume the supported session. Cross-provider
  continuation uses a new session plus an explicit context packet. Do not claim
  lossless transfer of hidden state or a running tool process.
- Record user-visible messages, decisions, approved tool effects, artifacts and
  run evidence in the work ledger. Preserve originals within authorized retention;
  summarize incrementally and index eligible material using Section 3.
- Offer scoped MCP tools for history search, source reads and task proposals to
  native harnesses; these use the same policy checks as the app. MCP is an access
  adapter, not the scheduler, synchronization protocol or privacy sandbox.
- Show which context/working files leave the device and available usage figures.
  Distinguish exact counts, estimates and unavailable billing data. Never enable
  an API charge or credential-sharing workaround to make an adapter appear ready.

### Acceptance

Start a real study/project task with its correct files; interrupt/restart and
resume; continue it in the original client; switch providers with a reviewed
handover. Retrieve an older decision with source citations and corrected facts.
Rebuild the indexes without losing source history. Deny a private canary through
retrieval, direct file tools, shell, hooks and MCP. A model selector must not
silently export a local-only conversation. If interoperability fails, retain a
clearly labelled linked/read-only session instead of promising unified control.

## 7. Phase 4 — distributed task management and independent execution

The server coordinator and at least two execution targets arrive together:
the Mac worker and a narrowly authorized always-on-host worker. This replaces
the old relay-only direction, but does not move the whole Mac environment remote.

### Minimal deployment shape

- A small containerized coordinator, durable SQL run/event store and artifact
  references; avoid a cluster, message-broker fleet or custom inference gateway.
  A single-instance SQLite/WAL store is sufficient initially if its concurrency,
  backup and recovery tests pass; devices keep their own stores, not shared files.
- Workers connect outbound with per-device identity, revocable credentials,
  explicit capability grants and heartbeat/availability. No exposed unauthenticated
  provider ports; use authenticated encrypted transport and private networking.
- The coordinator owns schedule/run metadata and approved shared context. The Mac
  owns local-only sources and its permissions. Server workers receive only their
  authorized input material and execution credentials through local secret stores.
- Keep task intent, each execution attempt, provider session and result separate.
  A client disconnect is not proof that a task failed or stopped.

### Placement and continuity

Every task declares allowed/preferred devices, required files/capabilities,
provider and billing policy, privacy scope, power requirements, approval policy,
timeout, retry/missed-run policy and completion checks. Routing first eliminates
forbidden targets; it never uses a cloud model to classify local-only payloads.

Mac-only work waits visibly while the Mac is asleep/offline. Approved server work
continues. A task created on a phone can wait for the Mac. Do not wake/prevent
sleep by default or claim the server can access unavailable local files/models.

For selected projects offer explicit server availability: a checked-out revision
or authorized snapshot, content manifest and context checkpoint. Do not copy live
working directories blindly. Use separate branches/worktrees and reconcile local
uncommitted/ignored/private files explicitly. Device handover stops/checkpoints
the current attempt and establishes file/session compatibility before starting
another; never imply universal live-process migration.

### Reliability rules

- Durable outbox/event IDs and deduplication; renewable ownership leases and
  fencing/version checks prevent stale workers publishing authoritative results.
- A lease timeout alone does not prove an old writer stopped. Do not reassign a
  mutation until its effects are reconciled or old execution is isolated/stopped.
- Assume at-least-once delivery. Use operation-specific idempotency and outcome
  reconciliation; do not promise universal exactly-once external execution.
- States include queued, waiting for device, running, awaiting approval,
  cancellation requested, completed, failed and outcome unknown. Cancellation
  remains pending until acknowledged; uncertain outcomes do not auto-replay.
- Completion requires declared evidence: output files, validated format, tests,
  cursor/watermark or service acknowledgement. Agent prose is not sufficient.
- Schedules have one owner/revision, timezone, DST policy, overlap limit and
  explicit missed-run behaviour: skip, one catch-up, or bounded replay.
- Approvals bind the exact action, input version and device; changed proposals
  require renewed approval. Stop-all and per-project pause remain available.

### Migrate existing automation safely

Inventory current cron/systemd/provider automations and first show them as
externally managed. Wrap existing proven scripts and ingest status/artifacts
before rewriting any task logic. Preserve the study dashboard and its contracts.
Migrate one low-risk job at a time, with dry-run/comparison, rollback, verified
output and an explicit cutover disabling its previous scheduler. Never let both
systems independently trigger the same side effects. Migrate remaining jobs only
after a successful operating period and user review.

Nightly consolidation becomes an eligible daily maintenance job, not a promise
to run at 04:00 on a sleeping Mac. Keep configurable schedule/power/catch-up and
Run now controls. Low-confidence questions wait for the user; unattended jobs
must not require synchronous feedback or silently broaden their permission.

### Acceptance

Run approved server work while the Mac is offline and queue Mac-only work without
leakage. Restart coordinator/worker mid-run, lose the network after a side effect
but before acknowledgement, test duplicate delivery, stale leases, concurrent
native edits, cancellation and DST/missed schedules. No duplicate effects,
false success, silent billed fallback or unreviewed migration. Recover backed-up
state and show failures even if a phone notification is never delivered.

## 8. Phase 5 — installable, mobile-friendly dashboard

- Build the authenticated web dashboard on the Phase 4 API, installable as a PWA.
  Start with Today, Projects, Tasks/Runs, permitted Chats/History and Devices.
- Show source freshness, last device contact, result evidence, context used and
  why a task is waiting. Support task creation, reviewed approvals, cancellation,
  retry and provider continuation only within verified adapter capabilities.
- With the Mac offline, approved synchronized history/results and server-backed
  conversations remain accessible. Mac-only content is honestly unavailable;
  follow-up messages may queue. Cloud reasoning can use only authorized available
  context, not pretend to inspect an offline workspace.
- Local-only means no server replica by default. Optional selected-device content
  sharing requires a separate policy; encrypted relay storage and authorized
  server-side execution are different modes with different plaintext access.
- Secure login/device revocation, least-privilege sessions and scoped downloads.
  Cache the shell/minimal metadata first; do not silently cache sensitive chat,
  screenshots or arbitrary local files in a browser service worker.
- Notifications are best-effort, content-minimal and opt-in. The durable dashboard
  inbox is authoritative. Define offline edits/conflicts; never issue destructive
  approvals silently on reconnection.
- Link into the existing study dashboard rather than replacing it. Do not build
  a native Android app, phone notification listener or on-phone model yet.

**Gate:** install on the target phone; inspect results and submit/approve permitted
work while the Mac is off; reconnect without duplicate actions. Test expired auth,
lost-device revocation, offline/stale UI and accidental data caching.

## 9. Phase 6 — private focus, reminders and mail; Android only if useful

These ideas are retained, but do not delay capture and core continuity.

### Planning and private focus pilot

- Basic priorities/reminders are already available in Phase 3; timing and deadline
  arithmetic need no LLM. Frontier planning is explicit and receives selected
  project/task data only. External task sources retain authority.
- Start an explicit focus session with outcome/time budget. Observe app/project/
  window metadata with permission; add transient local screen checks only opt-in.
- Use deterministic signals first and a benchmarked bounded local classifier when
  useful: on-task, possible drift, uncertain, away. No cloud fallback.
- Reading a lecture, technical browsing, video and inactivity are not automatically
  distraction. Uncertainty stays quiet. Provide This is work, Switch task, Snooze
  and Stop with restrained notifications, quiet hours and a daily interruption cap.
- Test productive procrastination against legitimate research; collect explicit
  feedback and false-positive/energy measurements before enabling broadly.

### Private mail pilot

- Opt-in accounts/folders, visible last check/coverage and a durable cursor with
  bounded catch-up/deduplication when the app was closed, not only asleep.
- Keep existing sender review, untrusted-content quarantine, no-send boundary and
  exact-action confirmations. Do not follow mail URLs or obey embedded commands.
- Local triage and task proposals first; originals stay in Mail. Do not silently
  export private mail or derived content to frontier memory, Telegram or syncing
  calendar/reminder accounts. Show those destinations separately.
- A private-server mail worker is a separate data-access choice, not implied by
  having a coordinator. Failure/uncertainty must not be silently classified as
  "nothing important".

### Optional native Android companion

Only after the dashboard proves useful: integrate notification listener access,
voice/camera capture and a durable encrypted outbox with explicit grants. Private
notification processing can run on-device or wait for the Mac. The PWA cannot
stand in for native system-notification access. Benchmark phone-local models on
the actual device later; no mandatory NVIDIA/CUDA dependency. Reuse the shared
task protocol, not a second assistant architecture.

## 10. Switchyard, HydraFusion and model strategy

**NeMo Switchyard** supplies model-routing decisions and integrations. It does
not provide the complete project/history/scheduling system. Its current upstream
documentation calls out pre-1.0 components and a demo standalone server; pin and
evaluate any future integration rather than placing it on the critical path.

**HydraFusion is GitHub's project**, a Copilot research preview, not an NVIDIA
product. Its relevant patterns are single-model execution, draft/escalation and
draft/independent-critique/revision. It is inspiration, not evidence that arbitrary
Claude/Codex subscriptions can be fused transparently by Aitvaras.

Start with deterministic privacy/capability routing and explicit provider choice.
Use local models for evaluated bounded tasks, frontier models for difficult
reasoning, and optional independent review when it adds value. Preserve complete
context/provenance and measure whole-task quality, latency, energy and usage.
Do not add multi-model calls solely to minimize tokens when usage is not the
constraint. Never let a router's efficiency target override privacy or retry
side-effecting work on another provider. Fine-grained automatic routing is a
later experiment behind the same adapter and policy boundaries, not a prerequisite.

Primary references checked 2026-10-19:

- [Switchyard upstream documentation](https://github.com/NVIDIA-NeMo/Switchyard)
- [GitHub's HydraFusion announcement](https://github.blog/ai-and-ml/project-hydrafusion-frontier-quality-via-multi-model-orchestration/)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server) — rich session integration;
  provider authentication/product-hosting constraints still require checking for
  the actual deployment. Local-client entitlement is not a blanket hosted-service grant.
- [Codex native host handoff](https://learn.chatgpt.com/docs/remote-connections)
- [Claude subscription SDK/CLI guidance](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Claude authentication/product constraints](https://code.claude.com/docs/en/legal-and-compliance)
- [Apple SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) and
  [Parakeet multilingual model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [WhisperKit / Argmax Swift](https://github.com/argmaxinc/argmax-oss-swift)
- [Qwen3-VL candidate](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct)

These are candidates and documented interfaces, not measured results on this
installation. Recheck versions, terms and compatibility when implementing.

## 11. Architecture and delivery checks shared by all phases

Domain boundaries: `Project`, `WorkItem`, `ProviderSession`, `RunAttempt`,
`WorkEvent`, `SourceArtifact`, `KnowledgeRecord`, `ContextPacket`, `Device` and
`Schedule`. IDs and source references connect them; do not equate a chat, a task,
a model call and a completed outcome. Use ordinary relationships first, not a
new graph-database dependency. Keep file paths/hosts/credentials installation-local.

Reuse the existing Swift store, capture, hybrid search, permission/intake and
provider-discovery foundations. Extend schemas with migrations and explicit
ownership; do not share the live SQLite file between devices or rewrite all
connectors. Existing one-shot delegate calls are not persistent frontier chats.

Maintain regression scenarios for:

- Older decisions found with evidence; corrections beat stale claims; irrelevant
  projects and private canaries do not enter outbound prompts.
- Source deletion/reindex/model-change rebuilds, backup/restore and import
  deduplication without missing or fabricated history.
- Untrusted mail/screens/documents cannot turn retrieved content into tool
  authority. Filesystem/tool access cannot bypass retrieval privacy filters.
- Capture continuity and correct-folder export before summary/index success.
- Provider version mismatch, authentication expiry, permissions and billing
  visibility; no token collection or unsupported session rewriting.
- Worker restarts, uncertain outcomes, offline queues, safe cancellation and one
  schedule owner per job.
- Idle CPU/GPU, cold-start latency, memory pressure and long-session battery use.

A planning checkpoint ends in a small demonstrable user workflow and feedback.
Do not mark a phase complete from unit tests alone, and do not commit/push
unrelated dirty work while implementing it. Public repository updates always
require explicit authorization for that specific public action.

## 12. Immediate next slice and deferred scope

First implementation: a tightly bounded Phase 1 pass (News archiving, clear
health/source state, minimal overlay and permission paths), then Phase 2A
microphone-only capture, preview, durable audio/transcript recovery and selected
folder export. Inspect the existing dirty work first; preserve it. Prove a real
recording before expanding to vision or orchestration.

Keep deferred: new dragon modelling/animation polish, news redesign, ambient
surveillance, broad location/weather/transit awareness, automatic curiosity,
messenger bridges, autonomous full-memory sharing, new API-paid model gateways,
universal live-session migration, automatic commits/merges and native Android.
These are not prerequisites for a useful Aitvaras and must earn their place later.
