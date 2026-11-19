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
- **STT**: Apple `SpeechAnalyzer`/`SpeechTranscriber` provides live capture captions on macOS 26. Explicitly retained source audio can subsequently use native MLX Qwen3-ASR 1.7B (quality-first candidate) or Whisper large-v3-turbo (faster alternative). Second-pass results are separate versions, never replacements for live text. See [capture refinement](CAPTURE-REFINEMENT.md) for retention, privacy and verification.
- **Conversation mode**: started manually (no wake word in phase 1). Once started: continuous full-duplex conversation — voice-processing audio I/O (echo cancellation), VAD-based end-of-turn detection, barge-in (user speech interrupts TTS playback).
- **TTS**: quality bar is "ChatGPT voice mode", in DE and EN. This is the riskiest component locally. `TTSEngine` protocol, engines swappable:
  - v1 baseline: Apple premium/Siri voices via AVSpeech (instant, decent German, unspectacular).
  - ✅ (2026-07-05) **Chatterbox Multilingual implemented** as a Python sidecar (`voice/tts_server.py`, venv via `scripts/setup-neural-voice.sh`, MPS). `NeuralTTS` engine with automatic AppleTTS fallback + user toggle. Local measurements were ~8 s per sentence (~0.5× realtime) — quality tier achieved, latency is the open issue (candidates: streaming synthesis, shorter chunking, future MLX port, Kokoro for EN).
  - The sidecar is still fully local; "local-first" means no cloud, not no-subprocess.

## D4 — Character & app shell ✅ (revised 2026-07-18)
- **Previous sourced-mesh stage (2026-07-07).** The character journey — hologram (rejected: "should look like a human") → bundled human avatar → robot droid (rejected: "organic, not robot") → procedural low-poly dragon (rejected: "polygon style is not good — should be a good model") — briefly used the rigged Tarisland dragon. Its realistic PBR/topology language could not produce the requested cute, readable companion, so the sourced model and its 47 MB of animation machinery were removed.
- The human avatar remains selectable (Setup → Avatar); everything below still applies to it. Aitvaras stays explicitly **not anime**; serious and elegant, cyber only as accents.
- **Authored fire-drake mesh (2026-07-15, now the fallback).** The first cartoon implementation was rejected because a stack of SceneKit spheres, capsules and rounded boxes still read as an inflated toy even after material and lighting work. The primitive model and its builder were removed. The default is now the original bundled `AitvarasDragon.glb`, reproducibly authored by `scripts/generate-dragon-avatar.py`: 24,452 triangles and 74 named mesh parts, including a shaped skull/snout, overlapping scale fields, layered belly/face/limb armour, curved jointed anatomy, separate paws and claws, multi-panel wings and finger bones, curled tail and emissive two-layer flame. Named nodes drive eye blinks/mood, head tilts, the hinged voice-reactive jaw and tongue, breathing wings and flame flicker without a skeletal rig. Ink-blue scales, crimson armour, orange fire transitions and gold details follow the Aitvaras colour story while the oversized eyes and seated proportions preserve the cute read. PBR materials use controlled roughness, environment reflections, a shadow-casting soft key, cool fill, warm rim, SSAO and a reflective plinth/contact shadow. The asset contains no third-party model geometry or textures.
- **Meshy-based runtime dragon (2026-10-16, current).** The default is now `App/Resources/AitvarasDragonRuntime.glb`, reduced by `scripts/build-dragon-runtime.py` from a Blender master generated with Meshy, with the seated pose baked in and only jaw, blink and eye-look morphs left live. `AitvarasDragon.glb` stays as the fallback. The asset has no body clips, and idle and hidden states render no frames. Details and checks: `docs/character/dragon-runtime/`.
- The companion uses a compact liquid-glass frame that appears on hover, with controls above and below the portrait so they do not obscure the character. The room wall is translucent and the portrait is deliberately close.
- **Asset** (revised 2026-07-05): Ready Player Me shut down (domain gone), and the user wants Aitvaras to have **her own identity** rather than a self-avatar anyway. Aitvaras ships with a **bundled avatar** (`App/Resources/AitvarasAvatar.glb` — MIT-licensed RPM-generated character from the TalkingHead project: dark hair, glasses, sci-fi jacket; full ARKit + viseme blendshapes). A user-supplied GLB in Application Support overrides it; Setup has import/reset buttons.
- **Face animation**: blink/expressions/lip sync driven through the ARKit blendshapes — visemes derived from TTS output (phoneme timings where the engine provides them, audio-envelope fallback).
- Rendered with **SceneKit + GLTFKit2** in v1 (loads the RPM GLB directly, morpher-based blendshape animation is straightforward there); RealityKit remains the target for a later pass — the animation state machine is renderer-independent.
- **Floating companion window**: small, always-on-top, draggable, global hotkey show/hide. Speaks/listens/reacts with animation states (idle, listening, thinking, speaking).
- **Minimal overlay is the default (2026-11-19).** With no saved choice, the companion opens as the minimal overlay, which renders no 3D model. The avatar is opt-in under Setup → Companion; a saved choice is kept.
- **Full main window**: chat with history, activity log, connector settings, RAG index management.

## D22 — Complete Aitvaras naming ✅ (2026-07-13)
The assistant is named **Aitvaras**, after the Lithuanian household dragon that nests behind the hearth and provisions its keeper — the user researched the name in depth (wake-word phonetics: 3–4 syllables, hard /t/ plosive, /ai/ diphthong, no collisions; full German research in docs/AITVARAS.md). The name applies consistently to all user-facing strings, prompts, the app bundle, repository, Xcode project and scheme, SwiftPM package and modules, bundle identifier, state paths, calendar/reminder ownership tags, environment variables, assets, README, and documentation. The avatar uses ink-blue body colors, layered burnt-orange belly plates, crimson head armour and wings, gold horns/claws, flame-orange accents, and a flickering flame on the tail tip that flares with her voice.

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

## D9 — Moodle — no mobile API 🔍
moodle.example.edu has the mobile web-service disabled; manually copied session tokens die after ~2 h. Strategy:
1. **iCal export token** (Moodle → Preferences → Calendar export): permanent-ish URL, gives assignment deadlines + course events officially. Cheap, reliable — implement first.
2. **Session-cookie scraping**: in-app WebKit login (user completes university SSO + 2FA manually), Aitvaras persists the `MoodleSession` cookie and politely scrapes dashboard/course/forum pages until it expires, then asks the user to re-login. Keychain-stored.
3. 🔍 Check whether the university's forums expose RSS tokens, and whether the campus management system offers a usable API for grades/dates.

## D10 — Homelab: HTTP APIs, narrowly scoped, no SSH ✅
- **Home Assistant** (built in): long-lived access token on a dedicated non-admin user;
  verified API access, compact/searchable entity reads and exact idempotent
  `light.*` on/off are exposed (D28), with no arbitrary service calls. Plain
  HTTP is accepted only for local/private hosts; other origins require HTTPS.
- **Other homelab services** (hypervisors, NAS systems and similar) are
  custom manifests (D17) with read-only API tokens.
- All tokens in macOS Keychain. No shell access anywhere—the LLM can only call
  typed endpoints; custom homelab manifests stay read-only and HA writes are limited
  to reversible lights.

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
`DelegateConnector` runs **Claude Code** (`claude -p`) or **Codex CLI**
(`codex exec`) headlessly for tasks beyond the local model. Uses the user's
existing subscription logins—no API keys—and reports signed-out installations
in Connections with the exact login command. The user can select either
provider; automatic mode prefers authenticated Claude and then Codex.
Delegated prompts travel over stdin rather than the process list, inherited
API-token/MCP configuration is excluded, Claude runs in safe automatic mode,
and Codex runs ephemerally in a workspace-write sandbox. A successful process
with denied Claude operations is treated as failure. Delegated tasks remain
`confirmable` because they consume quota and may modify the selected workspace.

The four non-chat CLI-backed features share one provider-neutral boundary and the
versioned Aitvaras Cloud Agent Policy. Delegation, nightly memory, connector
creation and routine review each have an independent Local/Automatic/Claude/
Codex setting. Automatic mode validates the task result and tries Codex if
Claude fails or returns an invalid structured result. A local ledger records
call metadata and provider-reported usage where available, but never prompt or
response text; a profile-scoped monthly call count can prevent further calls.
Selections are resolved when a new call starts, so changes take effect without
restarting the app. Turning routine review on immediately checks unreviewed
existing candidates. Usage UI exposes monthly totals and recent history for
each feature.

Interactive project Chat instead uses the direct `AitvarasAgents` backends
and `AgentSessionManager` (D31/D32). It does not use `CloudAgentService`'s
restricted feature calls. Those four non-chat features retain the isolation,
selection and accounting rules here; native chat configuration is not enabled
for them.

Tool access follows the job: confirmed delegation receives its selected
workspace because editing is the point. Nightly memory and routine review gain
nothing from tools, while connector drafting receives documentation fetched by
Aitvaras's bounded SSRF-safe reader. Claude tools are disabled for these
structured jobs; Codex runs read-only in an empty temporary directory.

On-device inference has a separate metadata-only ledger. MLX and Ollama provide
exact prompt/generation counts; unsupported engines are explicitly estimated.
The UI calls their sum **token credits** to make local and cloud workloads
comparable, while stating that local credits have no monetary cost.

## D15 — Extensible connector architecture ✅
Every integration (Mail, Calendar, Reminders, Moodle, Homelab, Telegram, Delegate, future Discord/WhatsApp) implements one `Connector` protocol: identity, capabilities (typed tools exposed to the LLM), event stream, health/auth state. New integrations = new package conforming to the protocol; registered in one place.

## D16 — Name ✅
App and character are both "Aitvaras". Short, warm, works identically in German and English, good wake-word phonetics for a later phase.

## D18 — Connections UX: nothing preconfigured, one add-flow ✅ (2026-07-06)
The Connections tab lists always-on capabilities (Calendar/Reminders, Mail read+search, web search, goals, RAG, delegation) and otherwise starts empty. Everything else — Telegram, Moodle, homelab, weather, focus coach, custom APIs — is added through a single "Add Connection" catalog with per-type setup sheets and is removable again. Custom APIs take a pasted D17 manifest OR are drafted by the configured Claude Code/Codex cloud agent from a description and bounded public documentation. Aitvaras fetches the documentation itself through the SSRF-safe reader, sends no credentials, validates the returned manifest locally and still requires user review before activation.

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
- Other homelab services are custom manifests on this engine. Home Assistant
  reuses bundled declarative tool metadata but has a constrained adapter for
  local entity search, response minimization and exact light validation; it
  does not gain an arbitrary service-call escape hatch.

## D22 — Memory v2: facts pipeline, quarantine, sleeping brain ✅ (2026-07-10)
Implements MASTERPLAN Part II (K1 + K2 core). Structured memory replaces the flat list: bi-temporal `memoryFact` records (typed, entity-tagged, supersede-never-delete), hybrid recall (sqlite-vec cosine + FTS5 BM25, RRF-fused, importance × last-access recency prior), `memory.*` agent tools, and the fact layer in the system prompt (40 facts chat / 12 voice). Learning is a pipeline: explicit `remember` writes live (`user_stated`, pre-authorized); a **ConversationArchiver** flushes ending chats into episode summaries + extracted facts (novelty-gated, transcript-fingerprint idempotent); a nightly **Consolidator** (due first opportunity after 04:00) reconciles ADD/UPDATE/SUPERSEDE against known facts, reflects insights, queues curiosity questions (cap 20, 14-day decay) and writes a digest. Nightly memory can explicitly use Claude Code, Codex CLI, or automatic Claude→Codex selection for one bounded, isolated, non-persistent pass; local inference remains the default and is also the automatic fallback for sign-out, quota, network, or malformed-output failures. The activity detail records the engine and whether fallback occurred; total failure remains loud and keeps the watermark for retry. O7 default: pipeline-extracted sensitive facts (beliefs, health, third-party judgments — keyword screen in `SensitiveFacts`) are quarantined behind `needsReview` until approved in the Memory view. Legacy memories were migrated into facts (`v4-memory-import`).

## D23 — Testable state isolation ✅ (2026-07-10)
All persistent state resolves through `AitvarasPaths`; `AITVARAS_STATE_DIR` relocates an entire profile (tests, agents, second personas) without touching real data — `AITVARAS_SHARE_MODELS=1` opts into reusing the default model weights. `--seed-demo-state` fills an *empty* profile with a fictional persona (`StateFixtures`) so UI and agent test sessions have realistic content. Real user state never ships in the repo; `CLAUDE.local.md` (gitignored) carries machine-local context.

## D24 — Rename-safe local state migration ✅ (2026-07-16)
The Naomi → Aitvaras rename must not strand local memories, model weights, voice assets or avatar overrides. Before the default database opens, a guarded idempotent migration moves the legacy components into the Aitvaras state root. A populated legacy database may replace only a demonstrably empty Aitvaras database (the empty file is retained under `Migration Backups`); if both contain user data, neither is touched and startup fails loudly for manual review. Isolated profiles never invoke this migration. Model discovery has a read-only legacy fallback so the headless MLX test can verify an installation before migration runs.

## D25 — Trusted senders are routing approval, not authority ✅ (2026-07-17)
Unapproved Apple Mail and macOS-notification senders are held before any model call, alert forwarding or agent work and appear in a local sender-review queue. Users may approve an exact mail address, an exact app+notification-label pair, or (after a warning) an exact non-consumer domain; shared mailbox domains such as `gmail.com` can only be approved address-by-address. Approval never authenticates a sender and never makes content instructions: approved external mail runs without Memory, RAG, history, web/mail/file/read tools and can only propose a new event or reminder, with mandatory confirmation enforced again in ConnectorHub. Configured Moodle/custom-service payloads remain untrusted but use the existing tool-free classifier. See `docs/MESSAGE-TRUST.md`.

## D26 — Deterministic wake briefings ✅ (2026-07-18)
After macOS reports system sleep, Aitvaras stores the exact boundary in its
local SQLite key/value state. A wake after less than five minutes is ignored;
longer sleeps trigger direct catch-up reads for Apple Mail, the Notification
Center helper when enabled, and Moodle when configured. Catch-up events still
pass through the existing stable-ID deduplication, sender approval,
quarantine, audit and confirmation rules. Their individual local/Telegram
presentation is suppressed so wake produces one introduction rather than a
burst.

The introduction is deliberately not an LLM summary of external text. It is a
bounded sentence assembled only from typed activity counts (mail,
notifications, Moodle deadlines, other service events, held senders, pending
suggestions and failed phone delivery) plus a closed enum of unavailable local
source names. Subjects, bodies, sender instructions and URLs therefore cannot
become spoken prompt injection. Connector lookback is capped at seven days,
but the real sleep duration remains in the greeting. Direct replay is capped
at the 200 most relevant events per source to prevent a flood from monopolizing
the assistant; the greeting explicitly identifies any partial source. Recording the
`wakeBriefing` activity event and consuming its boundary is one transaction
that verifies the exact sleep timestamp: duplicate wake notifications cannot
repeat it, and a slow old catch-up cannot clear a newer sleep boundary.

## D27 — Quiet, source-first News is an isolated reader ✅ (2026-07-19)
News is not another event stream. The user configures named topics, importance
and a six-hour, twelve-hour, daily or weekly interval. Due topics refresh
silently; stories never create notifications. The only proactive moment is an
optional, configurable morning offer claimed atomically once per local day,
or the user can ask through chat/voice at any time.

A versioned one-time starter set provides practical **AI tools & workflows**,
**International politics** and **Germany** feeds. They become ordinary user
topics after installation: edits and deletions are never overwritten on a
later launch, while unrelated custom topics are preserved. The former broad
`AI research` demo topic is replaced because it favored papers over changes
that materially affect day-to-day AI-assisted work.

Retrieval is source-first rather than model-first. Fixed publisher feeds
(SPIEGEL, Tagesschau, BBC, DW, Nature, Ars, TechCrunch, The Verge, OpenAI,
DeepMind, Hugging Face and GitHub) supply summaries and images. Practical AI
coverage also reads the official Claude Code and Codex release streams,
Google and Microsoft developer blogs, and selected expert analysis from Simon
Willison and One Useful Thing. Google News RSS
adds arbitrary-topic discovery, but a result is discarded unless its declared
publisher matches an explicit quality catalogue. Ranking is deterministic:
publisher tier, freshness, query relevance, useful metadata and independent
cross-source coverage. Publisher summaries are shown and spoken with audible
attribution; an LLM is not allowed to invent a synthetic article summary.
Explicit voice news requests route through the full chat model rather than the
usual low-latency voice tier before the source-attributed result is spoken.

SPIEGEL receives a small preference and paywalled articles open in the normal
signed-in browser—Aitvaras never copies browser cookies. X/Twitter is excluded until an
authenticated integration can provide acceptable provenance and signal.

News uses dedicated `newsTopic` and `newsArticle` tables with a 250-item and
30-day bound per topic. It deliberately records no Activity event and is never
read by RAG, conversation context, the archiver or nightly consolidation.
Article text stays untrusted, the agent sees explicit delimiters, and the
connector exposes reads only; remote content cannot configure a topic. The
SwiftUI reader keeps the selected image, source text and link visible while
local TTS narrates it, and supports stopping narration immediately.

## D28 — Learned exact shortcuts; schedules require approval ✅ (2026-07-19)
Repeated small commands should not pay inference latency forever. After three
successful user-initiated runs, Aitvaras compiles a shortcut only when the
normalized phrase and complete canonical tool path are identical every time,
the path contains a reversible write, and no step is `confirmable`. Matching
is exact after case/diacritic/punctuation normalization—not fuzzy or semantic.
Voice and typed input check it before the model, show a visible “Shortcut · no
AI” result, and execute the displayed steps through ConnectorHub. Current tool
existence and risk are revalidated at runtime; a changed connector fails closed
instead of falling back to a model that might duplicate a partial side effect.

The local observation window contains only the bounded command text and fixed
tool calls, never reasoning or tool output, and is pruned after 90 days. A
deterministic after-command and nightly scan also looks for cautious daily,
weekday or same-weekday time clusters. Those create review cards only. A time
automation cannot run until the user activates it in **Shortcuts**, and
confirmable workflows can never be scheduled. Scheduled slots are claimed
before execution so wake/restart races cannot replay writes.

This revises D10 only for Home Assistant's `light.*` domain: exact light on/off
service calls are now typed `reversibleWrite` tools so a command such as
“Licht aus” can become a useful shortcut. Custom homelab manifests remain read-only;
Home Assistant exposes no arbitrary service, delete, lock, alarm or shell tool.

Creation and execution remain deterministic and local. An optional,
independently configured Claude Code/Codex review runs only after Aitvaras has
derived and safety-checked a candidate. It receives a bounded phrase, schedule
pattern and fixed tool names/arguments, and can improve only the visible title
and factual explanation. The store cannot apply model-authored triggers,
steps, arguments, risk, status or approval. Review failure never blocks local
creation or execution.

## D29 — Nightly memory uses a catch-up boundary, not a wake alarm ✅ (2026-07-24)

A laptop that is closed and unplugged at 04:00 cannot reliably execute a local
job, and an unattended memory pass must not depend on a synchronous answer.
The default schedule therefore treats 04:00 local time as the start of a daily
eligibility window. Aitvaras runs once at the first suitable opportunity:
after launch or a macOS wake, a ten-minute settling delay, and either external
power or at least 20% battery. An adaptive timer targets that opportunity and
a half-hour poll is retained only as a recovery path. The successful-run
watermark remains durable, so restart and duplicate wake events cannot repeat
the same daily pass.

The Models screen exposes Automatic, Fixed time and Off; earliest/fixed time;
wake delay; Always, battery-threshold and plugged-in-only power policies; Run
now; and last successful / next eligible / reason-waiting status. A missed
fixed time catches up after wake rather than being lost. Automatic failures
stay loud in Activity but do not interrupt the user; they retry after 30
minutes. Questions discovered during consolidation remain in the existing
Memory review queue. Local inference is still the default. When the user
selects Claude or Codex for Nightly memory, the UI states that archived
conversation summaries and relevant facts leave the Mac for that unattended
run.

## D30 — One chat transcript; backends catch up on Send ✅ (2026-10-26)

The original adapter contract below remains relevant to legacy readers. D31
amends consent and the context limit for the current unified Chat: provider
selection plus Send authorizes catch-up, bounded to 16,000 UTF-8 bytes. New
chats use normalized sessions and entries; legacy evidence stays readable.

A workspace chat is one conversation, whichever engine answers. Aitvaras owns
its canonical transcript: local messages, Aitvaras-only Codex turns and linked
native Codex items (Claude later) form one timeline, and every entry records
the thread that produced it. Native imports remain separate read-only evidence.
Switching backend sends nothing and loses nothing.

- **Local** is stateless per turn and reads the recent completed transcript
  every time, whoever wrote it.
- **Thread backends** (Aitvaras-only Codex sessions, linked native Codex chats,
  later Claude) keep their thread. When the user sends, completed messages that
  other threads produced after this thread's last handover travel with the
  message as one labelled handover block: oldest first, at most 16,000
  characters, older messages dropped with a stated count when over budget. A new
  thread for a chat with history is caught up the same way. The block is plain
  deterministic text; local summarisation of long gaps is a later option.
- **Explicit, never silent.** A handover happens only inside a user's Send and
  only with that chat's cloud-sharing consent (`shareHistory.codex`). The exact
  text sent is recorded, and the transcript shows it as an expandable "Caught
  Codex up on N messages" line. In linked native chats the block is part of the
  user message in the shared Codex thread, so it is visible in Codex desktop;
  Aitvaras strips it from its own rendering of that message so it is neither
  shown twice nor handed over again.
  Envelope removal requires an exact recorded send and its acknowledged native
  turn ID; marker-looking user text or edited native messages remain untouched.
- **No gaps, at worst a duplicate.** A thread's handover watermark advances only
  after the provider acknowledges the turn. Undelivered turns hand over nothing;
  an uncertain outcome does not advance it, so the next Send repeats rather than
  skips.
  The scan is independent of UI pagination: all eligible missed messages are
  considered and counted, while only the bounded newest context is retained.
- Turns are never written into another provider's history as if that provider
  had produced them. Imported histories, captures, other chats and memories are
  not part of a handover.

This implements the "explicit context handover" promised in
[CODEX-BIDIRECTIONAL-INTEGRATION.md](CODEX-BIDIRECTIONAL-INTEGRATION.md) and
replaces the earlier Aitvaras-only rule that started a fresh Codex thread
whenever the latest message was local: the thread is now kept and caught up.

## D31 — Chats drive the official CLIs directly 🚧 (2026-11-04)

See [D34](#d34--project-agent-setup--2026-11-17) for project setup, MCP gating, approvals and conversation forks.

**Implementation and acceptance:** the unified UI is connected to the direct
backends, durable journal, native discovery/reconciliation and action coordinator.
Codex has run through the in-process UI driver. The Claude path through this UI
has never run live because its CLI login expired; the visible signed-out row and
offline recordings do not prove a Claude reply, catch-up or browser completion.
The real Ollama Local gate has not run, so AgentLoop remains the default.
Old chat adapters, models, helpers and diagnostics are not yet removed: M6.3
waits for the owner's review. Native menus, file panels, drag and drop and real
focus are covered only by the XCUITest, which needs the owner's password and
has not passed that gate. Light/dark and the 800 × 500-point minimum content
layout also require real-app screenshot review; adding a scenario is not proof.

Replaces the adapter approach in `CLAUDE-INTEGRATION.md` and
`CODEX-BIDIRECTIONAL-INTEGRATION.md`; plan in `UNIFIED-CHAT-PLAN.md`. Chat runs
`claude` and `codex app-server` as subprocesses, so chats exist natively in
those tools. Claude has named account profiles, each with a separate CLI home
(`CLAUDE_CONFIG_DIR`) and native history. The migrated default profile leaves
that variable unset and uses the existing login. Additional homes live under
`<state>/Providers/claude/<UUID>` with mode 0700 and symlink only the default
home's `CLAUDE.md`, `settings.json`, `skills` and `plugins` when present.
Aitvaras never copies credentials or touches the default home. User-scope MCP
servers stay per account; app-global MCP definitions can be shared. Sign-in is
the CLI's own browser flow and credential store; Aitvaras never handles tokens.
Codex and Local retain exactly one implicit profile and no profile UI. Their
remaining multi-account work in issue #9 is open. Child environments inherit the app's environment minus a denylist of
credential and endpoint overrides: the allowlist dropped `USER`, which pointed the
CLI at a stale credential item. The session start checks first-party subscription
status and refuses anything else. API keys stay forbidden.

Changing provider or Claude profile and pressing Send is the consent for sending that chat's earlier
messages to the provider (amends D30). Every provider action passes
`AgentActionCoordinator`, using Claude's pre-tool hook callback and Codex's sandbox,
approvals and item events, so the autonomy policy and activity log still hold.
Pending permission, plan and question cards wait without an automatic timeout,
matching the native CLIs. Answers, Stop, provider cancellation or resolution
(including turn end), and process exit clear them through the audited lifecycle.
Up to eight chats may have a turn in progress, including approval waits. Idle
transports do not consume that allowance; at eight retained transports, a new
chat evicts the least recently used idle one and resumes its durable native
session on its next Send. Capacity refusal stays inline without failing the chat.

The new chat path bounds each deterministic handover block, including labels, to
16,000 UTF-8 bytes. It keeps the newest completed messages, orders them
oldest first, states the omitted count (and explicitly clips an oversized newest
message at a Unicode character boundary) and advances the per-session/profile watermark
only on acknowledgement. Local receives completed context on every Send. Legacy
adapters retain their existing sharing checks until migration.

Native history refresh publishes a complete canonical branch atomically across
a chat's refreshed sessions, keyed by native message identity (turn and item
for Codex, persisted UUID for Claude). Streamed rows retain their display IDs;
removed branch messages are retired from the projection, with prior observations
and execution journals retained. Failed, partial or inconsistent reads keep the
last projection. An unavailable native reader (including a newly created session
not yet present in native storage or an unsupported full-history surface) does
not block Send: it uses the retained canonical transcript. Identity conflicts,
malformed history and persistence failures still fail closed. Passive refresh
failures do not replace the inline send/sign-in error. A second complete observation checks for changes during refresh;
it does not reserve the native session against another client. Changed native
content evicts an idle run so the next Send resumes the updated native session.

Issue #23: successive tool-result UUIDs were rebinding the input row and causing
a persistence identity conflict that killed the turn. Claude user frames
consisting entirely of tool results finish their tools but
are not user messages: their UUIDs never bind the input row. Input bindings
also refuse a second, different native identity. The one-time v39 repair clears
only Claude user-row native UUIDs that differ from a proven owning journal
input UUID. The journal must match chat/session; links through `journalInputID`
require corroborating `nativeHistory.itemID`. Conflicting or malformed metadata,
inherited fork rows and unowned imports remain untouched. Native-history
evidence, journals, content and display IDs are preserved. Ordinary GRDB
migrations have no automatic database backup; installation requires a manual
database backup before upgrading. No app-level backup is added for this repair.
Hook events fold into their tool payloads under the matching rules in D34.

Claude local command echoes display as slash commands. Tagged stdout and stderr
attach to the originating user entry in live streams and native history. The
CLI caveat stays hidden. Local command output from a queued Send does not start
an autonomous turn or take ownership of a running model turn (D38).

Turn-ending error catches retain a typed safe category across backend and
coordinator boundaries through `AgentEvent.failureReport`. Public backend/run
throws and stream errors unwrap diagnostic carriers to `AgentFailure`.
Activity records only the error type and case plus
chat/input provenance, never descriptions, associated values, paths, prompts
or credentials. Full caught errors go to unified log with explicit `.private`
interpolation. Unknown error types use a validated metatype name and an
`unknown` case, without inspecting the value. Failure diagnostics are excluded
from memory evidence. If the Activity write itself fails, the full error is
privately logged without recursively auditing the audit failure; durable
diagnostics cannot be guaranteed while storage is unavailable.

An abnormal turn end now commits a compact `stopped` transcript entry with
the journal outcome. It retains delivery evidence, provider/profile and native
session identity, the safe error category and any reported quota reset time.
Reopening and native history refresh preserve it. Startup recovery creates a
Connection lost row for unfinished journals without sending anything. Explicit
Stop creates a Stopped row. Internal failures show “Aitvaras error · category”
with only Copy details, which copies the category. Connection failures show
“Connection lost”; quota failures show “Usage limit reached”, with a local
24-hour reset time when known. These offer Continue for acknowledged input and
Retry otherwise. Authentication keeps the existing Sign in flow.
Provider-reported result/assistant errors use the fixed `providerError` case
and the Connection lost actions. Internal catches retain `unknown` or their
safe store/history category; provider error text never becomes composer copy.

Manual recovery remains available for Stopped rows. The manager's recovery API validates the original durable
session and rejects absent or changed native identities for Continue. Continue
checks Claude's authoritative system/init identity; foreign session IDs on
ordinary tool, subagent, hook or compaction frames do not terminate a turn. Continue
sends exactly “Continue where you stopped.” through the normal policy boundary,
without a catch-up envelope, and persists a small `continued` marker instead of
a user bubble. Native refresh preserves that marker only for the exact recorded
instruction; an edited native message renders as user text. Retry restores the
original wire prompt and selected composer bytes, including when delivery is
unknown. Each click claims the stopped row and prepares one new journaled attempt
atomically before writing to the provider. Old delivery evidence is retained;
repeated/stale claims cannot send again. Usage-limit rows also support the
separately audited automatic continuation in D41.
Composer failures remain only for provably undelivered input. Stopped diagnostics
stay outside provider context, and Continued markers delimit their own journal
when selecting completed assistant context.

Catch-up scans normalized entries and the chat's legacy local, owned and linked
timeline without the UI page limit. Completed messages from other sessions are
eligible, including earlier sessions of the same provider. Acknowledged handovers
record source identities and text digests as well as their exact wire envelope.
Corrections or deletions invalidate that receipt and send an explicitly labelled
canonical-history correction on the next Send. Unknown delivery never consumes
context. Older positional receipts conservatively repeat context. Envelopes are
stripped only for an exact acknowledged send bound to the canonical user identity
(and the acknowledged native turn identity for Codex).

Per-chat git worktrees are optional and default off. Their ownership and cwd/root
mappings are durable; failed or mismatched ownership blocks execution. Explicit
Commit and confirmed Discard pass the autonomy policy and metadata-only activity
audit. Discard clears reviewed changes only inside the selected owned worktree;
it never force-removes a worktree or branch. Ordinary checkouts allow explicit
Commit, with the user's message and native git hooks, without added attribution.
The Git panel also shows the current branch, upstream and locally known
ahead/behind counts (refresh does not fetch). Explicit Push and Commit and push
require a visible outbound confirmation under D13 and the Git autonomy policy.
Push only sends the current branch to the same name on origin, setting upstream;
force, refspec-like branch names and arbitrary refspecs are unavailable. Detached HEAD and the origin default
branch are refused (origin/HEAD, falling back to existing origin/main or
origin/master). Owned worktrees may push only their chat's recorded
`aitvaras/chat-…` branch; ordinary checkouts may push their current non-default
branch. Ownership and branch are rechecked after authorization, and pushes share
the coordinator's serialization. Native hooks and configured credential helpers
run normally: push inherits HOME/PATH and credential-helper variables, allowing
only GIT_ASKPASS among inherited GIT_* variables, and disables terminal prompts.
Repository/config/transport overrides stay stripped. Push has a 120-second limit,
never retries or forces a rejection, and reports fixed error kinds. Remote URLs,
credentials, paths, file contents and commit messages never enter Git activity
payloads; branch UI retains only the remote host. A failed push after a successful
commit preserves the local commit for a later explicit Push.

Local chat now follows D33: sandboxed opencode with Ollama, with the tool-free
AgentLoop adapter used only when opencode is not installed. The former
Codex-on-Ollama candidate and its environment switch have been removed.

## D32 — Chat opens the unified composer; every new chat has a project ✅ (2026-11-06)

See [D34](#d34--project-agent-setup--2026-11-17) for the setup entry in existing chats, command hints and conversation actions.

The Chat tab follows the Claude and Codex desktop apps. With no chat selected,
or after New Chat, it shows an empty unified transcript and a ready composer.
There is no creation dialog, Create/Cancel pair, project-less new chat or automatic
catch-all workspace. First Send creates the record; abandoned drafts leave none.

The composer's flat project menu (`chat.project`) preselects an explicitly requested
project, then the optional default project, then the most recently used visible
project. Its final item, “Add project…”, opens the folder picker. With no projects,
it reads “Choose project”, Send is disabled and one short line explains why. Git
projects offer a small worktree control beside the picker, off by default.

Default project is a profile-local, initially unset choice, changed through a
project row's “Set as default” / “Remove as default” context item and indicated by
a small marker. Removing or hiding that project silently clears the choice.

Projects and chats live together in the sidebar. A chat opens with one click,
including across projects, retains a clear selection highlight and cannot be hidden
by collapsing its project. Each project shows its five most recently active chats,
plus every running or waiting chat; older chats are behind “Show more” / “Show less”.
The selected chat also stays visible. A project's + opens its unsaved composer.
Old conversations without projects remain readable in `LocalChatView`, exclusively
through the bottom “Earlier chats” group, collapsed behind its own “Show more” and
absent when empty. Existing voice and companion paths remain supported.

One accessible icon per chat derives from the M3.12 state: animated running,
accent-coloured and prominent needs-you (approval, plan or question), filled dot for
completed but unseen, failed or interrupted. Idle/seen has no icon. A profile-local
read receipt identifies the last completed turn seen; opening a chat clears its dot,
and completion while visible is acknowledged immediately. The main Chat icon has
an accent badge whenever any chat needs the person.

New chats use the last profile chosen or sent with (one implicit choice for
Codex and Local). The composer shows up to three recent profile/provider
segments, with order frozen until another chat opens, plus one flat More menu
listing every choice grouped by provider and its sign-in state. Control-Command
1–9 select menu entries in that order; Edit profiles opens AI providers. Claude
profiles can be added, edited, reordered and deleted there, with separate login
status and observed usage. New profiles default to Opus (newest), Medium effort.
Deleting an additional profile retains chats, native history and CLI credentials;
its chats fall back to default Claude on their next send. Switching Claude
profiles is the same acknowledged catch-up as switching providers (D30/D31).
A fresh app profile starts on
Local, except when no local model is available and an installed, signed-in provider
exists. Signed-out providers remain selectable; the composer immediately shows
the single inline sign-in action and disables Send while the selected profile is
known to be signed out. Sign-in failures discovered during Send retain safe retry.
Setup includes a visible “AI providers” card
(`settings.providers`) opening `AgentProviderSettingsView`. Section 4 of the unified
chat plan still governs gauges, icons, flat menus and the absence of start buttons
and checkboxes.

Chat's composer and transcript share a centred column. The composer is one rounded
card with input above a fixed control row: attach, project, provider, model, effort,
mode; then reserved gauge slots and Send/Stop on the right. Send remains beside
Stop whenever there is input, using the existing follow-up delivery. At narrow
widths the provider segments collapse to a menu, then the project becomes an
icon menu, then effort and mode become icon menus. Controls stay on one row
without scrolling. Changes opens only
from the toolbar's changed-file count (`chat.changes`), never automatically.
Gauges use a static full track and a small percentage number. Unsupported controls
and unknown gauges reserve space without drawing empty controls. Accepted input
leaves the composer as soon as its transcript entry and delivery journal are saved,
including when provider startup subsequently requires sign-in. Sign-in retries
restore that saved input, never the current draft. Restored chat/provider settings
are checked against the cached provider catalog on selection and before Send.

On Chat, the activity dock appears only while automatic work is actually running;
manual chat/provider failures remain inline and do not add dock attention. Other
tabs retain their activity presentation. The dock reserves real layout height so
native split views cannot draw the composer or error actions underneath it.

## D33 — Local uses sandboxed opencode and Ollama ✅ (2026-11-07)

See [D34](#d34--project-agent-setup--2026-11-17) for opt-in stdio MCP and MCP-revision reuse checks within this unchanged sandbox.

Owner decision: Local must use an open source agent harness and keep file
processing on this Mac. opencode (MIT) supplies tools, editing, context and
permissions; building and maintaining another agent harness was rejected.
Local no longer launches Codex or any OpenAI CLI. There is no cloud-provider,
API-key or subscription fallback when Local is selected.

Aitvaras launches one on-demand `opencode serve` process per profile through
`StreamingProcess`, under a generated macOS `sandbox-exec` policy. Network is
restricted to loopback, including descendants. Writes are limited to the chat's
project folders (including its worktree and additional roots), isolated
opencode XDG/home directories under `AitvarasPaths`, and the temp directory.
The normal opencode home/config/plugins are not inherited; project config and
external skills are disabled. Config admits only Ollama at loopback, disables
sharing and auto-update, and starts with tool permissions asking, except denied
web search and question tools. The startup HTTP password is transient memory used only for Basic authentication;
it never becomes a transcript event, diagnostic, DB value or activity field.

A live server cannot acquire additional write roots. A different folder set
restarts it only when its sessions are idle; conflicting active requests fail
inline. Idle sessions resume from the same isolated data store. This keeps one
server per profile without widening authority across simultaneous chats.
Shutting down the final run, backend or app terminates the isolated process group,
including the sandbox wrapper and descendants: SIGTERM, then SIGKILL after two
seconds. A PID file in the isolated data directory supports startup recovery;
stale cleanup verifies an opencode serve process and its owned group before
signalling. Native sessions remain resumable after the server stops.

Ask requires approval for shell and edits. Accept Edits and Auto permit typed
reversible edits through the audited coordinator; shell remains confirmable in
all modes. Read permissions pass policy and are audited automatically. Plan
denies shell and edits (a shell command cannot be proved read-only from text).
Web search is off; web fetch has an Ask permission but remote network requests
are blocked by the sandbox. The question tool is denied in generated config and
session permissions; Local asks questions in plain text. The tested form adapter
remains defensive support for unexpected native forms. Unsupported blocking
permissions, forms or questions are cancelled or interrupted with a visible
“Not supported here” line. Informational events, including instructions, inbox,
usage, project/plugin updates and unknown non-blocking events, never cancel a turn.
Local currently has no native plan cards, attachments, slash commands, file
completion or effort control.

Installed models are discovered from Ollama's loopback `/api/tags`, without
loading/pulling weights. Remote/cloud model metadata is excluded. Missing
Ollama or no eligible model reports unavailable. Missing opencode selects the
existing text-only AgentLoop, and Providers says “Install opencode for tools”
with the reason; there is no installer/download action. Errors after opencode
selection fail visibly instead of selecting a different backend.

opencode sessions persist native IDs and participate in the same acknowledged,
revision-aware 16,000-byte catch-up as Claude and Codex, into and out of Local.
This amends D30/D31's stateless Local rule only for opencode; text-only Local
still reads completed context each turn. Changing providers sends nothing;
Send authorizes that chat's catch-up. Native opencode history reconciliation is
not advertised; the Aitvaras transcript remains authoritative.

Host recordings from opencode 2.2.6 establish the HTTP/SSE protocol, Allow,
Reject and Stop with a local model under a sandbox. They do not establish
unified-app acceptance, the exact generated isolation config, model reliability
or memory/voice coexistence. Host self-drive and manual sandbox-denial checks
remain required. Exposing Aitvaras knowledge through a policy-gated MCP server
is an open follow-up; it is not available to opencode in this batch.

## D34 — Project agent setup 🚧 (2026-11-17)

Project Chat discovers the setup defined by any project folder. Claude's
`system/init` reports MCP servers, their source and connection status, skills
and agents; its command names are merged with the richer `initialize` catalog,
including argument hints. Setup probes send the read-only `mcp_status` control
request after `initialize`, because init is not emitted until the first user
message. This discovers MCP connection status without sending a prompt; refresh
reuses a healthy matching chat transport when available. Only name, status and
source are projected from `mcpServers`; `config` and other raw server metadata
are discarded and never logged or persisted. These snapshots stay outside the transcript and
handover context. Hooks and scoped rules have no CLI listing: Aitvaras reads
user settings, `.claude/settings{,.local}.json` and `.claude/rules/` for display
only. The CLI remains responsible for applying project instructions, rules,
skills, permissions and hooks. This changes interactive Chat, not D14's four
restricted non-chat CLI features.

MCP has three layers, resolved per run: app-global definitions, app-project
definitions and the repo's `.mcp.json`. A project can switch off a global
server, and project definitions override globals with the same name. An
app/repo name collision fails visibly. Claude still loads its own user/account
configuration; Aitvaras never writes that configuration or the repo.

Claude `-p` loads repo MCP servers without an approval dialog. Every launch,
including catalog probes, therefore reads every `.mcp.json` from its actual cwd
up to the filesystem root, using bounded descriptor-relative reads without
following file symlinks. Setup labels each server with its relative source file(s).
A name defined with different raw objects in several files is never approvable
and shows “defined differently in several .mcp.json files”. Every launch passes
`--settings` with `disabledMcpjsonServers` for every unsupported,
denied, new or changed server. Approval is project-scoped and bound to a
SHA-256 fingerprint of the whole raw server object as canonical JSON with
sorted keys, including unknown options. Unknown top-level keys are ignored;
invalid typed fields leave that server listed as unsupported without hiding
valid siblings. Duplicate object keys at any depth are rejected before Foundation
parsing, comparing decoded UTF-8 bytes (including escaped keys). Server names
must be plain ASCII matching the existing name grammar, preventing NFC/NFD key
merging. A name alone never approves a server, and denial wins.

A missing `.mcp.json` is normal. An unreadable, non-regular, oversized or
unparseable file anywhere on that path, or one without an `mcpServers` object,
produces a visible unreadable state. Claude then receives `--strict-mcp-config`
with only app servers, keeping repo servers off. Ordinary launches omit that flag and use
`disabledMcpjsonServers`, never `enabledMcpjsonServers`. There remains a race
between Aitvaras's fresh read and the CLI's later read: a repo change during
that window is not an atomic approved snapshot. Fingerprints and reuse
revisions detect changes on the next launch; they do not eliminate this window.
As defence in depth, each Claude `system/init` is checked against the approved
project server set. An unexpected `source: project` server stops the run before
any tool request is processed, with a fixed visible error and metadata-only audit.
This name check cannot detect a same-name definition changed inside the read race.

App-added servers are passed with `--mcp-config` only when present. Each run
owns `<state>/Runtime/mcp/<project>/<run>.json`, created with mode 0600 in
private directories. Claude removes it as soon as `system/init` arrives, retaining
only an in-memory redaction cache for later diagnostics; startup failure and
cancellation also remove it. A startup sweep runs before any backend starts and
removes crash leftovers using `openat`/`O_NOFOLLOW`, only inside private owned
directories and only regular files with runtime UUID names. Stored definitions
contain Keychain references restricted to `agent.mcp.<UUID>`; decoding, saving,
runtime validation and the App resolver all enforce that namespace. Removing an
app-added server deletes its MCP-owned Keychain items only when no other stored
global or project definition references them; other Keychain accounts are never
resolved or removed. The App injects the profile-scoped Keychain resolver;
Agents has no Store dependency. Resolved secrets enter only the transient runtime
configuration, never stored rows, session configuration, logs or audit payloads.
Definition hashes use reference names, never resolved values. Runtime file creation and
cleanup pass policy and metadata-only audit. Retained transports are reused
only with a matching setup revision.

MCP OAuth credentials remain in the provider CLI's own credential store,
like its account login. Aitvaras never reads or stores those tokens; this is
not an exception to the Keychain rule for secrets Aitvaras holds. Claude
sign-in runs a managed `claude mcp login -- <name>` in the project directory,
with cancellation and a five-minute limit. Its validated browser URL is
transient. That command cannot receive the run's injected settings/config,
so sign-in is offered for eligible repo and user/account servers; runtime-only
app servers show a fixed unavailable reason. There is no Terminal fallback.
Codex reports paginated `mcpServerStatus/list` and threadless startup updates,
and uses `mcpServer/oauth/login` plus `mcpServer/oauthLogin/completed` for
sign-in. Setup refreshes after sign-in. Per-project Codex MCP configuration,
Codex hooks and Codex forks remain out of scope.

The project permission source defaults to **Repo settings**: the repo's allow
and deny rules apply. **Aitvaras policy** ignores repo allow rules by returning
PreToolUse `permissionDecision: "ask"` whenever Aitvaras's current mode requires
approval. Reads continue; reversible writes continue in Accept Edits and Auto
and ask in Ask and Plan. Confirmable tools ask except in Auto, which retains
the existing native Auto behavior; any native permission request still passes
the coordinator. Mode changes apply during the session. Repo deny rules and
hooks still apply under both sources. `--setting-sources user` was rejected
because it also removes project instructions, skills and `.mcp.json`.

All tool actions retain the autonomy policy and activity provenance. Exact
built-in `ToolSearch` is a read so deferred MCP discovery can proceed. MCP
cards display `server · tool` while retaining the wire name. “Always allow in
this project” stores an audited exact grant, with no wildcards. MCP grants use
`provider.tool@fingerprint`, require one unambiguous current server definition and stop
matching when its approval or definition changes. Old unbound MCP grants never
match. Shell/command-execution tools cannot offer or honour grants. MCP names
containing send, reply, forward, compose, draft, post or publish (case-insensitive)
always ask and never offer a grant. The D20 forbidden-name guard runs first and
cannot be bypassed by a grant;
forbidden tools never offer this action. A grant answers the native permission
request, rather than changing the PreToolUse decision.

Local MCP is off by default and opt-in per project. Only stdio servers are
translated into opencode configuration. Its 0600 runtime file remains for the
server's lifetime and is readable by Local tools because the sandbox permits
reads; Local MCP is explicitly opt-in. It is removed at server shutdown or by
the next startup sweep after a crash. Remote transports show “Local: stdio
servers only”; repo options that cannot be translated also show a fixed unavailable reason. The loopback network and
write-root sandbox in D33 is unchanged, including for MCP descendants. Local
tools retain the existing audited permission path. Server reuse also checks
the MCP revision. Exposing Aitvaras knowledge as an MCP server remains open.

Agent setup lives in `WorkspaceBoundaryReviewView`, reachable through the
composer's project menu even when project switching is disabled for an existing
chat. Connections holds the global server list. Server actions use flat menus;
connection state uses accessible indicators, and Local opt-in is a switch.
Hook/rule metadata is read-only. Setup refreshes at chat startup and with
“Check now”. Command catalogs refresh on project changes,
and a picked command's argument hint appears in the composer. Approved repo
servers with unreported status say “Approved — starts with the next chat” and
offer Revoke approval, which removes approval without adding a denial. Setup
orders servers, permission source, hooks, rules, then compact one-line commands
with full descriptions in tooltips. Project is expanded by default; User,
Plugin, Built-in and Other are collapsed. When CLI source metadata is absent,
display grouping matches names against project `.claude/skills/*/SKILL.md` and
`.claude/commands/*.md`, then the user CLI home's `skills/` and `commands/`
(`CLAUDE_CONFIG_DIR`, otherwise `~/.claude`). This reads names and file metadata,
never skill or command contents. Namespaced plugin commands and exact known CLI
built-ins get their respective groups; remaining names stay Other. These hints
never discover executable commands or override the CLI's reported source.

New/default Claude choices use the CLI's `opus` alias, displayed as “Opus
(newest)”, with Medium effort. Existing explicit models and effort choices are
preserved; stored “Default (recommended)” choices move to this default. Setup
probes and side questions use the same fallback.

Claude folds user lines written during a running turn into one native result.
A normal result completes every input already written, acknowledges each journal,
and attributes the answer to the latest input; no queued input is left running.
Stop retains uncertain delivery evidence and disposes a queued Claude transport;
only the next explicit Send resumes its native session.
Native slash-command envelopes render as the command name and arguments.
Programmatic composer insertions leave an empty selection at the end; quote
replies end with a newline. Return accepts the highlighted completion, several
rows remain visible, and `/btw` is an explicit Aitvaras composer command. Command
search ranks name prefixes, name substrings, then descriptions, alphabetically
within each tier.
Assistant selection views have no intrinsic width and use the proposed
transcript width on every measurement, including after completion and resize.

Claude launches include hook events. PreToolUse hooks without a tool-use ID
start on the earliest same-name tool without a real result or a completed Pre
hook. All starts in that batch stay together. An interleaved next-tool start
closes the previous Pre batch; sequential configured hooks can stay on the
current unfinished tool when no next eligible tool waits. PostToolUse matches
the most recent unfinished tool, then the most recently finished match. The
first observation pins `hook_id` to that tool, so overlapping same-name tools
cannot steal responses. Tool payloads persist a `hooks` array in observation
order with id, name, event, status and an optional short reason. Exit 2 or a
block/deny decision is blocked; other nonzero exits/errors are failed. Reasons
use redacted stderr or structured decision reasons, one line capped at 240
UTF-8 bytes, never full output. Unknown responses and unmatched starts keep
standalone rows; unknown informational system events are ignored.
Real successful tool results supersede hook-derived denied/error flags in
either arrival order, while the hook outcome and reason remain in history.

Matched hooks appear as status icons beside the tool label. Block reasons
remain visible on the collapsed row; all hook details use the tool's existing
disclosure, without another popover. Unmatched rows keep their existing UI.

Claude **Fork from here** creates a chat in the same project with
`--resume <sid> --fork-session --resume-session-at <assistant uuid>`. It records
the fork origin and binds a distinct native identity on first Send. **Edit &
resend** forks before the user message at its preceding assistant message;
editing the first user message creates a fresh chat. Forks require an idle
source. A source worktree produces a separately owned worktree from its
committed branch tip. Fork from here and Edit & resend refuse a dirty source
worktree before creating a chat, with “Commit or discard the changes in this
chat's worktree first”. Worktrees are never shared between chats. All providers
support **Reply with quote** from a
read-only native text selection (whole-message fallback), and **Add to message**
from selected diff lines. Diff context includes the path, fenced snippet and
new-file line range, using old-file numbers for removed-only selections.
Shift-click and dragging extend from an anchor within one hunk/file. Added and
context lines quote file text without diff markers; removed lines are omitted
unless the entire selection is removed-only, when their `-` markers are kept.

Native `/btw` is unavailable headless and writes to the session. Side questions
instead use a separate ephemeral Claude fork with `--resume <sid>
--fork-session --no-session-persistence --tools ""`,
`--settings '{"disableAllHooks":true}'` and `--strict-mcp-config` with no MCP
config. Tools, hooks and MCP are off. One bounded prompt treats the question
as quoted text so it cannot expand a slash or shell command. The dismissible
answer panel cancels on dismissal; the operation has a bounded timeout and is
Claude-only. Question and answer never enter chat state, transcript, journal,
activity payloads or a native session file. A metadata-only activity event
retains chat provenance without either text.

**Verification boundary:** a real Claude CLI 2.1.300 check verified that the
ephemeral side question answers from resumed context and leaves no session
file. Hand-written fixtures establish offline protocol and failure behavior;
they do not prove browser completion or UI acceptance. D34 remains 🚧 until
the full isolated-profile live checklist in [TESTING.md](TESTING.md#project-agent-setup-d34)
is complete, including MCP sign-in with the user in the browser.

## D35 — Native selectable Markdown and math in Chat ✅ (2026-11-18)

All message bodies, plans and side answers share one TextKit renderer. Exact
SwiftPM dependencies are `swift-markdown` **0.7.3** (Apache-2.0 with the Swift
runtime exception) and `SwiftMath` **1.7.3** (MIT); the resolved transitive
`swift-cmark` **0.9.0** uses BSD and bundled permissive notices. SwiftMath ships
its unmodified offline font bundle, including Latin Modern Math under the GUST
Font License and other fonts under SIL OFL; distribution notices are bundled
in `ChatThirdPartyNotices.txt` and the dependency's resource bundle.

CommonMark/GFM becomes native attributed text and tables, with LaTeX as inline
baseline-aligned or display attachments. Invalid, incomplete, excessively deep
or oversized math remains literal monospace source. HTML stays visible text;
images become browser links and never load. HTTP/HTTPS/mailto links open only
on an explicit click. Native system colors follow appearance changes.

A single text storage per message keeps selection continuous across formatting,
code, tables and math without a web process per message. Source spans recover
Markdown for Copy and Reply with quote; Fork retains its existing anchor and
eligibility. Code stays in that text storage, with native copy controls and
horizontal scrollers rather than nested editors. The proposed transcript width
always controls prose and table layout. Complete top-level blocks and their math
attachments survive appends; only the open tail is parsed and replaced. Edits,
appearance changes and reference definitions invalidate the necessary prefix.
Host profiling and native interaction checks remain required for long chats.

The existing vertical composer keeps its selection binding and draft-edit path.
Shift/Option-Return replace the selection with a newline; plain Return accepts
an open completion or sends. Marked text defers Return to the input method.

## D36 — Home attention dismissal and recovery 🚧 (2026-11-18)

Home shows at most five attention rows in Decisions, Problems, Notices order,
with approvals first and one “N more” link into History's attention mode for
all remaining kinds. Agent permission requests use the same full approval
card as Chat (every detail line, the reason, Allow/Deny and Always allow);
plan approvals and question forms stay in Chat. Tool suggestions have labeled
Approve and Reject buttons. Neither has a ✕ or Undo, and rejection keeps the
existing policy and audit paths. Captures waiting to be saved have Save/Open
actions only.

Dismiss all acknowledges failed/interrupted problems, dismisses held updates
and defers the automatic-work review prompt. It skips approvals, unsaved
captures, every `outcomeUnknown` run and the monitoring error. A problem's own
accessible ✕ sets `acknowledgedAt`; for an unknown outcome this counts as
review, never retry or reversal. A monitoring incident's ✕ hides only that
Home warning, without clearing the failure or resuming automatic work.
“Later” persistently removes the review prompt from Home while keeping
Settings → Automatic Work available and the unreviewed policy closed.

Single ✕ and Dismiss all offer an inline “Dismissed N items · Undo” bar for
about eight seconds; ⌘Z undoes while the bar is visible. Undo conditionally
restores only that action's unchanged state, never consumed/expired updates
or problems already recovered by a later success. Activity runs and their
original outcomes always remain in History.

Only background job owners receive an optional explicit `jobKey`: startup,
consolidation, indexing, conversation archiving, capture summary/refinement,
model preparation/download, routines, queued delivery and keyed background
problems. The operation and stable subject identify the job, not its title.
Failed/interrupted runs group by key with a count; a group's ✕ acknowledges
all represented runs. A distinct successful run with the same key that started
after the failure finished clears it through a database query over persisted
evidence, without writing an automatic acknowledgement or using the recent-run
window. Unkeyed runs neither group nor auto-clear; unknown outcomes never
auto-clear. Chat responses and confirmed connector actions remain unkeyed.
Existing parent/child ownership stays intact; an unkeyed failed helper under a
keyed owner does not add its own Home row: the owner's row, or its recovery,
covers it, and the helper stays in the owner's details and History.

Held updates leave through ✕, Dismiss all, existing briefing consumption or a
fixed 24-hour expiry. Dismissal is soft during Undo, then deletes the held row;
expiry and consumption also delete with audit. Dismissed/expired rows cannot
enter a later briefing. Opening their source elsewhere does not clear them.

Operation details stay in a smaller resizable sheet: summary and main actions,
result and privacy fields, then one collapsed Details section including raw
JSON. Groups show the latest run and a short list of earlier failures.
Open conversation/capture closes the sheet before navigating. Retry is offered
only for failed capture summaries and safely identified stored-conversation
archives through their existing targeted paths; no other job gains Retry.
D36 stays 🚧 until the maintainer has reviewed the light/dark screenshots and
the person-only checks in [TESTING.md](TESTING.md#home-attention-d36-issue-18).

## D37 — Forge requests use installed CLIs 🚧 (2026-11-18)

Project Chat uses the already installed and signed-in `gh` (GitHub and
Enterprise) or `glab` (GitLab and self-hosted) CLI. Git push retains its Git
credential helper. There is no app account, token extraction, token storage or
API-key fallback. The origin hostname selects public forges; other hosts must
appear in exactly one CLI's authentication listing. Unknown hosts retain push
and show an unsupported-host message. A missing CLI shows an installation hint;
an installed, signed-out CLI offers a managed, cancellable browser sign-in.
Browser URLs pass `ProviderSignIn.validate`. Sign-in is never started on open.

Request creation is outbound and always requires a visible confirmation under
D13. The sheet previews editable commit-derived title/description, the default
base branch and a segmented Draft choice. A matching branch request is bound
instead of duplicated. Creation revalidates chat ownership, origin host/repository, branch,
base and committed tip. The CLI explicitly targets origin rather than choosing
an unrelated remote. Process output is bounded, commands time out, and failures
become fixed error kinds without retaining raw diagnostics. Audit includes
operation, chat provenance, risk and outcome; never titles, bodies or URLs.

One latest request identity is stored per chat. `watch` defaults to false.
Comments and checks are read-only, transient snapshots. Opening Chat, pushing
and manual refresh update request/check status. D40 covers opt-in forge polling.
The toolbar opens the request on the forge website. Merging stays there.
Connections lists installed CLIs and their signed-in hosts with sign-in fallback.
Offline fixtures establish parsing and policy behavior; live CLI/browser and
isolated app acceptance remain required before marking this decision complete.
## D38 — Chats show turns the CLI starts itself 🚧 (2026-11-18)

A retained official CLI may start a turn without a new Send, for example when
its wake-up fires or a background task completes. Chat gives that work a local
turn identity and persists its origin as user or autonomous, with the reason
wakeup, backgroundTask, monitor, scheduled or unknown. Existing turns remain
user turns. Autonomous turns have no user prompt and cannot be resent. Their
compact transcript marker replaces the injected CLI reminder; normal streaming,
usage, audited approvals, follow-up Send, Stop and crash recovery still apply.
Activity shows “Chat woke up” or “Background task finished”. A running autonomous
turn keeps its transport out of idle eviction; completion re-arms idle expiry.

Claude uses injected reminder markers when present, then the last scheduling,
monitor or background-shell tool observed in that process, otherwise unknown.
Reasons are descriptive provenance, never authorization. Native message UUIDs
and replay flags suppress replayed messages on resume. Codex opens a turn only
on an unsolicited turn/started for the bound thread and deduplicates completed
turn IDs. Autonomous requests retain the same policy and audit path as Send.

An unseen autonomous turn and its approvals mark that chat unread. Background
attention uses the existing generic requested-work notification and respects
Focus holds; no prompt or output enters a system notification. This batch only
observes work in a live retained transport. It adds no durable scheduler,
automatic restart, replay or catch-up after idle eviction or app shutdown.

## D39 — Wake-ups survive quit and restart 🚧 (2026-11-19)

Claude scheduling tool successes are mirrored as provider-neutral pending wakes
per chat/session and transport generation. Replayed history creates none.
Wake-ups and five-field numeric cron schedules survive transport eviction,
quit and restart. Background shell tasks and monitors retain their process but
cannot be restored: disposal drops their records with a metadata-only Activity
note. Archiving/deleting a chat clears its pending wakes.

A live creating transport owns its timers. Pending items prevent idle eviction;
at the eight-transport cap, idle slots with the latest next fire are evicted
first (slots without timed wakes first, oldest use breaks ties). Disposal
transfers timers to the app. A wake more than 120 seconds overdue transfers
only after retiring its idle native owner. Busy chats defer until a later tick.
The app checks on launch, system wake and every 30 seconds; no daemon or login
item runs while Aitvaras is closed. Missed cron slots collapse to one check,
then reschedule strictly after the catch-up time in the device's time zone.

Activity's Chat wake-ups feature controls app catch-ups. Unlike the other
background features it is on by default, without the one-time review (owner,
2026-11-19): it only continues work a chat already scheduled. Switching it off
(stored as a declined feature) or pausing all automatic work stops catch-ups and
leaves pending work intact; timers inside a live
CLI continue independently. The clock badge lists all pending items and permits
cancelling only unclaimed app-owned records, without killing native transports.

Claims are atomic and carry a turn identity. App-authored autonomous inputs use
the ordinary audited delivery/approval path and native resume, with a fixed
scheduled-wake prefix and no user bubble. Their prompt is kept in the turn
record, separate from user prompts; autonomous turns cannot be resent. Activity
shows “Chat woke up (late)”. Catch-ups use the creating session and profile even
if the composer has since selected another profile; that selection is unchanged.
One unavailable chat does not prevent other due chats from waking.
On crash recovery, claims with no delivery attempt
are released; delivery-unknown/acknowledged claims are consumed rather than
resent, because the CLI may already have acted. This chooses no duplicate side
effects over retrying uncertain delivery. Unsupported cron syntax is not guessed.
Codex can receive app-authored autonomous input but currently produces no timers.

Offline tests cover protocol and store behavior. Live Haiku checks and isolated
app acceptance remain required before marking D39 complete.

## D40 — Pull request Auto-fix 🚧 (2026-11-19)

An open or draft pull request can be watched from its chat's PR bar after
forge sign-in. The switch is off by default. Enabling it records the newest
comment time and IDs at that time, along with the initial conflict state.
An already-failing check can trigger once. The Activity feature is on by
default and can be declined or paused. The app checks at launch, after
system wake and on a 60-second loop. Archived chats are skipped. Forge
errors back off per request and appear in the chat's existing forge error
line.

The watcher batches newly failing checks, transitions into merge conflict,
and new discussion or reviews into one autonomous turn in the owning chat.
Busy chats defer without changing their cursors. The local checkout must
track the request's source branch on origin. Log excerpts and comments are
bounded and escaped inside the prompt's untrusted-data fences. Aitvaras
keeps the marker and turn metadata in its journal. The watcher uses forge
reads only. The turn uses the ordinary chat approval policy for
working-tree changes and commands, including push. Merging stays on the
forge website.

The watermark comparison, watermark advance and delivery-unknown journal
transition commit in one transaction at the provider write barrier.
Pre-delivery failures leave events available. Uncertain deliveries are
consumed. The turn journal accepts the new reason through v41. The watch
cursors use the existing request columns. Three turns without entering an
all-passing check state, or six turns in a rolling hour, turn off the
switch and raise attention. A merged
or closed request stops watching and records the outcome. Watch transitions
and the turn's Activity mirror contain metadata only. A new opt-in starts
a fresh watch and baselines the discussion again.

## D41 — Continue once after a provider usage reset ✅ (2026-11-18)

An eligible usage-limit Stopped row offers “Auto-continue when the limit resets”,
checked by default. Unchecking cancels the pending continuation. Checking it
again re-arms the same eligible stop. The row shows the reset time or that
Aitvaras is checking for it. “Keep Mac awake until it continues” defaults off
and appears directly below the first choice. Manual Continue remains available
through the existing recovery action. A usage-limit row with an unknown
provider account explains why automatic continuation is unavailable.
The saved row choice authorizes one bounded continuation through the existing
policy/action coordinator; it never grants approval to subsequent tools.

The continuation sends exactly “Continue where you stopped.” to the failed
turn's native session and provider profile. Aitvaras shows “Continued automatically
after the usage reset”, never a user bubble. Native-history reconciliation must
recognize only the exact recorded automatic input, not matching user-authored text.
Any valid new-message submission in that chat cancels the pending intent, even
if subsequent provider startup fails. A later usage stop gets fresh defaults.

Reset evidence comes first from the failing request's hit window, then the last
relevant observation for that provider account/profile. Both sides of an
account match must be known. Persist only a lowercase hex SHA-256 key over
the provider, profile and provider account ID, framed as a JSON array. Raw
account IDs are transient and never appear in the database, activity or logs.
Codex also polls its
CLI's account/rateLimits/read every ten minutes while waiting, without a model
prompt. With no usable reset, retry intervals are five, ten, twenty, then thirty
minutes repeatedly: elapsed minutes 5, 15, 35, 65, and so on. This fallback ends
after twelve hours; definite quota rejections may advance the same intent.
Unknown delivery is never automatically replayed. A successful continuation
consumes the intent; a later usage stop creates a new one.

Pending work and both choices survive quit/sleep. Launch and NSWorkspace didWake
re-evaluate it, requiring the choice still on, no intervening chat input, and a
known reset less than twenty-four hours old. Missing/deleted profiles or changed
native-session identity never redirect execution. Scheduled, cancelled, fired
and expired transitions are durably audited with provenance and metadata only.

An optional idle-system-sleep IOPMAssertion is held only while eligible work is
pending and AC power is positively known, and is released on battery/unknown
power, firing, cancellation, expiry, loss of profile eligibility or shutdown. It does not override normal
closed-lid sleep without an external display, wake a sleeping Mac, or survive
app termination. Wake alarms remain outside this feature (issue #28).

The app starts the scheduler after journal recovery. Only verified usage-limit
stops can arm it. Offline fake-provider and clock tests spend no usage. Any
later live check uses Haiku or the smallest available Codex model.
