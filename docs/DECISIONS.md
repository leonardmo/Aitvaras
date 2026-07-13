# Decisions

Numbered so we can reference and revise them. Status: ✅ decided, 🔍 needs evaluation during implementation.

## D1 — Native SwiftUI app ✅
macOS 26+, Swift 6, SwiftUI. Full Xcode required (user installing). Core logic lives in a SwiftPM package (`AitvarasKit`) so it can be built and tested with `swift build` / `swift test` independent of the app target.

## D2 — Inference: embedded MLX, swappable engines ✅
- `InferenceEngine` protocol; implementations are swappable.
- Primary: **MLX** embedded in-process via `mlx-swift` (+ `mlx-swift-examples`' MLXLLM). Benefits over Ollama daemon: no external process to manage, tighter streaming/cancellation control, direct KV-cache management for the always-on companion.
- Fallback: **OllamaEngine** (HTTP to localhost:11434) — already installed, useful for A/B testing models before committing them to MLX format.
- Models: **Qwen3-30B-A3B** (MoE, 4-bit ≈ 17 GB) as main brain; **Qwen3-4B** class model for routing/classification (e.g. "is this email urgent?"); **Apple FoundationModels** framework for micro-tasks (notification triage, short summaries) where waking the 30B is wasteful.
- Target-memory budget: main model ≈ 17 GB + small model ≈ 2.5 GB + embeddings must leave headroom for the app and OS. 70B-class models are out of scope.

## D3 — Voice ✅ / TTS quality 🔍
- **STT**: Apple `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26, on-device, streaming, good German + English). Fallback option: whisper-large-v3-turbo via MLX.
- **Conversation mode**: started manually (no wake word in phase 1). Once started: continuous full-duplex conversation — voice-processing audio I/O (echo cancellation), VAD-based end-of-turn detection, barge-in (user speech interrupts TTS playback).
- **TTS**: quality bar is "ChatGPT voice mode", in DE and EN. This is the riskiest component locally. `TTSEngine` protocol, engines swappable:
  - v1 baseline: Apple premium/Siri voices via AVSpeech (instant, decent German, unspectacular).
  - ✅ (2026-07-05) **Chatterbox Multilingual implemented** as a Python sidecar (`voice/tts_server.py`, venv via `scripts/setup-neural-voice.sh`, MPS). `NeuralTTS` engine with automatic AppleTTS fallback + user toggle. Local measurements were ~8 s per sentence (~0.5× realtime) — quality tier achieved, latency is the open issue (candidates: streaming synthesis, shorter chunking, future MLX port, Kokoro for EN).
  - The sidecar is still fully local; "local-first" means no cloud, not no-subprocess.

## D4 — Character & app shell ✅ (revised 2026-07-07)
- **Current form (2026-07-07): a dragon.** The character journey — hologram (rejected: "should look like a human") → bundled human avatar → robot droid (rejected: "organic, not robot") → procedural low-poly dragon (rejected: "polygon style is not good — should be a good model") — landed on a **high-quality rigged dragon**: the Tarisland dragon (`App/Resources/DragonAvatar.glb`, see AVATAR-CREDITS.md), 25k-vert textured PBR model with 27 baked animation clips; the `stand` clip loops as her idle. She lives in the study-room diorama (time-of-day window, mail drops), lit by the room's ambient + one soft key on a dedicated light category (room lights blow PBR out), mood shown as a colored additive floor aura pulsing with her voice. The GLB required preprocessing for GLTFKit2 (specGloss→metalRough, node renames, clip-timeline rebase — documented in AVATAR-CREDITS.md). **Cute pass** (user: "a bit more cute — still a female character"): juvenile proportions (1.3× head via a wrapper node above the animated bone — the clip owns the bone itself — and a 0.9× height squash), soft glowing mood-colored eyes riding the head bone (state = size+color, blink = fade), warm key light. **Presence pass** (2026-07-07, user: "too small, too dark, mouth not moving while speaking"): scaled up (~0.62 m), a second directional fill light (directional not ambient/omni — those flood PBR to cyan), and — since the rig has no jaw bone — "speaking" reads as a gentle voice-synced head nod on a wrapper above the animated head bone, plus eye-glow + floor-aura pulse; listening adds a curious head-tilt.
- The human avatar remains selectable (Setup → Avatar); everything below still applies to it. Aitvaras stays explicitly **not anime**; serious and elegant, cyber only as accents.
- **Cartoon pivot (2026-07-07, current).** Shown a storybook reference (a chibi cute baby dragon), the user asked for a genuinely cute cartoon character — "clear eyes and mouth, cartoony but with details." The realistic Tarisland model can't read that way (its PBR/topology style is wrong), so the default character is now a **custom procedural cartoon dragon**, hand-built in SceneKit (`buildCartoonDragon()`): seafoam-teal body + warm orange belly, big glossy two-highlight eyes, an **openable smiling mouth** (jaw drops with her voice; a bead-arc smile shows when closed), blush cheeks, horns, ear-fins, a finned crest, little bat wings, a curled finned tail; flat cartoon (lambert) shading on its own bright light category. Expression via eye shape, head-tilt, cheek blush and floor-aura colour per state. The sourced GLB dragon (DragonAvatar.glb) and its baked-animation machinery were removed (−47 MB). Reference/build details in AVATAR-CREDITS.md. Body-detail pass (user: "two spheres... too cheap"): the torso is sculpted from hips + chest + a bridging neck with a segmented orange plastron, and limbs are jointed capsules via a `limb(from:to:)` helper (shoulder→elbow→hands-on-belly, hip→thigh→feet) so she reads as a body.
- **Asset** (revised 2026-07-05): Ready Player Me shut down (domain gone), and the user wants Aitvaras to have **her own identity** rather than a self-avatar anyway. Aitvaras ships with a **bundled avatar** (`App/Resources/AitvarasAvatar.glb` — MIT-licensed RPM-generated character from the TalkingHead project: dark hair, glasses, sci-fi jacket; full ARKit + viseme blendshapes). A user-supplied GLB in Application Support overrides it; Setup has import/reset buttons.
- **Face animation**: blink/expressions/lip sync driven through the ARKit blendshapes — visemes derived from TTS output (phoneme timings where the engine provides them, audio-envelope fallback).
- Rendered with **SceneKit + GLTFKit2** in v1 (loads the RPM GLB directly, morpher-based blendshape animation is straightforward there); RealityKit remains the target for a later pass — the animation state machine is renderer-independent.
- **Floating companion window**: small, always-on-top, draggable, global hotkey show/hide. Speaks/listens/reacts with animation states (idle, listening, thinking, speaking).
- **Full main window**: chat with history, activity log, connector settings, RAG index management.

## D22 — Complete Aitvaras naming ✅ (2026-07-13)
The assistant is named **Aitvaras**, after the Lithuanian household dragon that nests behind the hearth and provisions its keeper — the user researched the name in depth (wake-word phonetics: 3–4 syllables, hard /t/ plosive, /ai/ diphthong, no collisions; full German research in docs/AITVARAS.md). The name applies consistently to all user-facing strings, prompts, the app bundle, repository, Xcode project and scheme, SwiftPM package and modules, bundle identifier, state paths, calendar/reminder ownership tags, environment variables, assets, README, and documentation. The avatar uses charcoal-navy body colors, tan belly plates, a fiery red crest, gold horns/claws, ember-orange accents, and a flickering flame on the tail tip that flares with her voice.

## D5 — Mail ✅
- Watches **all accounts** configured in Apple Mail. Reads new mail but **leaves it unread**.
- Per-mail pipeline: small model classifies (urgent? actionable?) → summary stored in Aitvaras's inbox view → suggested actions (create event, create reminder, "reply needed") surfaced as one-tap accept/reject cards. **No auto-replies.**
- Urgent + user not active at the Mac → push to phone via **Telegram bot** (v1; WhatsApp requires Business API + second number or a ToS-grey bridge — revisit in phase 2 alongside messenger integration). "Not active" = screen locked / idle threshold.
- Trigger mechanism 🔍: Mail.app rule running an AppleScript (instant) vs. polling via Scripting Bridge (robust). Likely both: rule for latency, poll for missed items.

## D6 — Calendar ✅
EventKit. Aitvaras may **create** events freely (easily reversible). She may **modify/delete only events she created** (tracked by a tag in event notes/URL field + local DB). Everything logged (see D13). Her entries default into the calendar named **"Aitvaras"** when one exists so assistant-created items remain easy to identify; the same convention applies to the Reminders list (D7).

## D7 — Tasks: Apple Reminders ✅
User migrates from Microsoft To Do to **Apple Reminders** (EventKit access, local, syncs via user's accounts). No Microsoft Graph dependency.

## D8 — Messengers: phase 2 ✅
Discord/WhatsApp chat integration deferred. The `Connector` plugin interface is designed now so these slot in later.

## D9 — Moodle (TUM) — no mobile API 🔍
moodle.tum.de has the mobile web-service disabled; manually copied session tokens die after ~2 h. Strategy:
1. **iCal export token** (Moodle → Preferences → Calendar export): permanent-ish URL, gives assignment deadlines + course events officially. Cheap, reliable — implement first.
2. **Session-cookie scraping**: in-app WebKit login (user completes TUM SSO + 2FA manually), Aitvaras persists the `MoodleSession` cookie and politely scrapes dashboard/course/forum pages until it expires, then asks the user to re-login. Keychain-stored.
3. 🔍 Check whether TUM forums expose RSS tokens, and whether TUMonline/CAMPUSonline offers a usable API for grades/dates.

## D10 — Homelab: HTTP APIs, read-only, no SSH ✅
- **Proxmox**: API token bound to a `PVEAuditor` (read-only) role.
- **TrueNAS**: REST/WebSocket API key; use a read-only role account where the SCALE version supports it.
- **Home Assistant**: long-lived access token on a dedicated non-admin user.
- All tokens in macOS Keychain. No shell access anywhere — the LLM can only call typed, read-only endpoints.

## D11 — RAG ✅ / embedding model 🔍
- Sources: user-chosen folders added in-app (Knowledge → Sources) — e.g. a notes vault (Markdown/PDF) and code repositories. Folder watcher keeps the index fresh.
- Store: **SQLite + sqlite-vec** (single file, zero infra) with FTS5 for hybrid keyword+vector search.
- Embeddings 🔍: pick best multilingual model, not what happens to be installed — evaluate **Qwen3-Embedding-0.6B** (strong multilingual, runs in MLX) vs. bge-m3; `nomic-embed-text` via Ollama as stopgap.
- Chunking: Markdown-heading-aware for notes; symbol-aware for code; PDFs via PDFKit extraction.

## D12 — Personal memory ✅
Long-term memory about the user (preferences, ongoing projects, recurring people) separate from document RAG. Same SQLite store, distinct type; Aitvaras proposes memories, user can view/edit/delete all of them.

## D13 — Autonomy & activity log ✅
- **Read** operations: always allowed.
- **Easily reversible writes** (create reminder, create calendar event, research tasks): executed immediately, no confirmation.
- **Outbound / hard-to-reverse** (send anything, delete anything, modify non-Aitvaras data): confirmation card required.
- **Activity history**: every action recorded with timestamp, action, result, and provenance chain (e.g. Mail message-id → classification → created event). Visible and searchable in the main window.

## D14 — Delegation to CLI agents ✅
`DelegateConnector` runs **Claude Code** (`claude -p … --output-format stream-json`) or **Codex CLI** (`codex exec`) headlessly for tasks beyond the local model (implementations, deep research). Uses the user's existing subscription logins — no API keys. Aitvaras composes the task spec, streams progress into the activity log, and summarizes results. Delegated tasks run with explicit user confirmation (they consume subscription quota and can modify repos).

## D15 — Extensible connector architecture ✅
Every integration (Mail, Calendar, Reminders, Moodle, Homelab, Telegram, Delegate, future Discord/WhatsApp) implements one `Connector` protocol: identity, capabilities (typed tools exposed to the LLM), event stream, health/auth state. New integrations = new package conforming to the protocol; registered in one place.

## D16 — Name ✅
App and character are both "Aitvaras". Short, warm, works identically in German and English, good wake-word phonetics for a later phase.

## D18 — Connections UX: nothing preconfigured, one add-flow ✅ (2026-07-06)
The Connections tab lists always-on capabilities (Calendar/Reminders, Mail read+search, web search, goals, RAG, delegation) and otherwise starts empty. Everything else — Telegram, Moodle, homelab, weather, focus coach, custom APIs — is added through a single "Add Connection" catalog with per-type setup sheets and is removable again. Custom APIs take a pasted D17 manifest OR are **drafted by Claude CLI from a docs URL** (ManifestDrafter): the big model writes the manifest, the user reviews, the local model just uses the resulting tools.

## D19 — Focus coach + notification routing ✅ (2026-07-06)
Daily goals (set conversationally via GoalsConnector tools) + a local monitor: frontmost-app samples every 30s (memory only, never persisted or uploaded), a light-model on-track check every 20 min that notifies only on CLEAR drift, and break reminders after ~55 min of continuous activity. Off by default; enabled as a "connection".

All of Aitvaras's notifications flow through one **NotificationRouter**. **Focus mode** (toggleable by the user or by Aitvaras via `goals.set_focus_mode`) holds non-urgent notifications and delivers them bundled at the next break (break reminder, user stepping away, or mode off); urgent items (triage verdict: deadlines today, direct personal requests, time-sensitive social plans) always punch through immediately. Event pipeline: urgent → immediate local notification (+ Telegram when away); actionable/non-mail events → routed gentle notification; ordinary mail → activity log only.

## D20 — Mail stays read-only ✅
Explicit user decision: Aitvaras must never be able to send email. The mail connector exposes read/search tools only; no send/compose tool may be added.

## D21 — Notification reading via kernel-sandboxed helper ✅ (2026-07-06)
Reading other apps' notifications (WhatsApp/Signal urgency triage) requires Full Disk Access — which must NEVER be granted to Aitvaras's process (user requirement: guarantees must be programmatic, not prompt-based). Design: `notify-reader`, a ~100-line helper bundled in the app, seatbelt-sandboxes itself at launch (deny network, deny all writes, deny home reads except the Notification Center DB — kernel-enforced even if the helper is compromised), opens the DB read-only+immutable, prints JSON. Aitvaras spawns it with the TCC responsibility-disclaim attribute so the FDA grant attaches to the helper binary alone. If sandbox init fails, the helper refuses to run.

## D17 — User-addable API connectors ✅
Beyond built-in connectors (D15), the user can wire up **arbitrary HTTP APIs without writing Swift**:
- A single `GenericHTTPConnector` interprets **declarative manifests** (JSON): base URL, auth scheme (bearer / header / query / basic), endpoints exposed as typed tools (name, description, JSON-Schema params, risk level — writes default to `confirmable`), and **polling triggers** (interval + JSONPath watch expression; a changed value emits a `ConnectorEvent` into the agent loop, i.e. new automations without code).
- Secrets are pasted once in the settings UI and stored **only in the Keychain**; the manifest references them by key name.
- Manifests can be hand-written, generated by Aitvaras herself from API docs ("here's the docs URL, build me a connector" — she drafts the manifest, user reviews before it's activated), or derived from an OpenAPI spec subset.
- The built-in Proxmox/TrueNAS/Home Assistant connectors (D10) are implemented **as bundled manifests** on top of this engine, which keeps it honest.

## D22 — Memory v2: facts pipeline, quarantine, sleeping brain ✅ (2026-07-10)
Implements MASTERPLAN Part II (K1 + K2 core). Structured memory replaces the flat list: bi-temporal `memoryFact` records (typed, entity-tagged, supersede-never-delete), hybrid recall (sqlite-vec cosine + FTS5 BM25, RRF-fused, importance × last-access recency prior), `memory.*` agent tools, and the fact layer in the system prompt (40 facts chat / 12 voice). Learning is a pipeline: explicit `remember` writes live (`user_stated`, pre-authorized); a **ConversationArchiver** flushes ending chats into episode summaries + extracted facts (novelty-gated, transcript-fingerprint idempotent); a nightly **Consolidator** (background tier, due first opportunity after 04:00) reconciles ADD/UPDATE/SUPERSEDE against known facts, reflects insights, queues curiosity questions (cap 20, 14-day decay) and writes a digest — failures are loud activity-log entries that keep the watermark for retry. O7 default: pipeline-extracted sensitive facts (beliefs, health, third-party judgments — keyword screen in `SensitiveFacts`) are quarantined behind `needsReview` until approved in the Memory view. Legacy memories were migrated into facts (`v4-memory-import`).

## D23 — Testable state isolation ✅ (2026-07-10)
All persistent state resolves through `AitvarasPaths`; `AITVARAS_STATE_DIR` relocates an entire profile (tests, agents, second personas) without touching real data — `AITVARAS_SHARE_MODELS=1` opts into reusing the default model weights. `--seed-demo-state` fills an *empty* profile with a fictional persona (`StateFixtures`) so UI and agent test sessions have realistic content. Real user state never ships in the repo; `CLAUDE.local.md` (gitignored) carries machine-local context.
