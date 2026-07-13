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
- **Connectors** expose *typed* tools with declared risk levels (`read` / `reversibleWrite` / `confirmable`). AgentCore enforces D13 autonomy rules centrally — a connector can never bypass confirmation.
- **Events** (new mail, Moodle deadline, homelab alert) enter the same loop as user messages, tagged with provenance that follows every downstream action into the activity log.
- **VoicePipeline**: AVAudioEngine voice-processing I/O (echo cancellation) → SpeechAnalyzer streaming partials → end-of-turn VAD → agent streams → sentence-chunked TTS with barge-in cancellation.
- **Character states** (idle / listening / thinking / speaking, plus mood accents) are driven by a small state machine observing AgentCore + VoicePipeline; RealityKit animations subscribe to it.
- **Concurrency**: Swift 6 strict concurrency; engines and connectors are actors; UI observes via `@Observable` models.
