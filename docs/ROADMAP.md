# Roadmap

## Current direction — 2026-10-19

The consolidated delivery plan is
[`WORK-HUB-PLAN.md`](WORK-HUB-PLAN.md): a private work hub with durable
cross-harness context and distributed execution. Its implementation is **not**
claimed complete by this roadmap.

1. Simplify the Mac app and establish clear health/source/privacy boundaries.
2. Ship reliable transcription and study-folder export, then optional visual evidence.
3. Add projects, durable history, scoped RAG and supported Claude/Codex sessions.
4. Add server coordination, Mac/server workers and safe automation migration together.
5. Add an installable mobile-friendly dashboard, preserving the study dashboard.
6. Pilot private focus/mail assistance; consider native Android only afterward.

That plan supersedes the older priorities below and in `MASTERPLAN.md`,
`FUTURE.md` and `MOBILE-COMPANION.md`. The following is a historical
implementation record, not evidence of runtime reliability or a current delivery order.
In particular, existing text-only capture and ephemeral CLI delegation do not
yet meet the new capture/session-continuity requirements.

## Historical roadmap and implementation record

The current Step 1 implementation checkpoint and its verification/release boundary
are tracked in [`STEP-ONE-OBSERVABILITY.md`](STEP-ONE-OBSERVABILITY.md).

Phase 1 = everything below. Phase 2 = messengers (Discord/WhatsApp chat), wake
word and a local-first mobile companion. The proposed Android model, shared-task
protocol and optional encrypted Docker relay are specified in
[`MOBILE-COMPANION.md`](MOBILE-COMPANION.md).

Status 2026-07-04: M0–M6 implemented in v0.1. Still open: runtime verification
of voice/Mail/EventKit paths (need interactive permissions), real avatar GLB
(user-provided), Chatterbox TTS evaluation (M2 follow-up), RealityKit avatar
pass. FSEvents-based recursive reindex shipped on 2026-07-16; the timer remains
only as a failure fallback.

## M0: Foundation ✅ (this repo state)
Repo, decisions, AitvarasKit skeleton with core protocols, character design mock.

## M1: Shell + brain
Xcode app target; main window with chat; MLX engine running Qwen3-30B-A3B streaming; engine abstraction with Ollama fallback; companion window rendering the Ready Player Me avatar in RealityKit (idle/listening/thinking/speaking driven by Mixamo clips + blendshapes, per D4); global hotkey show/hide.

## M2: Voice
SpeechAnalyzer streaming STT (DE/EN); conversation loop with VAD end-of-turn and barge-in; TTS baseline (Apple voices) behind `TTSEngine`; Chatterbox Multilingual evaluation → sidecar if it wins; character lip/energy sync.

## M3: Native integrations + safety rails
Activity log store + UI with provenance; autonomy policy enforcement (risk levels, confirmation cards); Calendar + Reminders connectors; Mail watcher with triage pipeline, in-app summaries, suggested-action cards; Telegram urgent-notify (only when user inactive).

## M4: RAG + memory
sqlite-vec + FTS5 hybrid store; embedding model bake-off (Qwen3-Embedding vs bge-m3); indexers for user-chosen note folders (md/pdf) and code repos (code-aware); FSEvents incremental reindex; personal memory with review UI.

## M5: External connectors
Generic HTTP connector engine with declarative manifests + polling triggers (D17) and its settings UI (paste key → Keychain, review tools, activate); Proxmox/TrueNAS/Home Assistant as bundled manifests; Moodle: iCal deadline feed + session-cookie scraper with in-app SSO login; "how's the homelab" briefing.

## M6: Delegation + polish
Claude Code / Codex CLI delegate connector with streamed progress; onboarding flow (permissions: Mail automation, Calendar, Reminders, mic, speech); performance pass (model load/unload strategy, memory pressure); app icon, character refinement round.

## Post-v0.1: situational + learning tracks (see MASTERPLAN.md)
Two parallel tracks proposed in `MASTERPLAN.md`: situational awareness (M7–M10) and knowledge/learning (K1–K4). Research evidence in `docs/research/`.

### K1: Memory foundation ✅ (2026-07-10, D22)
Bi-temporal facts/entities/questions schema + legacy-memory import; hybrid recall (vector+BM25, importance×recency prior); `memory.*` tools; fact layer in the system prompt (voice-lean); embedding backfill; O7 sensitive quarantine; **Memory view** (facts with search/filter/history/review, entities, questions); **ConversationArchiver** (end-of-chat episode summary + fact flush, idempotent, novelty-gated). All `swift test` + app-build verified.

### K2: The sleeping brain 🚧 core done (2026-07-10, D22)
**Done:** nightly `Consolidator` (extract → reconcile ADD/SUPERSEDE → reflect insights → curiosity questions → digest), loud failure trail and watermark retry. Its configurable scheduler treats 04:00 as a default daily boundary rather than a wake alarm, catches up after launch/wake with a settling delay and battery policy, provides Automatic/Fixed/Off and Run now controls, shows last/next/waiting status, and retains a half-hour recovery poll. Opt-in isolated Claude Code / Codex CLI execution includes authenticated discovery, live provider selection, local fallback, per-feature cloud history, on-device token accounting and a monthly cloud call-count limit. Question generation doubles as the K3 seed.
**Open:** profile-pack markdown regeneration (facts currently feed the prompt directly), a provider-independent monetary cost cap where CLIs expose reliable cost data (O8), weekly deep pass (entity summaries, dedup sweep, rhythm baselines).

### K3: Curiosity 🚧 partially done
**Done:** question queue + decay/cap, Q&A via `memory.list_open_questions`/`answer_question` tools, Questions tab in the Memory view. **Open:** proactive offering at natural moments (needs F2 attention budget), voice Q&A session mode.

### M11: Capture mode v1 🚧 implemented, runtime-unverified (2026-07-12)
Generalized capture (not meeting-specific, MASTERPLAN Part IV): setup panel asks what to capture (window / whole display / audio only) and which audio (none / system / system + mic), consent checkbox gates start (O13 → checkbox). ScreenCaptureKit stream (Aitvaras's own audio excluded), second `TranscriberSession` for system audio (`[Andere]`), optional mic channel (`[Ich]`), throttled Vision OCR with slide-change dedup, map-reduce summary; engine-down keeps the transcript (`summaryPending`, retryable). **No raw audio/frames ever persist**: text only. Companion overlay gained the mode buttons (Voice · Focus · Capture + red recording chip); `capture.*` agent tools ("schreib mit") open the setup panel; recording never starts from a model decision alone. Core logic `swift test`-green (86 tests); the live SCK + dual-SpeechAnalyzer path needs a real run (permissions): that spike is the v1 exit test.

### K4, M7–M10: not started
Procedures + self-tuning (K4); Situation Engine and downstream (M7–M10).

### M12: Android companion + multi-device tasks 💡 proposed

Build a useful offline Android companion rather than a full macOS clone:
local small-model routing/chat, voice/camera capture, a durable local outbox
and shared tasks that can wait for Mac-only capabilities. Prototype direct
encrypted phone↔Mac pairing first; add a minimal end-to-end-encrypted Docker
relay only for reliable delivery while the Mac sleeps. MCP may expose device
tools, but task synchronization, identity, leases and idempotency remain an
Aitvaras-owned protocol. See
[`MOBILE-COMPANION.md`](MOBILE-COMPANION.md) for scope, phases and acceptance
criteria.

### Part III: Today dashboard 🚧 useful first slice (2026-07-17)
**Done:** Today is the default landing surface and assembles one read-consistent,
bounded overview from existing local state: daily goals, pending confirmations,
updates held during focus, highest-value curiosity questions, active-memory count,
and the latest overnight-learning status. Goal completion and suggestion decisions
work inline; questions hand off to Chat. Overnight failures remain visible in the
dashboard and the sidebar footer while the last complete state stays in use.
**Open:** situation/next-commitment, rendered morning briefing, and interruption
budget cards depend on M7–M9.
