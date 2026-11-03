# Overnight development handoff — 2026-07-16

This report describes the isolated private branch `overnight/2026-07-16`.
Nothing in this branch has been merged into `main` or pushed to the public
repository.

## Suggested review order

1. Launch the app with a separate test profile and open **Today**. This is the
   main user-facing addition and the new default landing surface.
2. Try a normal chat, a tool call, a confirmation card, Memory, Voice History,
   and Knowledge indexing.
3. Review the companion and capture behavior already included on the branch.
4. Inspect the grouped changes below rather than reviewing all commits strictly
   chronologically; much of the branch is defensive coverage around the same
   workflows.

## User-facing additions

- A **Today** dashboard brings together today's goals, actions waiting for
  approval, open memory questions, held focus updates, and the latest overnight
  learning result.
- Goals and suggestions can be acted on inline; memory questions can be handed
  to Chat with context already prepared.
- Nightly memory failures stay visible until a later successful or clean no-op
  run proves recovery.
- Chat and Voice History keep their interfaces responsive by showing bounded
  recent windows. Older messages remain saved locally and are still available
  to background memory processing.
- Degraded connections, indexing, focus state, capture recovery, notification
  delivery, and model setup now surface actionable status instead of silently
  looking healthy or empty.

## Reliability and privacy work

### State and recovery

- Local profiles isolate the database, preferences, credentials, model state,
  avatar assets, and test runs.
- Rename-era local state and components can be recovered without overwriting a
  non-empty destination.
- Typed chat, voice turns, capture checkpoints, pending capture summaries,
  focus updates, urgent phone notifications, connector checkpoints, and pending
  confirmations survive interruption with atomic storage boundaries.
- Conversation archiving and nightly consolidation remain retryable after
  engine or storage failures and avoid duplicate durable effects.

### Model and tool execution

- All inference streams have inactivity and output ceilings; Ollama also gets a
  native prediction limit.
- Chat history, retrieved context, model-generated tool arguments, tool output,
  tool bursts, total tool executions, assistant carry-over, and user-message
  size are bounded with clear failure messages.
- Confirmable actions remain atomic with their audit entries, cannot execute
  twice after an audit failure, and stop accepting new cards at a visible
  pending-queue ceiling.
- Connector drafting and delegated processes have finite input, output, time,
  and sandbox boundaries.

### Connectors and external content

- Connector HTTP sessions are ephemeral and responses are bounded.
- Connector event queues are finite and replay-safe. Event fields are bounded
  once at central intake before triage, notification, storage, or agent work;
  long source identifiers retain a digest for stable deduplication.
- Public web fetching validates DNS/IP destinations and redirects against local
  and private-network targets.
- Custom manifests, trigger observations, and checkpoints have explicit work
  and size limits.
- Credentials are kept in the profile-scoped Keychain and redacted from remote
  connector responses and diagnostics.
- External mail, notification, web, and file content is marked as untrusted and
  cannot grant write authority or become user-memory evidence by itself.

### Memory and Knowledge

- Durable facts, entity lists, curiosity questions, memory-search inputs,
  conversation-extraction drafts, and nightly plans have count and size limits
  before embedding or persistence.
- Fact corrections, answers, entity creation, FTS updates, and archive writes
  use atomic transactions.
- Knowledge indexing stays inside selected roots, reports unavailable sources
  without pruning their trusted index, and refreshes from file-system events.
- File reads are capped while reading—not only during discovery—so files that
  grow between enumeration and indexing/backfill cannot cause an unbounded
  allocation.

### Capture, voice, focus, and models

- Capture checkpoints only text, never audio or frames, and recovers unfinished
  summaries after restart.
- Voice interruption cancels queued speech and waits for final playback buffers
  before declaring a turn complete.
- Neural voice is lazy-loaded, reproducibly installed, and replaces stale
  sidecars without leaving a process behind.
- Focus app usage remains memory-only; persistent state and UI are reconciled
  after tool calls and restart.
- Model downloads are resumable, validated independently, pinned to catalog
  revisions, and incomplete installations are rejected.

## Validation evidence

- Final smoke gate: **218 tests in 18 suites passed**.
- The macOS app target built successfully after the final changes.
- The tracked-file privacy sweep passed after the final changes.
- Full Address Sanitizer and Thread Sanitizer suites passed during the branch
  run with no sanitizer findings.
- An isolated fictional profile ran through startup and scheduled overnight
  consolidation for an extended idle soak; database `quick_check` stayed `ok`
  and idle memory remained stable.
- The private remote branch matches the local branch tip. The public remote was
  not changed.

## Review notes

- The branch deliberately favors explicit failure over silently dropping or
  pretending data is empty.
- Limits are intentionally generous for normal personal-assistant use and are
  paired with user-facing recovery guidance where the user can act.
- `main` remains the comparison point. Review and merge the branch as a whole,
  or cherry-pick by the grouped themes above after trying the Today workflow.
