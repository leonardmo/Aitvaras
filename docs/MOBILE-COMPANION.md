# Mobile companion and multi-device Aitvaras

> Historical architecture proposal. [`WORK-HUB-PLAN.md`](WORK-HUB-PLAN.md)
> supersedes the Android-first delivery order and relay-only/server-later scope.
> The current direction is Mac capture first, then shared work context, server
> coordination plus explicitly authorized workers, then a PWA before native Android.
> The task/event/privacy ideas below remain background; a relay and a plaintext
> execution worker are distinct trust roles, not interchangeable components.

**Status:** future architecture proposal, not an implementation decision  
**First target:** Android, because that is the mobile platform currently
available for testing  
**Last reviewed:** 2026-07-24

## Product goal

Extend Aitvaras from one intelligent Mac into a small network of independently
useful, local-first devices:

- the phone remains useful without a network;
- the Mac keeps authority over Mac-only data and actions;
- tasks can begin on one device and finish on another;
- an optional always-on service makes delivery reliable while the MacBook is
  closed;
- adding a server must not turn Aitvaras into a server-dependent gateway or
  silently move personal data out of local control.

The first mobile version should be a **companion**, not a feature-for-feature
port. Its strongest jobs are fast voice/text capture, notifications, camera
input, lightweight local reasoning, task review and receiving results from
other Aitvaras devices.

## Recommended shape

```text
┌──────────────────────────┐
│ Android companion        │
│ local DB + small model   │
│ voice/camera/phone tools │
└────────────┬─────────────┘
             │ encrypted task/event sync
             ▼
┌──────────────────────────┐       optional, always available
│ Aitvaras relay           │◄────────────────────────────────┐
│ delivery + queue only    │                                 │
│ no assistant authority   │                                 │
└────────────┬─────────────┘                                 │
             │ encrypted task/event sync                     │
             ▼                                               │
┌──────────────────────────┐                                 │
│ macOS Aitvaras           │─────────────────────────────────┘
│ local DB + larger models │
│ files/Mail/native tools  │
└──────────────────────────┘
```

Every device has its own local database, outbox and model runtime. The relay is
helpful for availability but is not required for local interaction.

## What should run where

| Capability | Phone | Mac | Relay |
|---|---:|---:|---:|
| Voice/text capture and short replies | Primary | Yes | No |
| Intent routing and task creation | Local small model | Local model | No |
| Camera/OCR and mobile notifications | Primary | No | No |
| Compact personal profile and task history | Local replica | Authoritative initially | Ciphertext only |
| Large Knowledge/RAG collections | Small selected subset later | Primary | No |
| Apple Mail, Mac files and desktop automation | No | Primary | No |
| Task delivery, presence and retry queue | Local outbox | Local outbox | Primary |
| Scheduled delivery while devices sleep | Android WorkManager | Existing scheduler | Queue/wake signal |
| Deep reasoning | Escalate when useful | Larger local model | No model initially |
| Claude/Codex work | Explicit existing policy | Explicit existing policy | Never implicitly |

The executor is selected from **required capabilities**, not merely from where
the user created the task. A phone can therefore create “summarize my lecture
notes”; it stays visibly queued until the Mac holding that Knowledge source is
available.

## Android local inference

### Recommended first runtime

Use the native Kotlin **LiteRT-LM** SDK behind an Aitvaras inference interface.
It currently supports Android CPU/GPU/NPU backends, streaming and tool use.
Do not couple application logic directly to one model or vendor runtime.

Initial model tiers to benchmark on the actual test phone:

1. **Gemma 3 1B, 4-bit (about 557 MB)** — preferred default for intent
   routing, structured task creation, classification, short summaries and
   brief chat.
2. **Qwen 2.5 1.5B (about 1.5 GB in the published LiteRT-LM build)** —
   multilingual alternative worth comparing for German/English behavior.
3. **Gemma 3n E2B, 4-bit (about 3 GB)** — optional quality/multimodal tier for
   high-end phones; substantially heavier and not the default download.
4. **FunctionGemma 270M (about 288 MB)** — promising dedicated tool router,
   but only after an Aitvaras-specific fine-tuning and evaluation set exists.

Gemini Nano through Android AICore/ML Kit can be an optional backend when the
device reports support. It must not be the only path because device coverage
and per-app quotas vary. `llama.cpp` remains a useful fallback for broad GGUF
model support, at the cost of more native integration and device-specific
performance work.

A 1B-class phone model is not expected to replace the Mac's larger reasoning
models. It should confidently perform bounded local work and route or queue
everything else.

Current implementation references:

- [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)
- [Gemma on mobile](https://ai.google.dev/gemma/docs/integrations/mobile)
- [Gemma 3n overview](https://ai.google.dev/gemma/docs/gemma-3n)
- [ML Kit GenAI and Gemini Nano device support](https://developers.google.com/ml-kit/genai)
- [`llama.cpp` Android integration](https://github.com/ggml-org/llama.cpp/blob/master/docs/android.md)

Re-benchmark model size, cold load, sustained generation, thermals, battery,
German/English quality and structured-output accuracy before choosing a
shipping default.

## Shared tasks: synchronize events, not databases

Do not replicate the macOS SQLite file. Each device owns its local store and
synchronizes a small, versioned, append-only protocol.

A shared task should contain at least:

- globally unique task and event IDs;
- origin device and creation time;
- user-visible request and result;
- required capabilities and preferred execution target;
- state: `queued`, `claimed`, `running`, `waitingForConfirmation`,
  `completed`, `failed` or `cancelled`;
- an idempotency key for every action;
- provenance from request → routing → tools → result;
- revision/causal metadata for conflict detection;
- expiry and retry policy;
- whether the payload may leave its origin device.

Important invariants:

- Only one device may hold an execution lease at a time.
- A repeated delivery never repeats a side effect.
- Confirmation is performed on a trusted user device and is bound to the
  exact proposed action.
- Offline creation succeeds locally first and enters an outbox.
- A queued task visibly explains what device or condition it is waiting for.
- Cancellation and completion are events, not destructive row replacement.

Start by sharing tasks, task results and device presence. Do **not** begin with
automatic full-memory replication. Later, explicitly selected facts or a
compact profile can use the same versioned event mechanism. Raw mail, files,
Knowledge documents and credentials remain on their owning device.

## Connection options

### 1. Direct device pairing

Pair phone and Mac with a QR code containing a one-time invitation and device
public key. Use mutually authenticated, encrypted connections on a trusted
LAN or private VPN. This is the simplest first prototype, but the Mac is
unreachable while asleep.

### 2. Optional Docker relay — recommended for reliable remote use

Add a small Docker Compose deployment only when remote delivery is needed. A
first version needs:

- one synchronization API/WebSocket service;
- a durable queue/event store;
- device registry and public keys;
- short-lived execution leases and acknowledgements;
- optional push adapter that sends an opaque “new encrypted work available”
  wake signal.

The relay should store encrypted payload envelopes and the minimum routing
metadata. It should not receive model prompts in plaintext, hold connector
credentials, execute personal tools or become the authoritative memory store.
A private VPN plus device-level cryptographic authentication is preferable to
exposing an Aitvaras API directly to the internet.

Without a push provider, Android can still synchronize on foreground use and
through WorkManager, but delivery will be opportunistic rather than instant.
WorkManager should drain a durable local outbox with network/battery
constraints and exponential retry; it is not an exact-time scheduler.

Reference:
[Android offline-first synchronization](https://developer.android.com/topic/architecture/data-layer/offline-first).

### 3. Server execution — deliberately later

The relay may eventually advertise narrowly scoped server capabilities, such
as a public-web fetch or a user-approved model hosted on the user's own
hardware. This must be an explicit third Aitvaras device with its own
capability and privacy disclosures—not an invisible expansion of the relay.

## MCP's role

MCP can provide a common description of tools offered by the Mac, phone or a
future server. It is not a suitable replacement for:

- durable offline task queues;
- device pairing and identity;
- synchronization/conflict resolution;
- execution leases and idempotency;
- result delivery and presence.

The multi-device protocol should therefore remain Aitvaras-owned. An MCP
adapter can sit at its capability boundary so external clients can call
approved Aitvaras tools without defining the internal synchronization model.

## Security and privacy boundaries

- Pair devices explicitly and support immediate revocation.
- Give every device its own signing/encryption key; never share one universal
  credential.
- Encrypt task payloads end to end when using a relay.
- Keep secrets in each platform's protected credential store.
- Advertise capabilities, not credentials or raw inventories.
- Preserve the existing risk policy and audit provenance on every executor.
- A relay outage must delay synchronization, never disable local use.
- A compromised phone must not automatically gain Mac filesystem/Mail access;
  capability grants are device-scoped and revocable.
- Remote content remains untrusted data regardless of which paired device
  delivered it.
- Clearly show “local on this phone”, “sent to Mac”, “stored encrypted on
  relay”, or “sent to selected cloud agent” before execution.

## Suggested delivery phases

### Phase A — Android-local prototype

- Kotlin/Compose shell with the companion character.
- Room-backed conversations, tasks and outbox.
- LiteRT-LM abstraction and a Gemma 3 1B baseline.
- Local text/voice interaction and constrained JSON task routing.
- Benchmark harness across the available Android hardware.

### Phase B — phone ↔ Mac

- Shared protocol types and compatibility/version negotiation.
- QR pairing, device keys and direct encrypted transport.
- Capability advertisements.
- Phone-originated task execution on the Mac with visible waiting state.
- Idempotency, cancellation, confirmations and provenance tests.

### Phase C — reliable relay

- Minimal Docker Compose relay and encrypted envelope store.
- Offline delivery, acknowledgements, retries and device presence.
- Foreground WebSocket plus Android WorkManager synchronization.
- Optional opaque Android push wake-up.

### Phase D — selective continuity

- Explicitly selected compact memory/profile synchronization.
- Small offline Knowledge packs.
- Handoff of an active conversation between devices.
- Optional server device with separately approved capabilities.

## Decisions to make after the prototype

- Which Android phone and memory/storage floor define support?
- Is Google push acceptable for opaque wake signals, or is opportunistic sync
  sufficient?
- Should the Mac remain the initial authority for shared facts, or should
  fact edits use a true multi-writer conflict model?
- Which capabilities may be granted to a paired phone by default?
- Does the relay run only on the user's infrastructure, or may an optional
  hosted relay exist later?
- Is a shared cross-platform inference runtime worth adopting on macOS, or
  should Android LiteRT-LM and macOS MLX remain behind the same interface?

## Acceptance criteria for an initial mobile release

- Core capture/chat/task review works in airplane mode.
- A queued phone task survives process death and device restart.
- A task reaches the Mac after it returns from sleep without duplicate work.
- A Mac-only action cannot execute on the phone or relay.
- A repeated message cannot repeat a side effect.
- Revoking either device prevents all new synchronization.
- Relay storage inspection reveals no task text, memory or credential.
- The UI always identifies where inference and execution happen.
- Battery, thermal and bilingual quality measurements support the chosen
  default model rather than relying on desktop benchmarks.

