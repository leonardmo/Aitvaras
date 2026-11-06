# Structured AI workspace: implementation checkpoints

**Chat implementation superseded by [UNIFIED-CHAT-PLAN.md](UNIFIED-CHAT-PLAN.md)
and D31/D32.** Its current-status section governs direct CLI sessions, new-chat
and project navigation, permissions, native discovery and verification gaps.
The adapter/link/consent milestones below are historical; old code remains
pending M6.3 owner review. Capture, evidence and future knowledge/supervision
work below retain their own scope.

Accepted direction, October 2026. This document refines
[WORK-HUB-PLAN.md](WORK-HUB-PLAN.md), preserving its privacy, evidence,
observability and private/public repository boundaries. A checklist item is not
a claim that its implementation has passed verification.

For the current cross-provider completion checklist, see
[FRONTIER-INTEGRATION-STATUS.md](FRONTIER-INTEGRATION-STATUS.md). It distinguishes
the delivered native Codex path and Claude subscription adapter from the remaining
native acceptance, project knowledge and supervision work; older text below is not
a current capability matrix.

The native Codex two-client follow-up is specified in
[CODEX-BIDIRECTIONAL-INTEGRATION.md](CODEX-BIDIRECTIONAL-INTEGRATION.md).
It requires a shared-runtime compatibility proof and an explicit native-tool
permission decision before execution is enabled; it is not delivered by the
existing isolated interactive prototype.

## Product contract

- Aitvaras Project → stable primary/temporary chat → native provider sessions,
  captures, source evidence and work attempts. A chat is not one endless prompt.
- Projects own reviewed folder/provider permissions and instructions. Chat scopes
  can narrow, not expand, that ceiling. Visibility, connection and automatic
  activation are independent settings.
- Import selected native projects/chats; several native projects can link to one
  canonical project. Match stable provider/host IDs, not names or current folders.
- Primary course/topic chats stay pinned and addressable by stable IDs. Temporary
  chats archive after seven inactive days, except active/unresolved work or
  enabled automation targets. Archive is visibility only, never knowledge loss.
- Keep native clients usable. Separate sessions may run in parallel; the same
  session has one active controller. Observe/take over only through demonstrated
  adapter capabilities. Unsupported histories/control remain linked/read-only.
- Import native updates without mirroring every message to other providers.
  Cross-provider continuation uses a reviewed context handover/new session.
- Supervised shared-folder edits are permitted with warnings; unattended editing
  requires isolation, normally a reviewed Git worktree. Never auto-merge.

## A1 — local project/chat foundation

Implemented and checked in isolated profiles:

- Additive SQLite records for projects, registered folders, logical chats and
  native project/session identity links; legacy conversations remain unassigned.
- Nested workspace rail within Chat; create/edit/hide projects, primary/temporary
  chats, archive/restore, and assign existing typed conversations without copying
  their messages. Saved voice history stays read-only in this surface.
- Restore selected workspace/chat; protect active response/voice sessions from
  switching and preserve drafts while changing chats.
- New project conversations are explicitly **text-only local**. Registering a
  folder is not a file/tool/index grant. No global memories, retrieval,
  connectors, exact shortcuts, routine learning or cloud calls in this mode.
- Project conversations are excluded from the old global fact-extraction
  archiver. Their original messages remain saved; project RAG follows below.
- Seven-day expiry is event-driven metadata maintenance on launch/workspace
  refresh, not a timer. Active/unknown/unreviewed-failure runs and the selected
  chat are protected. There are no project-targeted automations yet.

This is the first reviewable slice, **not completion of native import or the
full project-permission system**. No live profile is migrated by build/tests.
The package verification is 403 tests in 41 suites; see
[TESTING.md](TESTING.md) for lifecycle/scope checks and synthetic app scenarios.
Installation and supervised real-window review remain separate from these checks.

## A2 — native discovery and trusted project context

### A2a delivered: reviewed read-only histories

Local Codex/Claude Code discovery, text previews and imports are implemented.
Imported evidence stays separate from local chat prompts, global facts and RAG.
Provider/host/session IDs, observed revisions and explicit fork/spawn provenance
are retained; older ambiguous parent references remain labelled unverified.

The import-hardening checkpoint adds shared preview/storage normalization,
revision-bound review consent, filter-generation invalidation, Activity/History
records, retained cancellable operations and quit coordination. A manual complete
refresh traverses the exposed pages, checks source versions and fences the read
with the initial page before one atomic save. This uses the provider's available
metadata; it is not a promise of a frozen native transcript or automatic sync.
Failed/cancelled refreshes keep the previous evidence and complete-refresh time.
Individual page checks never claim complete freshness. Each complete refresh is
bounded to 100 pages / 10 million text characters; exceeding that limit fails
explicitly without replacing the saved snapshot. Saved-history browsing remains
paginated and is not capped at 300 records.

Native setup, preview, import and refresh are manual and never run a model or
control a provider session. SDK installation is a separate explicit download.
Live account/history pagination checks remain separate from synthetic testing.
The remaining A2 work below is not completed by this slice.

### A2b delivered: reviewable boundaries and capture destinations

- Additive, revision-bound project boundary reviews record the exact registered
  folders, instructions and future provider ceiling. Changes invalidate the
  review even if later reverted; stale review submissions are rejected.
- A chat context inspector shows the actual bounded metadata block used by
  local turns, its included/excluded sources and separate history budget.
  Reviewed provider choices do not activate execution or authorize export.
- Capture setup can explicitly choose a visible project's active primary chat.
  An atomic local reservation fixes the stable target before inputs start;
  checkpoints and save retries retain it after navigation, hiding or archival.
  Captures are browsable from the chat inspector and link back to their chat.
- Existing conversations, captures and settings remain unchanged/unassigned.
  Nothing auto-exports to a registered folder or adds capture/native text to
  model context. Native histories remain separate, read-only evidence.

This is a permission/context foundation, not a sandboxed file-access feature.
File reads/tools, native trust/hooks review, persistent provider execution,
automation targets and atomic course-folder Markdown delivery remain open.

### Remaining A2 integration

- Capability/version-check Codex app-server and official Claude Code SDK;
  preserve their official authentication, no token extraction/API fallback.
- Review-only project discovery; display/import selected supported chat history
  with pagination, deduplication, original attribution and fork identity.
- Offer grouping suggestions but review same-title/ambiguous sessions. Keep
  last sync, coverage and errors visible. Do not rewrite provider databases.
- Enforce the reviewed folder/provider ceiling in a tested execution sandbox
  before enabling scoped file access. Confirm native settings/hooks/MCP trust
  separately. Context packets currently contain local metadata only.
- Let automations target Project → primary chat by stable ID; captures now have
  local stable-ID links, with atomic folder delivery still pending in B.
  Preserve the study dashboard and existing study folder conventions.
- Remote projects are explicit read-only links/open-in-native in this phase;
  remote control, execution and scheduling remain later work.

## B — dependable capture and visual evidence

### Delivered sleep-protection slice

- Explicit recording/startup holds native idle-system sleep protection; visual
  capture also protects the display, while audio-only capture lets it sleep.
- Status is visible in capture controls. Acquisition failure refuses recording
  before opening inputs. Stop, cancelled/failed startup, device failure and quit
  release protection; saving, summary work and idle browsing do not retain it.
- Forced sleep is not prevented. The system sleep notification synchronously
  checkpoints the current text and adds a persistent continuity/gap warning.
  Closed-lid/low-battery behavior is not promised to keep recording.

### Remaining capture/visual work

- Select project/chat/destination before capture; save Markdown/events/assets
  atomically, independently of successful summarization/indexing.
- Preserve separate microphone/system sources, original versus refined text,
  and source timestamps. Keep recording health visible during saving/analysis.
- Save screen keyframes only after explicit consent, scoped to selected content.
  Detect formula/operator changes, preserve images when OCR fails, and defer heavy
  vision work until afterwards by default.
- Evaluate quantized Qwen3-VL via native MLX for opt-in local post-capture formula
  and diagram extraction. Preserve original images and mark ambiguity.
- Independent audio/image retention switches share: after successful chosen
  final analysis, seven days, or with capture. Default newly enabled retention
  to seven days; preserve existing settings. Active readers hold leases.
- Failed/pending analysis never triggers delete-after-analysis. Input-only
  deletion preserves text, and exported copies have independent retention.

## C — persistent frontier sessions

### C0 delivered: owned state and native isolation proof (not interactive UI)

- Additive owned-session/turn records preserve reviewed metadata, stable chat
  identity, model/effort, partial output and typed outcomes. Imported native IDs
  cannot be converted into owned identities by binding.
- Atomic reservations and unresolved-state guards block duplicate delivery;
  interruption reconciliation never automatically replays input. Policy/context
  changes invalidate old session consent, including changes later reverted.
- The installed native harness passed a loopback-only synthetic-provider proof
  for clean profile context and rejection of fabricated file/shell calls. A
  contaminated-home negative control demonstrates why native user configuration
  cannot simply be inherited. See [FRONTIER-CODEX-PROOF.md](FRONTIER-CODEX-PROOF.md).
- This checkpoint adds no provider process, login, model call, auto-sync or
  interactive composer to the installed app. Existing native chats stay read-only.

### C1: text-only Codex prototype

- Dedicated app-owned profile and official separate login, with native credentials
  in macOS Keychain; do not copy existing tokens or inherit private native config.
- Streaming/follow-ups, owned-ID-only control, project-scoped provider settings,
  model/effort selection, Activity visibility, bounded usage and safe stop/quit.
- The project chat source selector now separates Local, Codex interactive and
  imported read-only sources. Project settings has one Save action for instructions,
  folders and providers. Explicit Send creates an owned backend thread on demand;
  there is no additional consent checkbox or session-start dialog. The chat has
  a single Local/Codex/Claude selector and adjacent provider settings. Local and
  Codex share one visible chat timeline. Switching from Local to Codex confirms
  history sharing; explicit Send supplies bounded recent chat history when a
  new backend thread is required. Imported histories remain excluded. Claude's
  live backend is not implemented yet and is labelled unavailable.
  Nothing is sent merely by opening the view or saving project settings.
- Connecting the account and sending are explicit actions. The native
  process is on demand, not an idle background service. Native user credentials,
  config, skills and imported session identities are never adopted.
- The prototype is pinned to the reviewed native protocol and refuses unknown
  configuration or requirements. No file, shell, web, browser, MCP or plugin
  tools are enabled. This is not the scoped coding-agent execution phase.
- Authenticated model/catalog behavior and native persistent resumption still
  require a separately approved supervised test. Synthetic tests do not establish
  live account compatibility. If verification fails, do not weaken the isolation
  profile or silently substitute another provider/model.

### Later execution work

- Prove Codex first, then Claude Code: streaming, supported model/effort choice,
  follow-ups, approvals, scoped edits, validation, interruption and resume.
- Open natively, observe and take over only after ownership/history reconciliation.
  Fail closed if safe attachment/control cannot be demonstrated.
- Enforce filesystem/network restrictions alongside tool permissions, including
  shell, direct reads, hooks and MCP. No silent unsandboxed fallback.
- Existing isolated one-shot cloud features remain separate from persistent
  interactive sessions; no silent subscription/API/provider changes.

## D — useful local harness

- Evaluate an on-demand pinned Pi SDK helper, reusing existing MLX or approved
  local Ollama inference. Do not add another inference server for convenience.
- Disable discovered extensions/resources, telemetry, updates, cloud fallback
  and warming. Reuse existing tool capabilities only behind tested isolation
  and approvals; do not build a new general coding agent.
- Start with private context search, capture explanations and drafts. Compare
  the same model against the existing loop for outcomes, tool correctness,
  latency, memory and energy; retain the existing path if the pilot fails.

## E — shared knowledge and live capture discussion

- One authoritative evidence service, logically scoped to project/chat plus an
  explicitly approved shared layer. Cross-project searches require expanded
  scope. Shared-knowledge suggestions require user review.
- Retain authorized original active/archived chat evidence, files, captures,
  decisions and outputs. Summaries/embeddings are derived, not sole evidence.
  Corrections supersede stale assertions; deletion invalidates derivatives.
- Use established components: LlamaIndex for reusable ingestion/retrieval and
  LanceDB for local hybrid indexing; SQLite remains authoritative for evidence,
  permissions and provenance. Verify Mac packaging, offline filtering/deletion
  and resource costs first. QMD/Mem0/Graphiti are not foundational dependencies.
- Expose a scoped knowledge MCP interface to native harnesses and the same
  internal service to local agents. The service, not model-supplied filters,
  authorizes reads. Returned content sent to frontier models is a cloud export.
- Provide a small initial project/course checkpoint plus bounded cited retrieval,
  never every historical message in each prompt. Filter before both retrieval
  paths and across direct source/tool access; derivatives inherit restrictions.
- Chat about an ongoing recording without stopping it. Each question uses a
  timestamped evidence snapshot with cutoff/provisional status and manifest.
- Approve provider/sources once per recording; only user-sent questions attach
  new context. Broader scope/provider changes require renewed approval. No
  continuous upload, audio feedback by default, or answers mixed into transcript.

## F — usage and safe recovery supervisor

- Separate plan quota/reset meters from session/model token/cache activity and
  estimated costs. Include account/source/time, freshness and coverage.
- Use supported provider interfaces and opt-in native telemetry; preserve
  existing status-line configuration. Deduplicate cumulative usage on resume.
  Missing is unavailable, not zero; do not invoke models just to read usage.
- Opt-in deterministic task continuation now; general autonomous goal planning
  later. Default three continuation turns/thirty active minutes, excluding waits.
- Reconcile history and effects after sleep/network/helper failure/restart;
  native retries precede outer recovery. Wait for supported quota reset signals.
- Continue previously authorized isolated edits only after reconciliation. Hold
  unknown effects, conflicts, permission changes and new external actions.
- No auto approvals/provider switches/paid extras/reset-credit use/merges or
  replay of user-stopped/completed work. Respect global review/pause/monitoring
  gates; show every attempt and wait in Activity/History.
- Mac execution stops during actual sleep/quit; always-on execution, task/server
  scheduling and mobile dashboard remain separate later phases.

## Verification and delivery

Each checkpoint ends with user review. Use isolated profiles, synthetic captures
and simulated providers before approved live checks. Cover preservation/migration,
same-title identities, scope/permission canaries, archive knowledge retention,
native ownership, duplicate delivery, uncertain effects, deletion/rebuild,
backup/restore, long capture interruption and idle resource use.

Land reviewed changes through PRs as described in AGENTS.md. Never include
installation paths, personal project identifiers, credentials or live service
data in committed examples.
