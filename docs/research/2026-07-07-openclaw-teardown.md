# OpenClaw teardown — mechanisms & community evidence

*Research report (2026-07-07) feeding MASTERPLAN.md Part II. Produced by a web-research agent; all claims sourced. Config keys/prompts quoted from official docs at docs.openclaw.ai unless noted.*

**Project background (for orientation):** Launched Nov 2025 as **Clawdbot** by Peter Steinberger (ex-PSPDFKit); renamed **Moltbot** in Jan 2026 after an Anthropic trademark complaint ("Clawdbot" ≈ "Claude"), then **OpenClaw** shortly after ([n9o.xyz history](https://n9o.xyz/posts/202602-steipete-openclaw-openai/), [euronews](https://www.euronews.com/next/2026/02/16/austrian-creator-of-viral-openclaw-joins-openai-to-build-next-generation-of-ai-agents)). MIT-licensed, Node/TypeScript gateway that bridges LLMs to messaging channels (WhatsApp, Telegram, Slack, iMessage, ~20 more) ([repo](https://github.com/openclaw/openclaw), [openclaw.ai](https://openclaw.ai/)). Feb 2026: Steinberger joined OpenAI; the project moved to a foundation and continues as OSS ([TechCrunch](https://techcrunch.com/2026/02/15/openclaw-creator-openclaw-joins-openai/)). Architecture axiom relevant to everything below: **"the model only remembers what gets saved to disk; there is no hidden state."**

---

## 1. Memory system — exact mechanics

Sources: [Memory overview](https://docs.openclaw.ai/concepts/memory), [Memory config reference](https://docs.openclaw.ai/reference/memory-config), [Agent workspace](https://docs.openclaw.ai/concepts/agent-workspace), [VelvetShark memory masterclass (2026-03-05)](https://velvetshark.com/openclaw-memory-masterclass), [Milvus memsearch extraction](https://milvus.io/blog/we-extracted-openclaws-memory-system-and-opensourced-it-memsearch.md).

### File layout (workspace default `~/.openclaw/workspace`)

| File | Role | Context behavior |
|---|---|---|
| `MEMORY.md` | Long-term: durable facts, preferences, decisions | Injected at session start ("bootstrap"); loaded **only in private sessions** (not group chats). If over budget, file on disk stays intact but the injected copy is truncated |
| `memory/YYYY-MM-DD.md` (also `YYYY-MM-DD-<slug>.md`) | Daily notes: running context, observations, task state | **Not** injected every turn — indexed for search; today's + yesterday's files load on `/new` / `/reset` |
| `DREAMS.md` | Optional "dream diary": consolidation-sweep summaries for human review | Written by the dreaming pass |
| `SOUL.md` / `AGENTS.md` / `USER.md` / `IDENTITY.md` / `TOOLS.md` | Persona+boundaries / operating rules / who the user is / agent name+vibe+emoji / local-tool notes | All loaded every session; they "survive compaction because they're reloaded, not compressed from history" |
| `BOOTSTRAP.md` | One-time first-run ritual; "delete it after the ritual is complete" | Only in brand-new workspaces |

Budgets: `bootstrapMaxChars` 20,000/file, `bootstrapTotalMaxChars` 60,000 total (docs default; VelvetShark cites 150K aggregate — version drift). Community guidance: keep `MEMORY.md` under ~100 lines; never store API keys/raw logs/drafts.

### When memories get written

1. **Conversationally** — user says "remember that…", agent writes the file (plain file tools; no special memory API).
2. **Pre-compaction memory flush** — the load-bearing mechanism. When a session nears the context limit, an **automatic silent agent turn** runs first. Exact prompts (per VelvetShark): system — `"Session nearing compaction. Store durable memories now."`; user — `"Write any lasting notes to memory/YYYY-MM-DD.md; reply with NO_REPLY if nothing to store."` Config: `agents.defaults.compaction.memoryFlush.enabled` (default `true`), `memoryFlush.model` (cheap-model override for just this turn), `reserveTokensFloor: 40000`, `softThresholdTokens: 4000`. Fires *before* overflow, not after.
3. **Dreaming** (optional, **disabled by default**) — background consolidation: collects short-term recall signals, scores candidates with **score / recall-frequency / query-diversity gates**, promotes only qualified items into `MEMORY.md`, writes phase summaries to `DREAMS.md`. Historical backfill: `openclaw memory rem-backfill --path ./memory --stage-short-term`.

### Memory search

- Tools: **`memory_search`** (semantic, "even when the wording differs") and **`memory_get`** (file/line-range read), provided by the default `memory-core` plugin.
- **Hybrid retrieval**: vector similarity + keyword FTS. Defaults under `agents.defaults.memorySearch`: `query.hybrid.vectorWeight: 0.7`, `textWeight: 0.3`, `candidateMultiplier: 4`, `maxResults: 6`, `minScore: 0.35`; MMR diversity re-rank and temporal decay (`halfLifeDays: 30`) exist but are off by default.
- **Chunking**: 400 tokens per chunk, 80 overlap (changing invalidates index identity). Milvus's extraction adds: chunks split on heading+body semantic boundaries, SHA-256 dedup, versioned chunk IDs `hash(source_path:start_line:end_line:content_hash:model_version)` so a model upgrade auto-triggers re-embedding.
- **Store**: SQLite with **sqlite-vec** extension (`store.vector.enabled: true`), falling back to in-process cosine; FTS tokenizer `unicode61` (`trigram` option). Index at `agents/<agentId>/agent/openclaw-agent.sqlite`. **Markdown is the source of truth — delete the index and "you lose nothing"**; rebuild takes minutes.
- **Embeddings**: default `openai`; alternatives `local` (GGUF via llama.cpp — community setups use embeddinggemma-300m), `ollama`, `lmstudio`, `gemini`, `voyage`, `mistral`, etc., with `fallback` adapter. Embedding cache on by default.
- **Index sync triggers**: `onSessionStart: true`, `onSearch: true` (lazy), file `watch: true` with `watchDebounceMs: 1500`; periodic reindex off.
- **Session transcripts as memory** (experimental): `experimental.sessionMemory` + `sources: ["memory","sessions"]` indexes conversation JSONL too (re-index thresholds `deltaBytes: 100000` / `deltaMessages: 50`).
- Pluggable backends: **QMD** (BM25-first local sidecar with rerank/query-expansion), **Honcho**, **LanceDB**, community **Mem0** plugin ([mem0 blog](https://mem0.ai/blog/mem0-memory-for-openclaw)).

### Known failure modes (VelvetShark)

(1) instructions given only in chat vanish at compaction if never flushed; (2) compaction drops nuance/images; fixes = write rules to files, verify flush headroom, and add a retrieval protocol line to `AGENTS.md`: *"memory_search before non-trivial work."*

---

## 2. Proactivity — heartbeat + cron

Sources: [Heartbeat docs](https://docs.openclaw.ai/gateway/heartbeat), [Cron docs](https://docs.openclaw.ai/automation/cron-jobs), [heartbeat guides](https://www.openclawplaybook.ai/guides/openclaw-heartbeat-md-guide/), [openclawsetup.info](https://openclawsetup.info/en/blog/openclaw-heartbeat-proactive-agents).

### Heartbeat

- Periodic agent turns **in the main session** "so the model can surface anything that needs attention without spamming you." Default interval **30m** (1h on Anthropic OAuth auth); disable with `every: "0m"`. Config at `agents.defaults.heartbeat` / per-agent.
- **Exact default prompt**: `"Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK."`
- `HEARTBEAT.md` is a plain user-editable checklist ("small, stable, and safe to consider every 30 minutes"; supports structured `tasks:` blocks with per-task intervals). Empty file → run skipped (`reason=empty-heartbeat-file`). You extend it conversationally: "Update HEARTBEAT.md to add a daily calendar check."
- **Suppression convention**: reply `HEARTBEAT_OK` → stripped if remaining content ≤ `ackMaxChars` (300); the user never sees a no-op beat. This one token is the whole "decide whether to speak" mechanism.
- **Delivery**: default `target: "none"`; options `"last"` (most recent channel) or explicit channel; `directPolicy: "block"` stops unsolicited DMs.
- **Cost controls**: `isolatedSession: true` (≈100K → 2–5K tokens by skipping conversation history), `lightContext: true` (inject only `HEARTBEAT.md`), per-heartbeat `model` override (community: run beats on the cheapest model; a no-action beat is ~500–800 tokens), `activeHours` `{start,end,timezone}` (defer outside window), visibility flags `showOk`/`showAlerts`/`useIndicator` (all off → beat skipped entirely).

### Cron (vs heartbeat)

- Persistent scheduled jobs in a **shared SQLite state DB**; heartbeat = ambient main-session pulse, cron = discrete detached jobs. CLI: `openclaw cron create|add|list|get|runs|run|edit|remove`.
- **Schedules**: `--at` (ISO/relative "20m"), `--every` (10m/1h/1d), `--cron` (5–6 field + `--tz`), `--on-exit`.
- **Session modes**: `main` (enqueue system event into a cron-owned lane), `isolated` (fresh session per run — "background reports"), `current`, `session:custom-id` (persistent workflow session).
- **Payload types**: `--system-event` (no model call), `--message` (agent turn), `--command` (shell). Per-job `--model "opus"`, `--thinking high`, `--tools exec,read`.
- **Delivery**: `announce` (fallback-deliver final text, e.g. `--announce --channel telegram --to "-1001234567890"`), `webhook`, `none`; retry `maxAttempts: 3`, `backoffMs: [30000,60000,300000]`.
- **Patterns people actually configure**: morning briefing (weather+calendar+tasks+news+health digest), inbox triage/unsubscribe watching, repo health dashboards (PRs/failing tests/stale branches), competitor/price watching, 200+-source weekly newsletter drafting, gym-slot sniping, nightly Obsidian→flashcard pipelines ([Ask HN](https://news.ycombinator.com/item?id=47783940), [use-case roundups](https://sidsaladi.substack.com/p/openclaw-use-cases-35-real-ways-people), [sphereinc](https://www.sphereinc.com/blogs/100-openclaw-use-cases-you-can-try-today)).

---

## 3. Skills / extensibility

Source: [Skills docs](https://docs.openclaw.ai/tools/skills).

- **Format**: directory containing `SKILL.md` with YAML frontmatter — required `name` (also the slash command) + `description`; optional `homepage`, `user-invocable`, `disable-model-invocation`, `command-dispatch: "tool"` (bypass the model, dispatch straight to a tool), `command-tool`, `command-arg-mode`.
- **Gating** via `metadata.openclaw` (JSON5): `requires.bins` / `anyBins` / `env` / `config` (skill only becomes eligible if the binary/env/config exists), `os` filter, `always`, `emoji`, `install` specs (brew/node/go/uv/download). This makes skills self-describing about their dependencies — ineligible skills cost zero tokens.
- **Locations** (precedence): `<workspace>/skills` → `<workspace>/.agents/skills` → `~/.agents/skills` → `~/.openclaw/skills` (managed) → bundled → `skills.load.extraDirs`/plugins.
- **Context loading**: eligible skills inject into the system prompt as "a compact XML block" — **name+description only, ~24 tokens per skill** plus field lengths; the model then reads the full `SKILL.md` on demand (the Claude-skills lazy-loading pattern). Overflow policy: drop descriptions first, then truncate the list (`skills.limits.maxSkillsPromptChars`). Eligible set is **snapshotted at session start**; a file watcher (`watchDebounceMs: 250`) can refresh mid-session.
- **Per-agent allowlists**: `agents.list[].skills` is a *final* set, not a merge — enables locked-down agents.
- **ClawHub registry**: `openclaw skills install @owner/slug | git:owner/repo@ref | ./path --as name`, `--global`, `update --all`, `verify`. Docs explicitly: "Treat third-party skills as **untrusted code**"; optional `security.installPolicy` pre-install policy hook. PKM-relevant community skills that circulate: journaling/daily-note writers, memory-review ("weekly memory audit") skills, morning-briefing builders, Obsidian/flashcard integrations (see [Ask HN](https://news.ycombinator.com/item?id=47783940) — e.g. dsiegel2275's nightly Obsidian→spaced-repetition pipeline).

---

## 4. Other subsystems worth mining

**Sub-agents** ([docs](https://docs.openclaw.ai/tools/subagents)). Spawned via non-blocking `sessions_spawn` (params: `task`, `agentId`, `model`, `thinking`, `context`, `cleanup`) returning a run ID; child session key `agent:<agentId>:subagent:<uuid>`. Default `context: isolated` (clean transcript, cheap) or `"fork"` (branch parent transcript). Children get **only `AGENTS.md` + `TOOLS.md`** injected — no persona/memory — and no session/message tools. Results **announce back** into the requester's session (status + reply text + token stats), waking/steering the parent if active; `sessions_yield` waits on completion events instead of polling; an "Active Subagents" block is injected into parent turns. Limits: `maxConcurrent: 8`, `maxChildrenPerAgent: 5`, `maxSpawnDepth: 1` (set 2 for orchestrator→workers; depth-2 can never spawn).

**Session model** ([docs](https://docs.openclaw.ai/concepts/session)). Transcripts are JSONL at `~/.openclaw/agents/<agentId>/sessions/<sessionId>.jsonl`. Scoping: all DMs share one session by default (`session.dmScope: main`; options per-peer / per-channel-peer / per-account-channel-peer); groups isolated per group; cron isolated per run. **Resets**: daily at a local hour (`reset.atHour`, default 4 a.m.), idle-based (`idleMinutes`), or manual `/new` (`/new <model>` also switches model) — with per-type/per-channel overrides. Bootstrap files reload on reset; memory files persist and stay searchable — "expected behavior, not a bug." Maintenance: `pruneAfter: "30d"`, `maxEntries: 500`; session *pruning* (tool-result trimming, cache-TTL 5m) is separate from *compaction* (summarization).

**Model failover** ([docs](https://docs.openclaw.ai/concepts/model-failover)). Two stages: (1) rotate **auth profiles** within the current provider, (2) fall to the next model in `agents.defaults.model.fallbacks`. The chosen profile is **pinned per session to keep provider prompt-caches warm** — no per-request rotation. The rate-limit bucket matches 429 plus strings like "ThrottlingException", "resource exhausted", weekly/monthly usage-window limits. Billing failures aren't transient: profile is disabled with a 5h backoff, doubling to a 24h cap. OpenRouter integration exposes routing knobs (`sort`, `only`, `max_price`, …) ([OpenRouter tutorial](https://openrouter.ai/blog/tutorials/openclaw-openrouter/)).

**Canvas.** The gateway serves a live, agent-drivable visual surface ("render a live Canvas you control") to companion apps/browsers — agent pushes HTML/UI to a user-visible panel ([openclaw.ai](https://openclaw.ai/), [repo](https://github.com/openclaw/openclaw)). Not verified deeper this session; treat as directionally sourced.

**Voice.** Provided by companion macOS/iOS/Android apps that "speak and listen" and talk to the gateway; voice is a channel like any other, not part of the agent core ([openclaw.ai](https://openclaw.ai/)). Depth not verified this session.

---

## 5. Community feedback

### What users praise (real daily use)

From [Ask HN: Who is using OpenClaw?](https://news.ycombinator.com/item?id=47783940):

- **Memory you can read, edit, and version** is the single most-praised property: lexandstuff runs it as his "main day-to-day LLM… via WhatsApp, but memory stored in version control I can read/edit," explicitly valuing that memory isn't "locked away with [a] vendor… switched when better LLM arrive[d]."
- **Proactive/agentic loops**: brtkwr's Telegram agent interviews 50+ family members in Nepalese, "meticulously documents [stories] and uses [them] as basis for further questions." mjsweet (gardener) runs scheduling, photo analysis, 14–32-page LaTeX PDF proposals and Xero invoices by voice from his truck. dsiegel2275: nightly Obsidian-notes→flashcards→spaced-repetition pipeline.
- **Low activation energy via chat**: calorie/health logging "lower activation energy than MyFitnessPal."
- Morning digests, inbox-zero triage, repo-health dashboards, competitor watching are the recurring heartbeat/cron patterns ([use-case roundup](https://sidsaladi.substack.com/p/openclaw-use-cases-35-real-ways-people), [TLDL](https://www.tldl.io/blog/openclaw-use-cases-2026)).

### Criticisms

- **Reliability/fragility**: "Broke every other morning… got fed up" (bigpapikite); "Keeps saying it'll fix it, but still doesn't work" (godot) — both [Ask HN](https://news.ycombinator.com/item?id=47783940). Several users concluded deterministic cron scripts beat a probabilistic agent for fixed routines.
- **Token cost**: jaybuff ~$3.50/day (~$100/mo) before abandoning; lexandstuff paid $100–150/mo on Opus before switching backends to a $20/mo plan. Heartbeats and big bootstrap files are the known cost drivers (hence `isolatedSession`/`lightContext`).
- **Hype skepticism**: in [the "changing my life" thread](https://news.ycombinator.com/item?id=46931805), gyomu: "Somehow 90% of these posts don't actually link to the amazing projects"; aeldidi: agents "immediately fall apart when faced with the types of things that are actually difficult."
- **Setup complexity**: Node gateway + channel credentials + provider auth is widely described as a weekend project; a whole cottage industry of setup guides/hosting services exists (openclawsetup.info, lumadock.com, etc. appearing in every search).

### Security lessons

- **Exposed gateways**: publicly reachable default ports/gateways were found and documented as an incident class ([Giskard](https://www.giskard.ai/knowledge/openclaw-security-vulnerabilities-include-data-leakage-and-prompt-injection-risks), [Nebius hardening guide](https://nebius.com/blog/posts/openclaw-security)).
- **ClawJacked**: high-severity indirect-prompt-injection → full remote agent control; users urged to upgrade ([Infosecurity Magazine](https://www.infosecurity-magazine.com/news/clawjacked-bug-covert-ai-agent/)). Versions <2026.1.29 auto-connected a WebSocket to an attacker-supplied `gatewayUrl` query param, leaking auth tokens; a malicious website could brute-force the localhost gateway password with no rate limit ([Penligent analysis](https://www.penligent.ai/hackinglabs/the-openclaw-prompt-injection-problem-persistence-tool-hijack-and-the-security-boundary-that-doesnt-exist/)).
- **Prompt-injection payloads in the wild** targeting OpenClaw agents via Reddit/Discord/web content the agent reads ([GitHub issue #30448](https://github.com/openclaw/openclaw/issues/30448)); **malicious ClawHub skills** documented (Giskard) — hence the docs' "untrusted code" stance and `security.installPolicy`.
- Community consensus mitigation = **gradual trust**: read-only tools first, human-in-the-loop for consequential actions ([HN security thread](https://news.ycombinator.com/item?id=47479962)); mjsweet: unrestricted API access is "the biggest security regression ever created."

---

## 6. Verdicts — port vs skip for a native local assistant (Aitvaras)

| Concept | Verdict | Reasoning |
|---|---|---|
| Markdown memory (`MEMORY.md` + `memory/YYYY-MM-DD.md`, files = source of truth, index disposable) | **Port** | The most community-validated idea in the project; transparent, user-editable, survives model swaps, ideal for local-first. Users explicitly praise owning memory as files |
| **Pre-compaction memory flush** (silent turn: "Store durable memories now… reply NO_REPLY") | **Port** | Cheap, mechanical fix for the #1 observed failure (memories never written). Trivial to add to any agent loop; run it on a small local MLX model |
| Hybrid search (sqlite-vec + FTS5, 0.7/0.3 weights, 400/80 chunking, file-watch reindex, versioned chunk IDs) | **Port** | Maps 1:1 to Swift + SQLite + local embeddings on Apple Silicon; Milvus's extraction proves it stands alone without the gateway |
| Dreaming consolidation (recall-signal scoring → promote to MEMORY.md, DREAMS.md audit trail) | **Port as batch experiment** | Off by default even upstream; run as a scheduled Claude Code/Codex subprocess job. The promotion gates (score/recall-frequency/query-diversity) and human-reviewable diary are the stealable parts |
| Bootstrap file split (SOUL/USER/AGENTS/IDENTITY/TOOLS + per-file char budgets + truncate-in-context-not-on-disk) | **Port (consolidated)** | Clean separation of persona vs user model vs behavior rules; budgets prevent context bloat. Aitvaras can use fewer files but keep the roles |
| Heartbeat (interval turn + user-editable checklist + `HEARTBEAT_OK` suppression + `activeHours` + cheap-model/`lightContext`) | **Port** | The whole proactivity design is architecture-independent: a timer, a checklist file, and a one-token "stay silent" convention. Cost controls are the hard-won part — copy them |
| Cron layer (payload types: system-event vs agent-turn vs shell; isolated sessions; announce-on-completion; retry/backoff) | **Port** | Maps to a native scheduler driving MLX turns or CLI subprocesses; the three payload types and isolated-session-per-run are exactly right for briefings/batch jobs |
| Sub-agents (spawn→announce-back→steer, minimal child bootstrap, depth/concurrency caps) | **Port selectively** | Aitvaras already delegates to Claude Code/Codex; steal the announce-back-into-main-conversation pattern, the "children get AGENTS.md+TOOLS.md only" context diet, and depth limits. Skip session-key plumbing |
| Session model (JSONL transcripts, daily 4 a.m. reset + idle reset, `/new`, prune vs compact distinction) | **Port** | Daily reset with bootstrap reload + searchable memory is a genuinely good companion rhythm; JSONL transcripts also become a memory source |
| Model failover (auth-profile rotation, billing backoff, session-pinned profiles) | **Skip mostly** | Built for multi-provider cloud API juggling. Keep only two ideas: a simple fallback ladder (local model → CLI subprocess) and "pin choice per session for cache warmth" |
| Gateway / channels / multi-device | **Skip** | Explicitly out of scope for Aitvaras — and it's where every serious security incident (exposed ports, ClawJacked, token-in-URL) lived. A native app with no listening ports dodges the entire class |
| Skills (`SKILL.md` + `requires.bins` gating + ~24-token lazy injection + per-session snapshot) | **Port** | Portable format with an existing community corpus; dependency gating means ineligible skills cost zero context. ClawHub-style auto-install: **skip** — proven supply-chain risk; vendor skills manually |
| Canvas | **Skip** | Aitvaras has a native SwiftUI/3D surface; a gateway-served web canvas solves a problem Aitvaras doesn't have |
| Voice | **Skip mechanism** | Their voice is companion-app-to-gateway plumbing; Aitvaras's local TTS/STT pipeline is already the native equivalent |
| Security posture | **Adopt lessons** | Prompt-injection payloads targeting assistants circulate in the wild (issue #30448) — treat all fetched web/message content as hostile input to the tool layer; Aitvaras's existing autonomy policy (read/reversibleWrite/confirmable) is precisely the "gradual trust" model the community converged on |

**The two highest-value takeaways:** (1) the *memory-flush-before-compaction* silent turn plus plain-Markdown-files-as-truth is the proven core of OpenClaw's memory — everything else (embeddings, dreaming, backends) is replaceable tooling around it; (2) proactivity that people keep enabled is *boring*: a checklist file, an interval, a one-token silence convention, active hours, and a cheap model — not autonomous initiative.
