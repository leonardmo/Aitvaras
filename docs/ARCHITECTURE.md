# Architecture

## Layout

```
Aitvaras.xcodeproj            — app target (SwiftUI, RealityKit character, windows)
Package.swift              — AitvarasKit: everything testable without the app
  Sources/
    AitvarasCore/             — domain types, agent loop, activity log, memory
    AitvarasEngines/          — InferenceEngine impls: MLX, Ollama, AppleFM  (added in M1)
    AitvarasVoice/            — STT (SpeechAnalyzer), TTS engines, conversation loop (M2)
    AitvarasConnectors/       — Mail, Calendar, Reminders, Moodle, Homelab,
                             Telegram, Delegate (M3+)
    AitvarasRAG/              — indexer, chunkers, sqlite-vec store, retriever (M4)
```

## Core flow

```
                    ┌──────────────────────────────────────────┐
                    │                App (SwiftUI)              │
                    │  CompanionWindow (RealityKit character)   │
                    │  MainWindow (chat, activity, settings)    │
                    └───────▲──────────────────────▲───────────┘
                            │ state                │ transcript/audio
                    ┌───────┴───────┐      ┌───────┴───────┐
                    │  AgentCore    │◄─────│ VoicePipeline │
                    │  (orchestr.)  │      │ STT⇄VAD⇄TTS   │
                    └─▲───────────▲─┘      └───────────────┘
              tools   │           │  completions
        ┌─────────────┴──┐   ┌────┴────────────────┐
        │ ConnectorHub   │   │ InferenceEngines    │
        │ Mail Calendar  │   │ MLX (30B + 4B)      │
        │ Reminders      │   │ AppleFM  Ollama     │
        │ Moodle Homelab │   └─────────────────────┘
        │ News (read)    │
        │ Telegram       │
        │ Delegate(CLI)  │
        └───────┬────────┘
                │ events + provenance
        ┌───────┴────────────────────────┐
        │ Store (SQLite): activity log,  │
        │ memories, RAG vectors (vec+FTS)│
        └────────────────────────────────┘
```

## Key mechanics

- **AgentCore** runs the tool-use loop: user/voice/event input → context assembly (RAG retrieve + memories + activity) → model streams → typed tool calls into ConnectorHub → results back into the loop. Model choice per step: 4B/AppleFM for routing & triage, 30B for reasoning & conversation.
- **Connectors** expose *typed* tools with declared risk levels (`read` / `reversibleWrite` / `confirmable`). AgentCore enforces D13 autonomy rules centrally; a connector can never bypass confirmation.
- **CloudAgentService** is the single provider-neutral boundary for optional
  Claude Code and Codex CLI use. Authentication is checked before each call;
  prompts travel over stdin in a sanitized environment and always begin with
  the same versioned Aitvaras policy. Personal MCP servers, hooks, skills and
  CLI configuration are disabled. For non-delegation tasks Claude's tools are
  disabled, while Codex is read-only in an empty temporary workspace;
  delegated tasks receive only the confirmed workspace. Each feature
  independently selects Local, Claude, Codex or automatic Claude→Codex
  fallback. The selection is resolved when each call begins, so UI changes do
  not require reconstructing the agent loop or restarting the app.
- **Cloud feature boundaries** are explicit. Delegation sends the task plus
  files the confirmed agent reads in its workspace. Nightly memory sends
  bounded archived summaries and relevant facts, and falls back to the local
  background engine before the watermark can advance. Connector creation
  sends the description, URL and bounded public documentation fetched through
  the SSRF-safe web reader; no credentials. Routine review sends a bounded
  phrase/schedule/fixed tool path and may change presentation metadata only.
  A local metadata-only ledger records provider, feature, duration, declared
  data categories and available token/cost figures, never prompts or replies.
  The UI groups both monthly totals and recent call history per feature.
- **Local inference metering** wraps engines returned by `EngineRouter`. MLX
  generation metadata and Ollama final-stream counters provide exact token
  counts; engines without a usage API use a marked character-based estimate.
  The separate one-year ledger contains engine, role, duration, counts and
  success only—never conversation or tool content.
- **Nightly consolidation scheduling** treats the configured time as a local
  daily eligibility boundary, not an exact wake alarm. The default is
  automatic after 04:00: launch and macOS wake signals start a configurable
  settling delay, an adaptive timer runs at the resulting time, and a
  half-hour poll is the fallback. A durable successful-run watermark enforces
  one pass per boundary across restarts. Fixed-time and Off modes, battery
  threshold / plugged-in / always power policies, Run now, and visible
  last/next/waiting status are profile-scoped. Automatic failures remain in
  Activity and retry after 30 minutes without opening a synchronous prompt;
  curiosity questions stay queued in Memory for later.
- **Home Assistant** keeps its bearer token in the Keychain and base origin in
  local SQLite. Setup probes `/api/` before replacing a working connection,
  rejects cleartext non-local origins and follows no redirects. A dedicated
  adapter compacts/searches `/api/states`, omits location-like attributes, and
  exposes only validated, idempotent `light.*` on/off writes. Household entity
  names and ids are discovered at runtime and never appear in source fixtures.
  Health probes are cached; authentication/forbidden failures remain terminal
  until reconnect so the 15-second Connections refresh cannot trigger HA's
  persistent IP-ban threshold.
- **Events** (new mail, notifications, Moodle deadlines, custom triggers) enter a separate intake boundary. Unknown message senders are held before inference; configured-service payloads use tool-free triage; approved mail may enter only the context-free, two-tool external-message quarantine. Provenance follows every downstream proposal into the activity log.
- **Wake briefing**: `NSWorkspace` sleep/wake lifecycle events persist an exact
  sleep boundary in SQLite. After a meaningful sleep (≥5 minutes), Mail,
  enabled Notification Center reading and configured Moodle replay their
  missed windows through the same trust/dedup intake. Per-item presentation is
  suppressed during the batch; the companion receives one deterministic,
  count-only recap afterward. Lookback is capped at seven days, while the true
  away duration is retained; each source also has a 200-event ceiling that is
  disclosed in the recap if reached. Recap audit and boundary consumption are atomic
  and conditional on the exact sleep timestamp, so duplicate wake signals and
  sleep-again races cannot lose or repeat a period.
- **News feed**: a separate `NewsFeedService` fetches fixed RSS/Atom feeds plus
  a Google News RSS query per configured topic. Discovery is not authority:
  only an explicit publisher-domain catalogue is accepted, then deterministic
  source quality, relevance, freshness and cross-source similarity rank the
  result. `newsTopic` and `newsArticle` tables are bounded and foreign-keyed to
  each other only—there is intentionally no Activity event, conversation,
  memory, RAG or consolidation edge. The `news.*` connector is read-only and
  exposes delimited untrusted data to chat/voice; topic configuration remains
  UI-only. A scheduler silently refreshes due topics and may claim one local
  morning offer per day, while explicit commands can open the visual reader.
- **Command routines**: successful user-initiated tool paths containing at
  least one reversible write are stored as canonical tool name + argument
  sequences; outputs and model reasoning are excluded. Three consistent runs
  of one exact normalized phrase compile an active fast path. The voice and
  typed entry points check this matcher before `AgentLoop`, render a visible
  “no AI” banner, then execute through `ConnectorHub` with the current tool and
  risk metadata revalidated. A deterministic nightly/after-command scan may
  propose a clustered time trigger, but only an active user-approved schedule
  is evaluated by the local scheduler. Slot claiming happens before side
  effects, choosing a missed run over a duplicate after a crash. Optional
  cloud review occurs only after local derivation and safety checks; store
  methods accept a reviewed title/summary but expose no model-authored path,
  trigger, arguments, risk or activation fields.
- **Trusted senders** are local routing rules, never an instruction or authentication boundary. External-origin turns have no Memory/RAG/history/read tools; ConnectorHub permits only confirmation-gated `calendar.create_event` and `reminders.create_reminder`. See [MESSAGE-TRUST.md](MESSAGE-TRUST.md).
- **VoicePipeline**: AVAudioEngine voice-processing I/O (echo cancellation) → SpeechAnalyzer streaming partials → end-of-turn VAD → agent streams → sentence-chunked TTS with barge-in cancellation.
- **Character states** (idle / listening / thinking / speaking, plus mood accents) are driven by a small state machine observing AgentCore + VoicePipeline; RealityKit animations subscribe to it.
- **Concurrency**: Swift 6 strict concurrency; engines and connectors are actors; UI observes via `@Observable` models.
