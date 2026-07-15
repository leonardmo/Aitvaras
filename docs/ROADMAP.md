# Roadmap

Phase 1 = everything below. Phase 2 = messengers (Discord/WhatsApp chat), wake word, maybe companion mobile app.

Status 2026-07-04: M0–M6 implemented in v0.1. Still open: runtime verification
of voice/Mail/EventKit paths (need interactive permissions), real avatar GLB
(user-provided), Chatterbox TTS evaluation (M2 follow-up), RealityKit avatar
pass, FSEvents-based reindex (currently 5-min timer).

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
**Done:** nightly `Consolidator` (extract → reconcile ADD/SUPERSEDE → reflect insights → curiosity questions → digest) on the background tier, loud failure trail, watermark retry, half-hourly `runIfDue` scheduling (due after 04:00). Question generation doubles as the K3 seed.
**Open:** profile-pack markdown regeneration (facts currently feed the prompt directly), big-model (Claude CLI) audit pass + budget policy (O8), weekly deep pass (entity summaries, dedup sweep, rhythm baselines).

### K3: Curiosity 🚧 partially done
**Done:** question queue + decay/cap, Q&A via `memory.list_open_questions`/`answer_question` tools, Questions tab in the Memory view. **Open:** proactive offering at natural moments (needs F2 attention budget), voice Q&A session mode.

### M11: Capture mode v1 🚧 implemented, runtime-unverified (2026-07-12)
Generalized capture (not meeting-specific, MASTERPLAN Part IV): setup panel asks what to capture (window / whole display / audio only) and which audio (none / system / system + mic), consent checkbox gates start (O13 → checkbox). ScreenCaptureKit stream (Aitvaras's own audio excluded), second `TranscriberSession` for system audio (`[Andere]`), optional mic channel (`[Ich]`), throttled Vision OCR with slide-change dedup, map-reduce summary; engine-down keeps the transcript (`summaryPending`, retryable). **No raw audio/frames ever persist**: text only. Companion overlay gained the mode buttons (Voice · Focus · Capture + red recording chip); `capture.*` agent tools ("schreib mit") open the setup panel; recording never starts from a model decision alone. Core logic `swift test`-green (86 tests); the live SCK + dual-SpeechAnalyzer path needs a real run (permissions): that spike is the v1 exit test.

### K4, M7–M10: not started
Procedures + self-tuning (K4); Situation Engine and downstream (M7–M10); Part III Today dashboard + status strip (Memory view shipped as the first Part III surface).
