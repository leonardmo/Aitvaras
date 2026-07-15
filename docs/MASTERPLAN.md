# Master plan: a situational, learning Aitvaras

Status: **proposal** (2026-07-07). Nothing here is implemented, and nothing here is
decided, decisions get culled into `DECISIONS.md` (as D22+) and milestones into
`ROADMAP.md` once agreed. **Part I** answers: *what should Aitvaras become after v0.1,
and which context signals (location, weather, …) are actually worth adding?*
**Part II** (added the same day, research-grounded, full evidence reports in
`docs/research/`) answers: *how should Aitvaras remember, learn about the user, and
combine multiple models to get smarter over time?* The two multiply: Part I is
awareness of *now*, Part II is knowledge of *you*; judgment needs both.

---

# Part I: Situational awareness

## 1. Thesis

Aitvaras's ceiling is not model quality, it's **situational awareness**. v0.1 can
already read mail, triage notifications, manage the calendar and coach focus, but
every one of those judgments is made context-blind: the system prompt knows only
the clock (`PromptBuilder`), the mail classifier doesn't know whether you're in a
lecture or asleep, and the NotificationRouter's world model is a single boolean
(focus mode on/off).

The motivating example: a mail about a room change is urgent at 9:40 on the way to
campus and irrelevant on Saturday at home. Today's classifier cannot tell those
apart, not because the model is weak, but because nothing tells it where you are
or what comes next in your day.

So the plan is **not** "add a location feature, add a weather feature". It is:
build **one Situation Engine** that continuously answers *"what is the user's
situation right now?"*, and make every judgment Aitvaras already makes consume it.
New data sources are admitted as *signals* into that engine, under one rule:

> **Gimmick filter:** a signal earns its place only if it changes a decision Aitvaras
> already makes, a triage verdict, an interrupt-or-batch call, a briefing line, a
> trigger firing. A signal that only produces its own announcements is a widget,
> not awareness.

Corollary for a local app: prompt tokens are latency on a large local model. Signals
feed the engine; the engine emits a ~10-line situation block. Raw feeds never
enter the prompt.

### Operating principles

1. **Awareness before features.** One shared world model, many consumers: never
   per-feature sensor plumbing.
2. **Judgment over notification.** More data must mean *fewer, better*
   interruptions, not more.
3. **Restraint is the product.** Bounded interruptions, quiet hours, every
   proactive ping explainable ("why now"), briefings as the default sink.
   The trust statement to design toward: *"Aitvaras interrupts at most N times a
   day, and can always say why."*

## 2. The Situation Engine (the one new core component)

`SituationEngine`, an actor in `AitvarasCore` beside `AgentLoop`. Fuses cheap
signals into a compact, confidence-annotated snapshot:

```
Situation
├─ place          home | campus | commuting | elsewhere      (+ confidence, since)
├─ attention      activeAtMac(app) | meeting | focusSession |
│                 idleNearby | away | asleep
├─ nextCommitment event + place + slack
│                 ("Analysis, MI HS1, in 74 min, ~35 min travel")
├─ dayShape       deadlines <48h, goal progress, exam proximity
└─ environment    decision-relevant anomalies only
                  (disruption on usual line, rain at next departure)
```

Consumers, all of which exist today and are all currently blind:

1. **PromptBuilder**: one `# Current situation` block (≤10 lines) in the system
   prompt, so chat and voice answers are situated.
2. **Triage** (mail D5, notifications D21): the small-model classifier prompt
   gets the same block; urgency becomes *conditional* on situation.
3. **NotificationRouter**: interruption cost derived from `attention` instead of
   the focus-mode boolean (generalizes D19).
4. **Trigger engine**: situation *transitions* become `ConnectorEvent`s
   (`arrivedHome`, `leftCampus`, `meetingStarted`, `wokeUp`) usable by
   automation rules (M10).

Storage and transparency:

- **Transitions, not trails**: the store records "arrived campus 09:52 (HA zone)",
  never a coordinate log. FocusCoach's precedent holds, raw samples stay in
  memory, only aggregates/transitions persist.
- The current snapshot is always **visible in the UI** (status line / companion
  tooltip); clicking it shows which signals produced it, with per-signal toggles.
  Location, weather, transit are catalog "connections" per D18, addable,
  removable, off by default where they need permissions.

## 3. Signals: inventory and verdicts

Ordered by value-per-effort for a student workflow spanning university,
personal infrastructure and a laptop that regularly leaves home.

### 3.1 Presence & place: the core signal. Verdict: build first
- **Phone via Home Assistant**: the elegant path: HA already tracks the phone
  (`person.*`, zones for home/campus/gym) and Aitvaras already has a read-only HA
  manifest (D10/D17). One polling watch expression, **zero new permissions**, and
  it tracks *the user*, not the laptop. First source to build.
- **Mac-local signals** (free, no TCC): screen lock/unlock, idle time, frontmost
  app (FocusCoach already samples in sessions), **mic/camera in use by another
  app** (= in a call, the single strongest do-not-interrupt signal), power
  source + external display (= at desk), homelab reachable (= home network).
- **Wi-Fi SSID + geofences** (optional catalog connection): one Location Services
  grant unlocks both, SSID reads are location-gated since macOS 11. eduroam →
  campus, home SSID → home; `CLMonitor` geofences for the same two places. Off by
  default because HA covers most of it (see O2).
- **Calendar inference**: lecture in calendar + its time window ⇒ probably in it,
  even with no fresh location.
- **Fusion**: fixed source precedence with confidences; disagreeing sources lower
  confidence instead of flapping the state.
- **Sleep**: inferred (locked since >23:00, phone charging at home per HA).
  Gates quiet hours only, never produces announcements.

### 3.2 Day structure (calendar + Moodle + goals). Verdict: cheap, ship with M7
Already connected (D6, D9, D19) but pull-only. The engine computes: next
commitment + slack, deadline pressure over 48h, exam proximity. This is the
signal that turns the others from trivia into decisions.

### 3.3 Transit (MVG). Verdict: often worth more than weather
Munich reality: S-Bahn/U6 disruptions are a weekly event. MVG has a
well-known (unofficial but stable) departures/disruptions API, a pure D17
manifest, zero Swift. Consumed only by the transition advisor (F3) and briefings;
never a standing departure board.

### 3.4 Weather. Verdict: admitted as *input only*: demoted from feature
Your skepticism is correct: standalone weather is a widget the OS already has.
It survives the gimmick filter in exactly two places:
1. **Transition advisor**: rain/ice at departure time changes transport mode and
   leave-by time (bike vs U-Bahn).
2. **Briefing anomaly line**: only when it deviates from season-normal *and*
   intersects the day's plan (storm during your commute window; first frost).
Aitvaras never announces weather otherwise, no "nice day today".
Source: **Open-Meteo** bundled manifest (keyless, free, DWD ICON model, ideal
for Munich). WeatherKit would also work but adds an entitlement and an Apple
service dependency for no gain.

### 3.5 Mensa (TUM eat-api). Verdict: small, real, nearly free
Static JSON (github-hosted eat-api) as a bundled manifest. Surfaces exactly once:
on campus, ~11:00–13:00, in a briefing or on ask. Disproportionate daily utility
for a student; near-zero cost.

### 3.6 Rhythms: learned baselines. Verdict: the M9 multiplier
A nightly job over situation transitions computes baselines with plain statistics
(median/MAD, no ML): typical leave time per weekday, study blocks, return-home
time, sleep window. Stored as **reviewable rhythm records** in the memory UI
(D12 pattern: proposed by Aitvaras, viewable/editable/deletable). Enables
anomaly-gated proactivity, "you usually leave 8:40 on Tuesdays; it's 8:35 and U6
is disrupted", and, just as important, keeps Aitvaras silent on normal days.

### 3.7 Explicitly NOT signals (rejected)
- **Browser history / message-content mining** beyond what D5/D21 already triage,
  creep exceeds decision value.
- **Health/fitness**: no macOS data source; a phone detour isn't worth it now.
- **Ambient audio sensing**: hard no. The mic exists for conversation only.

## 4. Features this unlocks

### F1: Situation-aware triage (M7) · the original motivating example
Same pipeline (D5/D19/D21); the classifier prompt now carries the situation block
plus sender↔course linkage. A mail from the lecturer of the course starting in
2h → urgent now, punches through; the same mail on Saturday → evening briefing.
Homelab warning → urgent at home, briefing item on campus. Cheapest big win in
the whole plan: prompt changes + engine, no new UI.

### F2: Interruption calculus with an attention budget (M7 core, M9 full)
Every proactive impulse is scored `urgency × confidence` against the interruption
cost of the current attention state (meeting/lecture ≈ ∞, focus high, idle at home
low). Below threshold → held for the next briefing or break (the router already
knows how to hold, D19, this generalizes it). Hard rules: silence during
`asleep`; a **daily cap on proactive interruptions** (default 3, confirmations
and user-initiated turns excluded). Every proactive ping carries a **"why now"**
provenance line (extends D13 provenance from actions to *attention*).

### F3: Transition advisor (M8) · where location, transit and weather fuse
Fires only when: next commitment has a place ∧ you're not there ∧ the departure
window approaches. Computes leave-by from usual mode + live MVG + rain-at-
departure. One nudge, on the right channel (voice at Mac, Telegram otherwise):
*"Leave by 8:12, U6 is 10 min delayed and it'll rain in Garching; U-Bahn over
bike today."* No commitment away from home → silent all day.

### F4: Briefings: morning / evening / catch-up (M8)
The sink for everything sub-threshold, the structural alternative to
notification spam. **Morning** (first unlock at home): day shape, deadlines that
moved closer, the 2–3 triaged mails worth reading, homelab anomalies, transit/
weather only if anomalous. **Evening**: tomorrow preview, loose ends, goal recap.
**Catch-up card** (back at the Mac after >45 min): "while you were away: 12 mails
(2 flagged), TrueNAS scrub finished, 1 reminder created", makes background work
visible without ever having interrupted.

### F5: Study copilot deepening (M8–M9)
- **Pre-lecture card**: 20 min before a lecture, RAG surfaces last week's notes
  and the open exercise sheet for that course (the notes folder is already
  indexed, D11).
- **Deadline pressure**: effort estimates (Aitvaras asks once per assignment) vs
  free calendar slots → "Blatt 7 needs ~4h, you have 5h free before Thursday,
  tight" instead of a bare due date.
- **Exam mode**: exam within N days (Moodle/calendar) automatically tightens
  triage thresholds and suggests focus sessions (D19); auto-releases after.

### F6: Homelab watchdog (M9)
D17 polling triggers exist; add per-metric baselines and anomaly gating so it
pings on "scrub errors / VM down / disk temp trending up", never on noise.
Routed like everything else through F2, urgent at home, briefing line elsewhere.

### F7: Situation-triggered automations (M10)
Natural language → **reviewable rule** (Aitvaras drafts, user approves, the
ManifestDrafter precedent): trigger (connector event | situation transition |
schedule) × condition (situation predicates) × action (existing tools; autonomy
policy D13 applies unchanged). Deterministic hot path, no LLM once compiled.
Aitvaras may also *suggest* rules from observed patterns ("every mail from X ends in
a reminder, want a rule?").

## 5. Rejected as gimmicks (so we stop re-litigating)
- Standalone weather / news / quote-of-the-day announcements.
- Proactive small talk, violates the serious-companion character (D4).
- Auto-drafted mail replies, D20 stays absolute; drafts creep toward send.
- Analytics dashboards (screen-time graphs, location history maps): Aitvaras is
  judgment, not analytics; the activity log suffices.
- Smart-home *control*, blocked on O1; not in this plan while D10 stands.

## 6. Open decisions (each needs an explicit call before its milestone)
- **O1 (revisits D10):** does HA stay read-only? Focus scenes ("desk lamp on when
  a session starts") would need an opt-in write allowlist (domains `light`/
  `scene` only, risk `reversibleWrite`). Recommendation: keep read-only through
  M9, decide at M10.
- **O2:** is phone-via-HA presence enough, or grant Mac Location Services
  (SSID + geofences) in default setup? Recommendation: HA-first; Location stays
  an optional catalog connection.
- **O3:** situation-history retention (proposal: 30 days of transitions, then
  only rhythm aggregates).
- **O4:** interruption-cap default (3/day?) and quiet-hours policy.
- **O5:** briefing delivery, spoken by default when at the Mac, or card-first
  with voice on demand?

## 7. Milestones (post-v0.1; ROADMAP phase 2 unchanged, interleaves after M8)

### M7: Situation Engine
`SituationEngine` actor + Mac-local signals (lock/idle/frontmost/mic-camera/
power/display/homelab-reachability); HA presence via existing manifest polling;
attention states incl. `meeting` and `asleep`; `# Current situation` block in
PromptBuilder; situation block into mail/notification triage prompts;
NotificationRouter cost function on `attention`; snapshot visible in UI with
per-signal toggles.
**Exit:** triage verdicts and interrupt decisions demonstrably differ between
home / campus / in-call for the same event; the UI can always show *why*.

### M8: Day structure
Morning/evening briefings + catch-up card (router sink for sub-threshold items);
transition advisor; MVG + Open-Meteo + eat-api as bundled manifests (D17, no new
Swift connectors); pre-lecture card.
**Exit:** a normal day produces ≤3 interruptions and one genuinely useful morning
briefing; a disrupted U6 before a lecture produces exactly one advisor nudge on
the right channel.

### M9: Rhythms & judgment
Nightly baseline job + reviewable rhythm records; anomaly gating; full attention
budget (daily cap, "why now" provenance UI); deadline pressure + exam mode;
homelab watchdog baselines.
**Exit:** on a week of normal days Aitvaras is near-silent; every ping that did
happen can show the anomaly that justified it.

### M10: Automations & watchdog maturity
Rule engine (trigger × condition × action) + rules UI + Aitvaras's rule
suggestions; decide O1 (HA writes for focus scenes).
**Exit:** "when a mail from my Prof arrives while I'm on campus, Telegram me
immediately" works end-to-end as a user-approved rule, no code.

### Beyond (phase 2+, unordered)
Wake word (D16 chose the name for it), messengers (D8), iOS companion (Telegram
remains the mobile channel until then), full ambient screen capture
(screenpipe-class 24/7 OCR memory, real CPU/disk/redaction costs, unproven
summary ROI; revisit only if "what was I reading/doing" queries become frequent,
see §9 L1).

---

# Part II: Knowledge & learning

How Aitvaras remembers, actively learns about the user's life, and uses multiple
models each where they're strongest. Evidence base: three research reports in
`docs/research/` (2026-07-07): agent-memory state of the art, multi-model
orchestration + ambient intelligence, and an OpenClaw teardown with community
feedback. Claims below reference them; only load-bearing sources are linked
inline.

## 8. Thesis II: memory is a pipeline, not a list

Today `Memory` is a flat record and the top 30 are pasted into every system
prompt. That is the design both ChatGPT and Claude have already outgrown, flat
lists and single rolling summaries hit hard ceilings; Anthropic is currently
replacing its one memory summary with browsable topic-scoped "Memory Files".

The research consensus (Letta/MemGPT, Mem0, Zep, Hindsight, Generative Agents,
see `docs/research/2026-07-07-agent-memory-architectures.md`) is that memory
that works is a **pipeline**: raw episodes → extracted atomic facts →
consolidation/reflection → compact always-in-context profiles, with hybrid
retrieval over the middle layers and provenance throughout. And the strongest
published validation of our D14 delegation plan: **run the fast model live and
the strong model asleep** (Letta sleep-time compute, the interactive agent
never edits its own memory; a background agent with a stronger model does;
~2.5× cost reduction and better memory quality).

Operating principles for everything below:

1. **Files over black boxes.** Profile documents are plain markdown on disk,
   git-versioned; the SQLite/vector index is derived and disposable. This is
   the single most community-praised OpenClaw property ("memory stored in
   version control I can read/edit"), it's Anthropic's own API pattern (the
   memory tool is file-based), and the Rewind/Limitless shutdown (Meta
   acquisition, Dec 2025) proved the alternative: opaque vendor memory dies
   with the vendor.
2. **Supersede, never delete.** Facts carry validity intervals; contradictions
   invalidate the old fact and keep it queryable ("what did I use to…").
   Automatic hard deletion doesn't exist; deletion is a user action.
3. **Delta updates, never wholesale rewrites.** Aggressive re-consolidation
   destroys retrievable detail, "context collapse", found independently by
   Letta (over-consolidation warning) and Stanford's ACE paper.
4. **The user reads, edits, and vetoes everything.** D12 already promises this;
   the security literature adds the governance reason (unreviewable memory is a
   poisoning surface). Memory writes appear in the activity log like any other
   side effect.

## 9. Memory architecture (D12 v2)

Four layers in the existing SQLite + sqlite-vec + FTS5 stack. Shape verdict
from the evidence: **"graph-lite"**: a full knowledge graph bought Mem0 only
~2% over its flat pipeline, while the current LongMemEval SOTA (Hindsight,
91.4%) uses typed fact networks, not a graph DB. Entity-*tagged* facts with
bi-temporal columns recover the graph's only unique wins (temporal + multi-hop)
without Neo4j-class machinery.

**L1, Episodes** (exists: activity log). The append-only, non-lossy ground
truth. Additions: situation transitions (M7), **end-of-conversation summaries**,
and a daily timeline skeleton from cheap Mac signals (frontmost app + window
title + idle, FocusCoach's sampling generalized; content-level screen capture
stays out per the Part I rejection, with the revisit trigger noted in Beyond).

**L2, Facts** (new). Atomic, typed, entity-tagged statements:

```
fact(id, text,
     kind: preference | biography | event | procedure | belief | rhythm,
     entities[], importance 1–10, confidence,
     source: user_stated | user_answered | extracted | reflected,
     valid_from, valid_to, superseded_by,
     source_episodes[], last_accessed)
```

Bi-temporal validity is Zep's mechanism flattened into a table. A novelty gate
skips near-duplicate writes (the cheap lever against memory hoarding, gate
writes, not deletes). Embedded as fact text + entity names ("fact-augmented
keys", measurably better than embedding raw log lines) in the same sqlite-vec
store as D11, plus FTS5.

**L3, Entities** (new, lightweight). person / place / course / system records
with an LLM-maintained one-paragraph summary; facts tag entities. No edges, no
graph traversal, no community detection.

**L4, Profile packs** (new, replaces the flat 30-memory prompt dump). 3–5
topic markdown files: identity & preferences · current projects & courses ·
environment & homelab · working style & communication. **Regenerated nightly
from the facts table** (delta-patched, not rewritten), each with a hard token
budget, all always-in-context. They live in a git-versioned memory folder on
disk; a protected "user notes" section in each file survives regeneration
verbatim, and user edits are read back as highest-authority input at the next
consolidation (O6).

**Retrieval.** Score = BM25 (FTS5) + cosine (sqlite-vec) + recency decay on
*last access* + importance, rank-fused, the Generative-Agents triple on our
existing stack. Plus the two cheap wins with measured payoff: **time-aware
filtering** (extract a time window from the query, filter on validity, +7–11%
on temporal questions in LongMemEval) and **as-of semantics** (currently-valid
facts by default; superseded ones on explicit past-tense queries). The agent
gets `memory_search` / `memory_get` tools and one retrieval-protocol line in
the system prompt ("search memory before non-trivial personal questions").
Starting parameters straight from OpenClaw's shipped defaults (0.7 vector /
0.3 text, ~400-token chunks, 80 overlap, versioned chunk IDs so an embedding
model swap auto-reindexes). No cross-encoder reranker, at thousands of facts
the 30B reranks candidates in-prompt.

## 10. The learning loop (multi-model choreography)

"She should actively learn about my day", mechanically:

**Live (hot path, 4B/30B, during use).** Only three things, none of which
reorganize memory (Letta's lesson: online memory editing degrades both the
conversation and the memory):
- Explicit "merk dir das" → immediate `user_stated` fact (reversibleWrite,
  logged, visible).
- A per-session scratch block.
- **Pre-compaction flush**: OpenClaw's most load-bearing mechanism, ported:
  before a conversation is summarized, reset, or dropped, a silent small-model
  turn runs *"store durable notes now; reply NO_REPLY if nothing."* This is the
  documented #1 failure mode across the whole ecosystem (knowledge that lived
  in chat and was never written down, users experience it as "she forgot"),
  fixed with one cheap mechanical turn.

**Nightly sleep (Claude CLI via D14, "the sleeping brain").** One consolidated
job, six steps:
1. **Extract** candidate facts from the day's episodes (conversations, triage
   outcomes, situation transitions).
2. **Reconcile** each against the top-k similar existing facts →
   ADD / UPDATE / SUPERSEDE / NOOP (Mem0's controller pattern; supersede sets
   `valid_to`, never deletes).
3. **Reflect** (Generative Agents): pose the salient higher-level questions
   over recent memories, answer the answerable ones as insight-facts *citing
   their evidence episodes*.
4. **Regenerate profile packs**: as reviewed deltas, never full rewrites.
5. **Emit curiosity questions**: the unanswerable reflections go to the queue
   (§11) instead of the archive.
6. Write a human-readable **daily learning digest** ("what I learned about you
   today", OpenClaw's DREAMS.md pattern): shown in the memory UI, available to
   the evening briefing (F4), and doubling as the audit trail.

Weekly deep pass: entity-summary refresh, dedup sweep, decay update, rhythm
baselines (shares M9's nightly job).

**Budget & robustness.** Headless `claude -p` bills against a separate monthly
Agent SDK credit since June 2026, with hard failures when exhausted. So: one
consolidated prompt per night, output caps, prompt caching over the stable
memory files, cheapest adequate model (Letta reports Haiku-class suffices for
routine consolidation, reserve the big model for pattern-finding and audits).
**Graceful degradation is mandatory:** quota-out or offline → the local 30B
runs a reduced consolidation (extract + reconcile only, no reflection) or the
night is skipped, episodes are never lost, and failures alert loudly in the
activity log instead of breaking silently.

**Asymmetric draft-verify.** The local models may draft memory writes and
triage labels all day (immediate, never blocking); the nightly big-model pass
audits the accumulated drafts semantically. This catches the two documented
failure modes of small-model memory: "confidently slightly wrong" and "never
actually persisted". Memory writes go through the autonomy policy like
everything else: normal facts = `reversibleWrite`; sensitive kinds (health,
judgments about other people, beliefs) = `confirmable` (O7).

## 11. Curiosity queue + Q&A sessions (F8)

Research verdict: the pieces exist, Dot's interview-style memory building,
GATE's LM-generated preference elicitation (ICLR 2025: model-generated open
questions beat user self-description, and feel *less* effortful to answer),
sleep-time reflection, but **no shipped system closes the loop** of
*reflection generates a question memory cannot answer → route it to the user*.
The academic framing only arrived in May 2026 ("the proactivity gap": passive
personalization captures only what the user happened to reveal). This is
Aitvaras's chance to do something genuinely novel, with literature to lean on.

Mechanics:
- **Generation**: during nightly reflection (not mid-conversation), plus live
  ambiguities queued silently as they occur (two people named Max; an unknown
  preference that blocked a triage decision).
- **Store**: `question(text, motivation, expected_value, status)`, scored by
  expected downstream utility: how many pending decisions, triage rules, or
  facts would the answer unblock ("ask now, use later").
- **Delivery**: user-initiated ("was willst du wissen?" / a "3 questions"
  affordance in the UI) or offered at a break through the F2 attention budget.
  Short bounded sessions, 3–5 questions, voice-friendly, one topic at a time.
  Each answer may spawn one follow-up (Dot's pattern), never a chain.
- **Answers** become facts with `source: user_answered` (top confidence), the
  question is retired, and the provenance chain shows which answers changed
  which behaviors.
- **Contradictions route here too**: conflicting facts become a queued question
  instead of a silent overwrite.
- **Fatigue controls**: the failure mode every source warns about (Dot's
  reviews: "really, really wants to get to know you"): hard cap on unprompted
  questions (default 1/day, O9), unanswered questions decay, dismissed
  questions never return.

## 12. Multi-model doctrine (D-candidate, extends D2/D14)

| Model | Runs | Job |
|---|---|---|
| Qwen3-4B | always | route, classify, triage, flush notes, heartbeat-class checks |
| Qwen3-30B-A3B | interactive | converse, act through tools, draft memory writes, rerank retrieval in-prompt |
| Claude CLI | nightly + on demand | consolidate, reflect, audit drafts, regenerate profiles, distill rules, draft manifests |
| Codex CLI | overflow | code-shaped batch work (mind its 5-hour + weekly quota windows) |

- **Routing**: rules-first two-tier (intent / complexity / sensitivity),
  escalate on low confidence, 2026 production consensus; learned routers
  (RouteLLM-class) only become worthwhile after months of logged decisions, so
  **log every routing decision now** (chosen model, confidence, cost, latency)
  and revisit.
- **SPL-lite ("system prompt learning")**: weekly, the big model distills
  accumulated corrections and successes into the small models' *decision
  rules*, the triage rubric, the voice-mode rules, the routing rules, as
  reviewable, diffable markdown patches. Karpathy's proposal, with one measured
  implementation (optillm SPL: +8.6pp Arena-Hard after ~500 queries). The
  prompt becomes learned, versioned state. Expect payoff after weeks, not days.
- **Cache warmth**: pin model/profile choices per session (OpenClaw failover
  lesson; equally true for MLX KV-cache locally).
- The heartbeat cost lesson from the OpenClaw community ($100+/month burned on
  big-model beats) is standing policy: **periodic checks run on the 4B, always**.

## 13. From OpenClaw: port / adapt / skip

Full teardown with community evidence: `docs/research/2026-07-07-openclaw-teardown.md`.

**Port (adapted to native Swift):** markdown-canonical profile packs +
disposable index · pre-compaction flush (§10) · dreaming-style promotion gates
(score × recall-frequency × query-diversity decide what enters always-in-context
profiles) · the session rhythm, daily reset at ~04:00 + idle reset, bootstrap
reloaded fresh, memory searchable across resets (O10) · hybrid-search defaults
(§9) · sub-agent **announce-back** (D14 delegate results re-enter the main
conversation as events that can wake/steer it) · lazy skill loading (~24 tokens
of name+description per skill, full body read on demand) as the loading model
for procedural memory (F9).

**Skip:** the gateway/channel/server layer and canvas (every serious OpenClaw
security incident, exposed gateways, ClawJacked, token-leaking WebSockets,
lived there; a native app with no listening ports dodges the class) · model
failover machinery · ClawHub-style auto-installed skills (documented malicious
skills, procedures are vendored manually, treated as untrusted code).

**Adopt as standing lessons:** prompt-injection payloads targeting personal
assistants circulate in the wild, all fetched web/mail/notification content is
hostile input to the tool layer, and D13's read/reversibleWrite/confirmable
ladder is exactly the "gradual trust" posture the community converged on after
the mass-Gmail-deletion incidents. Their reliability data also confirms a Part
I principle: fixed routines belong in deterministic schedulers, not in "the
model will probably remember to do it".

## 14. New features (continuing Part I's F-numbering)

- **F8, Curiosity Q&A** (§11).
- **F9, Procedural memory**: "how-to" notes, how to reach the Proxmox box,
  how the user likes summaries structured, how Uni mails get filed, as
  markdown procedure files with name+description lazily injected and bodies
  read on demand. Written by consolidation from repeated corrections; the
  behavioral sibling of D17 manifests. (This is the `procedure` fact kind
  grown into files once a note outgrows one sentence.)
- **F10, Memory UI v2 + daily learning digest**: facts browsable and editable
  with provenance and a validity timeline ("knew since / superseded by");
  the nightly digest is the trust surface, "here's what I learned about you
  today, tap anything to correct it". Corrections are themselves high-authority
  training signal for the next consolidation.
- **F11, Perfect recall over episodes**: "wann habe ich zuletzt mit X über Y
  geredet?", hybrid search over conversation summaries and episodes (the
  transcripts-as-memory pattern), a separate tool namespace from fact memory.

## 15. Open decisions II

- **O6**: memory folder location: inside Application Support, or user-visible
  (e.g. `~/Aitvaras/memory`) with git history, optionally Syncthing-synced?
  Recommendation: user-visible + git init; it's the property users praise most.
- **O7**: which fact kinds are sensitive enough to require confirmation before
  storing (health, judgments about third parties, beliefs?). Default list to
  review.
- **O8**: nightly budget policy: model class per step, monthly cap, and the
  exact local-fallback ladder when quota is out.
- **O9**: unprompted-question cap (default 1/day) and Q&A session length
  (default 5).
- **O10**: conversation session model: adopt daily-reset-with-flush
  (recommended, bounded contexts, fresh bootstrap, nothing lost thanks to the
  flush) or keep endless persistent conversations?
- **O11**: does the memory folder join the D11 RAG index or stay a separate
  retrieval domain? Recommendation: separate tool namespace
  (`memory_search` ≠ `knowledge_search`), shared infrastructure.

## 16. K-milestones (knowledge track: parallel to M7–M10)

K1 can start immediately and pairs naturally with M7 (they share the episode
layer: situation transitions are episodes). Suggested interleave:
K1 ↔ M7 → M8/K2 in either order → K3 → M9/M10/K4.

### K1: Memory foundation
Facts/entities/questions tables with bi-temporal columns; facts + episodes
embedded into the existing sqlite-vec store; `memory_search`/`memory_get`
agent tools + retrieval-protocol prompt line; profile packs v0 (regenerated
on demand by the 30B, markdown on disk); PromptBuilder switches from the
30-item dump to packs + per-turn retrieval; memory UI v2 (edit facts, see
provenance); pre-compaction flush + explicit-remember hot path;
end-of-conversation summaries into episodes.
**Exit:** "was weißt du über mich / über X?" answers from structured memory
with visible provenance; nothing important said in a conversation is lost when
it ends.

### K2: The sleeping brain
Nightly Claude CLI consolidation (extract → reconcile → reflect → regenerate →
digest) with budget caps, prompt caching, and the local-fallback ladder; daily
learning digest in the UI and evening briefing; weekly deep pass; big-model
audit of the day's locally-drafted memory writes.
**Exit:** after a week of normal use, the profile packs read as accurate to the
user with zero manual curation, and every learned fact traces to its evidence.

### K3: Curiosity
Question generation in reflection + live ambiguity capture; queue with
expected-utility scores; Q&A session mode in chat and voice; answer→fact
pipeline with follow-ups; fatigue caps.
**Exit:** a five-question session measurably improves the next day's triage or
briefing (answered facts appear in decision provenance).

### K4: Procedures & self-tuning
Procedure files with lazy loading; SPL-lite weekly rule distillation (triage
rubric first, it has the fastest feedback loop); routing-decision logging;
(stretch) learned router from accumulated logs.
**Exit:** a correction stated once ("Mails von X sind nie dringend")
demonstrably changes behavior from the next day on, via a reviewed, diffable
rule patch, not hope.

---

# Part III: Making it visible (the full-app UI)

Everything in Parts I and II generates internal state, facts, a situation
snapshot, a curiosity queue, a nightly digest, an interruption budget. If the
only way to inspect that state is to ask Aitvaras in chat, the assistant is a black
box and the user has to trust it blind. The UI's job is the opposite of chat:
**answer the questions you'd otherwise have to ask the model**, at a glance,
inspectable and correctable. This part designs where that lives in the main
window.

## 17. Principles

1. **Each surface answers one standing question.** *What's going on right now?*
   *What does Aitvaras know about me? What did she do, and why?* One home per
   question, don't scatter situation across five screens.
2. **Read-first, edit-always.** Everything shown is inspectable and correctable
   in place, facts, profile, questions, rules. This is the same trust
   guarantee as D12/§8 ("the user reads, edits, and vetoes everything"), made
   physical. Correcting a fact in the UI is itself high-authority learning
   signal for the next consolidation.
3. **Three tiers of attention: glance → overview → drill-down.** A status strip
   that's always on screen; a Today dashboard for the overview; detail sheets
   (provenance, validity timeline) for the deep dive. This mirrors the existing
   Activity → `ProvenanceSheet` pattern, extend it, don't reinvent it.
4. **Surface silent failures loudly.** The nightly consolidation can fail
   silently (quota out, offline, §10); the research names this as the trust
   killer. Job status is a first-class UI element, not a log line.
5. **Reuse the existing visual language.** Grouped `Form`s, `List` rows with
   chips, `.sheet(item:)` details, the `ProvenanceSheet` timeline,
   `ContentUnavailableView` empty states, the sidebar footer. No new idioms.

## 18. Information architecture

The sidebar (`MainWindow`'s `SidebarItem`) grows from 6 flat items to grouped
sections. Two genuinely new surfaces, **Today** and **Memory**: plus
extensions to Activity and the footer.

```
AITVARAS          ← conversation surfaces
  Today   ★ new   the glanceable "what's going on" home (default landing)
  Chat
  Voice
TRANSPARENCY   ← "what does she know / what did she do"
  Memory  ★ new   what Aitvaras knows about ME (≠ Knowledge)
  Knowledge       RAG over external docs — unchanged (rename label if it
                  reads ambiguously next to Memory)
  Activity        the audit trail — extended (§20)
CONFIG
  Connections
  Setup
─────────────────────────────
[● MLX · Qwen3-30B] [📍 campus · focused] [Analysis in 74m] [⚡2/3] [⚠ sleep]
      status strip — always visible, on every screen (§21)
```

Why **Memory** is separate from **Knowledge**: they answer different questions
(what Aitvaras learned about *you* vs. external documents she can search) and are
different subsystems (D12 vs D11; O11 already splits `memory_search` from
`knowledge_search`). Merging them would bury the personal layer, the thing the
user most wants to audit, inside a document browser.

## 19. Today: the dashboard (the direct answer to "let me check without asking")

The default landing surface. A scroll of cards, each backed by a subsystem;
cards that have no data yet simply don't render, so it grows as the milestones
land rather than showing empty scaffolding.

- **Right now** (M7): situation snapshot, place chip, attention state, next
  commitment with countdown and travel slack. The at-a-glance state.
- **Today's briefing** (F4/M8): the morning briefing *rendered as a card, not
  only spoken*, deadlines that moved closer, the 2–3 mails worth reading,
  anomalies. Evening variant after ~18:00.
- **Pending for you**: confirmation cards awaiting approval (the existing
  `Suggestion` queue) + notifications held for the next break, accept/reject
  inline. This is where `confirmable` actions surface visually instead of only
  as notifications.
- **Aitvaras wants to know** (K3): top 1–3 open curiosity questions with an
  "Answer" affordance that opens a short Q&A; "ask me everything" starts a
  full session. Capped by the same fatigue rules as the spoken path.
- **Interruptions today** (F2/M9): the budget meter ("2 of 3 used") with the
  why-now line for each ping, makes the attention budget legible and builds
  trust that Aitvaras is *choosing* silence.
- **Last night** (K2): the learning digest ("what I learned about you") **plus
  the consolidation job status**: ran / skipped / failed, model used, budget
  spent. Principle 4 in one card.

## 20. Memory: "what does Aitvaras know about me?"

One sidebar item, four internal tabs (segmented control, keeps it one surface):

- **Facts**: searchable list, filterable by kind (preference / biography /
  event / procedure / belief / rhythm) and by entity. Each row: the fact text, a
  kind chip, a **source badge** (you said · you answered · inferred · reflected)
  and confidence. Tap → detail sheet with **provenance** (the source episodes /
  conversation it came from, reuse `ProvenanceSheet`) and a **validity
  timeline** ("known since 3 May", "superseded on 1 Jul → …"). Edit / correct /
  delete inline; a toggle reveals superseded facts as history. *This is the K1
  "memory UI v2" deliverable and is buildable now against the shipped store,
  it needs no other subsystem.*
- **People & things** (entities): list with summaries; tap → all facts about
  that person / place / course / system.
- **Profile** (K2): the generated profile-pack markdown (identity & prefs;
  projects & courses; environment & homelab; working style) rendered read-only,
  with an editable protected "your notes" area that survives regeneration. The
  always-in-context layer, made visible, this is literally what Aitvaras carries
  into every conversation.
- **Questions** (K3): the full curiosity queue with expected-value and
  motivation, "start Q&A", and answered/dismissed history.

## 21. Status strip + Activity extensions

- **Status strip** (extend `MainWindow.statusFooter`): today the footer is just
  the engine dot. Grow it into the always-visible glance tier, engine · a
  situation chip (place · attention) · next commitment · interruption budget ·
  a **warning dot when last night's consolidation failed**. Clicking it jumps to
  Today. Because it's on every screen, this is the single highest-use
  "without asking the model" affordance. (The floating companion window gets the
  same situation as a hover tooltip, the ambient mirror of this.)
- **Activity** (extend the existing audit trail): add situation transitions as
  event kinds (arrived campus, left home, woke up), a memory-writes filter
  (every fact add/supersede is already logged with provenance, make it
  browsable), and extend `ProvenanceSheet`'s "because of what" chain to carry
  the **why-now** for proactive pings (situation + rule that fired), so the
  interruption-budget entries on Today drill into a full explanation.

## 22. Build order (UI tracks the backend milestones)

- **Now (with K1):** Memory view, Facts + People & things + Questions tabs,
  editing, provenance/validity sheets. Buildable against the current store; the
  Profile tab is a stub until K2. *(App target, needs an Xcode build to verify
  visually; the store layer underneath is already `swift test`-green.)*
- **With K2:** Today's "Last night" card (digest + job status); Profile tab
  populated; the footer's consolidation-failure dot.
- **With M7:** Today's "Right now" card + the footer situation chip; situation
  transitions in Activity.
- **With M8:** Today's briefing + held-notifications cards.
- **With F2/M9:** interruptions budget meter + why-now drill-down; rhythm facts
  already appear in Memory (they're the `rhythm` fact kind).

The frame, **Today** as the landing dashboard and the **status strip** as the
glance layer, is worth stubbing early even mostly-empty, because every later
milestone then has an obvious home to render into instead of inventing UI
per-feature. Start Today with what already exists (pending suggestions + open
questions + memory/index counts) and let cards light up as subsystems land.

---

# Part IV: Meeting mode (added 2026-07-12)

User request: live-transcribe meetings (audio + shared screen), deliver a
detailed summary afterwards, fully local.

## 23. F12: Meeting mode

**Feasibility: everything runs on-device with Apple APIs, no new models.**

| Piece | API | Status |
|---|---|---|
| Your voice | mic capture + `SpeechAnalyzer` streaming STT (DE/EN) | already Aitvaras's stack (D3) |
| Other participants | system/app audio via Core Audio process taps or ScreenCaptureKit audio → a second `SpeechAnalyzer` session | new; needs the Screen/System-Audio Recording permission |
| Shared screen / slides | ScreenCaptureKit frames (window-scoped, ~1 frame/5 s or on-change) → **Vision OCR** (`VNRecognizeTextRequest`, on-device, DE/EN; macOS 26 adds structured document recognition) | new; low cost on Apple Silicon |
| Summary | 30B over transcript + slide text, map-reduce for long meetings | existing engines |

Design (v1):

- **Session-bounded, explicit start/stop**: same consent shape as focus
  sessions (D19) and the FocusCoach capture precedent: raw audio buffers and
  screen frames are transcribe/OCR-and-discard, **never persisted**; what
  persists is the transcript, timestamped slide text, and the summary.
  This is NOT ambient capture, the screenpipe-class always-on recorder
  stays rejected (Part I §5); meeting mode is a bounded, user-initiated
  session with a visible macOS recording indicator.
- **Two-channel attribution for free**: mic stream = `[Ich]`, system-audio
  stream = `[Andere]`. True per-speaker diarization is deliberately out of
  v1 (no Apple API; a pyannote sidecar only if v1 proves insufficient).
  v2 can often recover speaker names from the meeting app's active-speaker
  UI via OCR.
- **Slide dedup**: consecutive frames are text-diffed/perceptually hashed,
  stored notes are slide *changes*, not 600 identical captures. Default
  capture scope: the meeting window only, not the whole screen (O14).
- **Output**: structured summary (decisions · action items · open questions ·
  per-topic notes) as an episode + browsable transcript; action items become
  suggested Reminders through the normal autonomy policy; extracted facts run
  the standard pipeline (novelty gate, O7 quarantine). Transcript is
  searchable (the F11 "perfect recall" domain, not doc-RAG).
- **Auto-offer, never auto-start** (v2, needs M7's mic/camera-in-use signal):
  "Zoom is using the mic, soll ich mitschreiben?" through the attention
  budget. Recording never starts without an explicit yes.
- **Legal/consent posture (not optional)**: in Germany, recording the
  non-public spoken word without consent is criminal (§ 201 StGB): and a
  transcript is a record. Meeting mode therefore: requires explicit start,
  keeps the system recording indicator visible, stamps the summary header
  with "transcribed with participants' knowledge? y/n" metadata, and the
  docs say plainly: announce it or don't use it (O13).

## 24. Milestone M11: Meeting mode v1

Dual-stream transcription (`[Ich]`/`[Andere]`) with manual start/stop from
companion/hotkey/voice; window-scoped OCR notes with slide dedup;
post-meeting map-reduce summary + action-item cards + episode/facts;
transcript search; raw audio/frames never touch disk.
**Spike first**: two concurrent `SpeechAnalyzer` sessions (mic + tapped
system audio): the one genuinely unvalidated piece; everything else is
known-good API.
**Exit:** a 60-minute bilingual test call yields a summary the user would
have taken notes from, correctly split into mine/theirs, with ≥1 usable
action-item card, and `ls` of the state dir shows no audio artifacts.

v2 (later, unordered): auto-offer via M7, speaker names from active-speaker
OCR, live "catch me up" mid-meeting, diarization sidecar if needed,
capture in a D21-style disclaimed helper process so the main app never
holds the Screen Recording grant.

## 25. Open decisions III

- **O12**: transcript retention: keep full transcripts by default, or
  "summary only" per meeting? Recommendation: keep, with a per-meeting
  toggle and one-tap delete (they're the recall corpus).
- **O13**: consent default: hard-require the "participants know" checkbox
  before starting, or soft note in the summary? Recommendation: checkbox,
  it's one click and it's the difference between a tool and a liability.
- **O14**: capture scope default: meeting window only (recommended) vs
  full display; per-meeting picker either way.
