# Claude and Codex integration: completion checklist

Source audit — 2026-11-01. This records implementation status, not blanket runtime
acceptance. It complements [NEXT-WORKSPACE-PLAN.md](NEXT-WORKSPACE-PLAN.md) and
[CODEX-BIDIRECTIONAL-INTEGRATION.md](CODEX-BIDIRECTIONAL-INTEGRATION.md).
Older checkpoint descriptions are historical where the newer source differs.

## Current result

Codex has a shared native execution path; Claude now has an on-demand
subscription-backed Claude Code adapter, plus reviewed local history import.
Neither history import nor
project linking by itself grants export, indexing, tools or automatic work.
Claude Code and claude.ai are different surfaces: no claude.ai project/chat
synchronization is implemented or promised by the current history reader.

### Implemented

- Stable Aitvaras projects, primary/temporary chats, folders/instructions,
  revision-bound permissions and non-destructive archive/restore.
- Reviewed Codex/Claude Code history discovery/import with retained provenance.
- Native Codex project/chat links qualified by host/profile/native ID; ordered
  folder comparison, explicit working directory and filesystem identity checks.
- Shared canonical Codex history, streamed replies, native tools, supported
  inline approvals/questions, model/reasoning controls, explicit Stop and a
  durable operation journal. Uncertain input is never automatically replayed.
- Restricted Aitvaras-only Codex sessions also have approved read-only file
  listing/reading; older descriptions calling these entirely tool-free are stale.
- One Local/Codex/Claude transcript with consented handover on explicit Send. Handover
  now scans the complete eligible history, counts all omitted messages and
  strips native envelopes only against exact recorded turn/send evidence.
- Codex quota/context gauges. Capture checkpoints, sleep protection, separate
  retained audio sources, local refinement and manual Markdown export.
- Shared/default or separate Claude Code profiles, explicit official CLI
  subscription sign-in, account-qualified history grants, streaming, safe Stop,
  durable delivery barriers and approved read-only project tools. No API fallback.
- Exact-ID text refresh for app-owned Claude sessions, preserving canonical
  corrections separately from execution evidence. Imported native sessions stay
  read-only; unknown observations do not authorize replay or enter handovers.

Evidence: `WorkspaceCodexLinkStore.swift`, `WorkspaceCodexNativeStore.swift`,
`WorkspaceChatTimeline.swift`, `WorkspaceHandoverStore.swift`,
`CodexNativeWorkspaceModel.swift`, `CodexInteractiveClient.swift`,
`ProjectFileReader.swift`, `CaptureController.swift`, `CaptureAudioArchive.swift`.

## Remaining, in recommended order

### 1. Finish Codex acceptance and native metadata workflows

- Supervised installed-app check on disposable data: project/chat linking,
  streaming, approval, Stop, reconnect, handover and return to Codex desktop.
  The recorded synthetic live file-read/two-client proof verifies the runtime,
  not the full installed-app workflow. See [setup evidence](CODEX-NATIVE-SETUP.md).
- Native rename/archive/restore/move/folder updates need actual App workflows:
  inspect differences, explicit action, write, verify and retain conflict evidence.
  Transport allowlisting is not a completed user-facing feature. Local hide and
  archive must not silently alter native chats.
- Decide and implement the accepted many-native-projects → one-Aitvaras-project
  grouping. The current Codex project-link table permits one link per project.
- Preserve the native limitations: no proven exclusive cross-client controller
  lock or atomic idle-only send. No automatic resend when delivery lacks a
  confirmed native turn ID. Profile compatibility is not desktop attestation.

### 2. Finish Claude acceptance and broader native workflows

- The implemented account modes are **Existing Claude Code profile** (same
  account and supported native-session continuity) and **Separate Claude Code
  profile** (independent official sign-in, potentially a different account).
  Do not force a second account; a separate profile may also use the same one.
- Scope configuration-directory selection to adapter child processes, never the
  global login environment. Verify macOS credential isolation before enabling
  separate-profile sign-in. Never copy/extract tokens, sign another profile out,
  pool account quotas or silently switch accounts. Subscription use only; no
  API billing/fallback without a new explicit user decision.
- Preserve the goal of bidirectional continuity for supported Claude Code
  sessions in the shared profile. Qualify session/history identity by profile
  and host, enforce one active controller where demonstrable, and never treat
  same-account login as proof of safe concurrent control. Changing profiles
  must not silently adopt sessions or export their history to another account.
- Claude app/web ordinary chats and projects are a separate capability from
  Claude Code sessions. Full synchronization there requires an official,
  demonstrated interface; otherwise label them unsupported/read-only rather
  than presenting local copies as synchronized native conversations.
- Establish supported official SDK authentication, identity, history/resume,
  streaming, interruption, approvals/tools and version compatibility using an
  isolated synthetic proof first. Do not assume Codex shared-daemon semantics.
- Add the live adapter, per-provider settings, attribution and history handover;
  keep the existing Claude client usable. Unsupported takeover remains read-only.
- Distinguish local Claude Code history from claude.ai projects and expose actual
  coverage instead of claiming universal bidirectional synchronization.
- Test Local → Claude → Codex → Local continuity with explicit cloud consent,
  matching folder permissions, cancellation and reconnect behavior.

The owned-session adapter is implemented. A synthetic live response/file-read
and canonical-history proof passed on 2026-10-31. Subsequent server rejection of
a revoked token demonstrates that this is not ongoing authentication acceptance;
typed error/reconnect handling and installed-app verification remain necessary.
Existing imported-session takeover, native editing/shell/approval workflows and
claude.ai project/chat sync are not implemented. See
[Claude integration](CLAUDE-INTEGRATION.md) for the exact boundary.

### What “full project and chat sync” still requires

- **Codex:** finish native rename/archive/restore/move and folder-change conflict
  workflows, many-project grouping, and supervised two-client acceptance. Linked
  canonical chat text and native tools are not full metadata synchronization.
- **Claude Code:** explicit project-root linking, reviewed adoption/resume of
  existing native sessions, native tool/approval workflows, canonical refresh and
  safe ownership/conflict handling. Current app-owned sessions and read-only
  imports do not complete this requirement. The official SDK's local session
  management interfaces are the supported basis to evaluate next.
- **Claude app/web:** a distinct integration surface. No supported consumer
  project/chat write/sync interface has been established in this implementation.
  Managed Agents/API sessions are not those consumer chats and would not satisfy
  the subscription-only requirement by themselves. Do not substitute browser
  scraping, cookie extraction or API billing without a new decision.
- **Across providers:** explicit project equivalence and a shared authorized
  knowledge service are still missing. Aitvaras history handovers are bounded
  context exports, not bidirectional native chat identity or project mirroring.

Reference: Anthropic's [session browser cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser)
describes local Claude Code transcript operations, distinct from its
[Managed Agents sessions](https://platform.claude.com/docs/en/managed-agents/sessions).

### 3. Add the shared project knowledge service

- Project/chat evidence manifests with source IDs/versions, trust/privacy,
  freshness, citations and correction/supersession history. Archived chats remain
  evidence; they are not silently inserted into every prompt.
- Apply authorization before lexical/vector search and tool reads. Reuse the
  existing indexing/retrieval infrastructure, but do not confuse global RAG
  with the missing project-scoped service.
- Bounded cited context packets and a compact “Context used” view; explicitly
  permitted cross-project scope and cloud destinations only.
- A scoped knowledge interface/MCP for supported harnesses; rebuildable indexes,
  source deletion propagation and backup/restore tests.

### 4. Complete capture-to-course delivery and live lecture discussion

- Preselected atomic Markdown/events/assets delivery to the reviewed course
  folder, independent of summarization success. Stable chat association already
  exists; automatic folder delivery does not.
- Timestamped read-only capture snapshots for questions while recording;
  explicit frontier export grant. Never let chat failure stop recording.
- Opt-in keyframe retention and formula/diagram extraction. Current frames are
  discarded after OCR; richer visual evidence is not implemented.
- Finish retention options, including deletion only after successful selected
  analysis, with leases and failed/pending-analysis protection.

### 5. Unified usage and bounded supervision

- Durable per-provider/model usage with token/cache counts where supported,
  source/freshness/coverage and resume-safe deduplication. Claude per-turn tokens
  are retained when supplied, but subscription quota windows remain unknown;
  Codex gauges are not a complete unified ledger.
- An opt-in deterministic supervisor with attempt records, quota/reset waits,
  explicit continuation budgets, permission-change holds and side-effect
  reconciliation. Existing safe journals are not autonomous continuation.
- Stable Project → primary-chat automation targets, without loosening the
  one-time background review, global pause or notification/privacy rules.

### 6. Later phases, not prerequisites for the local integration

Evaluate an established local harness; then coordinator/workers, device-specific
execution, durable leases/outbox, offline behavior and the installable phone
dashboard. Preserve the study dashboard. Do not add a server or mobile app merely
to complete the Mac Claude/Codex adapter work.

## Verification boundaries

The handover fixes require long-history, omission-count, equal-time ordering,
exact native turn attribution, marker collision, edited wire, uncertain outcome
and existing migration/projection regression tests. No schema rewrite, personal
history import, live provider prompt, installation or public publication is
needed to verify these store changes.

Any later live model check, installed-app restart, remote deployment or expanded
data export is a separate action with its own current authorization.
