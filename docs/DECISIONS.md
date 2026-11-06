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
- **Proxmox**: API token bound to a `PVEAuditor` (read-only) role.
- **TrueNAS**: REST/WebSocket API key; use a read-only role account where the SCALE version supports it.
- **Home Assistant**: long-lived access token on a dedicated non-admin user;
  verified API access, compact/searchable entity reads and exact idempotent
  `light.*` on/off are exposed (D28), with no arbitrary service calls. Plain
  HTTP is accepted only for local/private hosts; other origins require HTTPS.
- All tokens in macOS Keychain. No shell access anywhere—the LLM can only call
  typed endpoints; Proxmox/TrueNAS remain read-only and HA writes are limited
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

All CLI-backed features now share one provider-neutral boundary and the
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
- Proxmox and TrueNAS are bundled manifests on this engine. Home Assistant
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
Unapproved Apple Mail and macOS-notification senders are held before any model call, alert forwarding or agent work and appear in a local sender-review queue. Users may approve an exact mail address, an exact app+notification-label pair, or (after a warning) an exact non-consumer domain; shared mailbox domains such as `t-online.de` can only be approved address-by-address. Approval never authenticates a sender and never makes content instructions: approved external mail runs without Memory, RAG, history, web/mail/file/read tools and can only propose a new event or reminder, with mandatory confirmation enforced again in ConnectorHub. Configured Moodle/custom-service payloads remain untrusted but use the existing tool-free classifier. See `docs/MESSAGE-TRUST.md`.

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

SPIEGEL receives a small preference and SPIEGEL+ opens in the normal signed-in
browser—Aitvaras never copies browser cookies. X/Twitter is excluded until an
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
“Licht aus” can become a useful shortcut. Proxmox and TrueNAS remain read-only;
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

Replaces the adapter approach in `CLAUDE-INTEGRATION.md` and
`CODEX-BIDIRECTIONAL-INTEGRATION.md`; plan in `UNIFIED-CHAT-PLAN.md`. Chat runs
`claude` and `codex app-server` as subprocesses with their default login and
stores, so chats exist natively in those tools and there is no separate account
or link step. Child environments inherit the app's environment minus a denylist of
credential and endpoint overrides: the allowlist dropped `USER`, which pointed the
CLI at a stale credential item. The session start checks first-party subscription
status and refuses anything else. API keys stay forbidden.

Changing provider and pressing Send is the consent for sending that chat's earlier
messages to the provider (amends D30). Every provider action passes
`AgentActionCoordinator`, using Claude's pre-tool hook callback and Codex's sandbox,
approvals and item events, so the autonomy policy and activity log still hold.
Pending permission, plan and question cards wait without an automatic timeout,
matching the native CLIs. Answers, Stop, provider cancellation or resolution
(including turn end), and process exit clear them through the audited lifecycle.

The new chat path bounds each deterministic handover block, including labels, to
16,000 UTF-8 bytes. It keeps the newest completed messages, orders them
oldest first, states the omitted count (and explicitly clips an oversized newest
message at a Unicode character boundary) and advances the per-provider watermark
only on acknowledgement. Local receives completed context on every Send. Legacy
adapters retain their existing sharing checks until migration.

Native history refresh publishes a complete canonical branch atomically across
a chat's refreshed sessions, keyed by native message identity (turn and item
for Codex, persisted UUID for Claude). Streamed rows retain their display IDs;
removed branch messages are retired from the projection, with prior observations
and execution journals retained. Failed, partial or inconsistent reads keep the
last projection. A second complete observation checks for changes during refresh;
it does not reserve the native session against another client. Changed native
content evicts an idle run so the next Send resumes the updated native session.

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

Local chat continues to use the AgentLoop adapter by default. The explicit
`AITVARAS_LOCAL_CHAT_BACKEND=codex-oss` switch enables an M4 candidate using
`codex app-server` pinned to Ollama on loopback, with no subscription or cloud
fallback. It discovers installed model metadata without loading weights and
fails closed for missing service, implicit/cloud models or mismatched provider
evidence. Local remains stateless: each Send starts a fresh ephemeral thread
with completed chat context. The candidate advertises only its implemented
capabilities; the host gate decides tool reliability, locality and memory
before any default changes.

## D32 — Chat opens the unified composer; every new chat has a project ✅ (2026-11-06)

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

New chats use the last provider chosen or sent with. A fresh profile starts on
Local, except when no local model is available and an installed, signed-in provider
exists. Signed-out providers remain selectable; Send retains the existing single
sign-in action and safe retry. Setup includes a visible “AI providers” card
(`settings.providers`) opening `AgentProviderSettingsView`. Section 4 of the unified
chat plan still governs gauges, icons, flat menus and the absence of start buttons
and checkboxes.
