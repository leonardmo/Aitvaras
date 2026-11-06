# Unified chat: technical plan

Goal: Aitvaras's Chat tab works like the Claude Code and Codex apps, with one
click to switch between Claude, Codex and local models, and sign-in that is at
most one click. Product intent comes from `docs/NEXT-WORKSPACE-PLAN.md`, D30, D32 and
the maintainer's UI feedback. This document replaces the *technical* approach of
`docs/CLAUDE-INTEGRATION.md` and `docs/CODEX-BIDIRECTIONAL-INTEGRATION.md`.

## 1. Why the last attempt failed

Measured on 2026-11-04 with the installed CLIs:

| Finding | Evidence | Consequence |
|---|---|---|
| Claude sign-in failure has a concrete cause. The adapters build an allowlisted environment without `USER`. | `claude -p` with HOME+PATH only: "OAuth session expired". Same command plus `USER`: answers. The Keychain holds a second credential item under account `unknown`, last changed at the time of a failed sign-in, so those runs apparently wrote it. `claude auth status` reports logged in either way. | Sign-in "succeeded" into a stale, separate slot, and the status check could not see it. |
| A direct connection is simple. | A throwaway script of about 60 lines drove `codex app-server` over stdio using the existing login: streaming, command approval, second turn, in 10 s. The Claude CLI answered stream-json input and the control protocol directly, with no Node or SDK. | Node helpers, the SDK download, the WebSocket proxy and separate profiles are unnecessary. |
| All tests were synthetic. | 601 tests passed while the first real "hello" failed. Project rules made real provider runs a separate, rarely run gate. | Green tests said nothing about the product. |
| Screenshots could not catch UI bugs. | `--uishot` renders offscreen: headings and icons are invisible in the output, and `TESTING.md` already warns about it. | No one, human or agent, saw the real UI before delivery. |
| Too many parallel paths. | Three adapters, three workspace models, per-provider link and consent views, and Claude with no shell or edit tools at all. | Slow to change, complex to use, and not "the same actions". |

## 2. Principles

1. **Drive the official CLIs directly, with their own default login and stores.**
   No separate profiles, no token handling, no API keys. Chats then exist natively
   in Claude Code and Codex, so there is nothing to sync or link.
2. **One backend protocol, one event stream, one UI.** Provider differences stop
   at the backend.
3. **The provider's own permission system does the enforcing.** Aitvaras presents
   its requests as inline cards and logs them; it doesn't build a second sandbox.
4. **Real first.** Nothing counts as done until it has worked in the real app,
   through real clicks, against the real CLI.
5. **Reuse what works.** `claude-workspace` has a tested process layer, stream
   parser, git layer and changes panel. Port the files, not the history.

## 3. Architecture

New SwiftPM target `AitvarasAgents` (actors, Swift 6 strict, no Node):

```
ChatView ─ ChatModel (@MainActor) ─ AgentSessionManager ─┬ ClaudeBackend  claude -p stream-json + control protocol
                     │                                   ├ CodexBackend   codex app-server, stdio JSON-RPC
                     │                                   └ LocalBackend   decided at gate M4
                     └ transcript store, autonomy policy, activity log
```

- **`AgentBackend`**: `status()`, `signIn()`, `models()`, `start(...) -> AgentRun`,
  `listSessions(folder:)`, `readHistory(session:)`.
- **`AgentRun`**: `events`, `send`, `respond(approval:)`, `setMode`, `interrupt`.
- **`AgentEvent`**: session started, text and thinking deltas, tool started,
  output and finished, file changed with diff, approval request, plan proposed,
  question, usage, and turn ended with an outcome.
- **`AgentFailure`** is typed: `authRequired`, `quota(resetsAt)`, `offline`,
  `notInstalled`, `crashed`, `unknown`. Claude can report `subtype: success` with
  `is_error: true`, so outcomes come from the error fields.
- **`ProviderEnvironment`** is the one place that builds a child environment: the
  app's inherited environment plus the login-shell `PATH`, **minus a denylist** of
  credential and endpoint overrides (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
  `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `CODEX_HOME`,
  `CLAUDE_CONFIG_DIR` and similar). Tests may set the last two explicitly. An
  allowlist caused the bug, and it also hid Homebrew tools from the agents.

**Sign-in.** Opening Chat checks status locally and sends nothing. If the CLI is
already logged in, there is no sign-in step at all. Otherwise a failed send, or
the provider row in Settings, shows one button: Claude runs `claude auth login
--claudeai`, Codex uses `account/login/start`. The browser opens, the app notices
completion, and a message that certainly never left (`authRequired`, zero cost) is
sent automatically. `auth status` is treated as a hint; a real send decides.

**Data.** Aitvaras keeps D30's single transcript per chat: additive tables for a
chat's per-provider native session and normalized entries. Old tables are kept,
and old chats stay readable. Switching provider and pressing Send carries the
catch-up block from D30. Interrupted turns are marked as such, and the next Send
resumes the native session. Only a message that certainly wasn't delivered is ever
resent automatically.

Legacy read compatibility (M5.5) projects saved local, owned and linked evidence
without rewriting source rows or adopting their session identities. Separate
provider profiles need not exist to read saved text; credentials are never moved.
Imported snapshots appear as collapsed read-only groups in the transcript, with
their original message IDs and current revisions. They remain excluded from
provider catch-up. Existing import controls retain access to saved-source details.
Project conversation ownership and capture targets remain unchanged, including
the guard against extracting project chats into global memory.

**Projects (D32).** Every new chat belongs to a project; there is no project-less
chat or automatic catch-all workspace. A project is a set of folders with
instructions and a default permission mode. A folder also used in Claude Code or Codex is the same project
automatically, with no link step. Native sessions for that folder appear in the
project's chat list and can be continued directly with `--resume` or
`thread/resume`. claude.ai chats have no supported interface and stay out.

**Permissions and hard rules.** Modes: Ask, Accept edits, Plan, Auto, mapped per
provider. Full access isn't offered in this version. Every request reaching the
user becomes an inline card, a `Suggestion` and activity-log entries with
provenance (`read`, `reversibleWrite`, `confirmable`). Keeps D20, the Keychain
rule and no API-key fallback.

**Local models.** LocalBackend (the existing AgentLoop adapter) remains the
default until the host M4 gate passes. `AITVARAS_LOCAL_CHAT_BACKEND=codex-oss`
explicitly selects the candidate for Local; unset or `agent-loop` keeps the
default. Unknown values fail startup. It launches `codex app-server` with
`-c model_provider='"ollama"'`, `-c local_provider='"ollama"'`,
`-c model_providers.ollama.base_url='"http://127.0.0.1:11434/v1"'` and
`-c model_providers.ollama.requires_openai_auth=false`. These config overrides
are the app-server equivalent of the interactive CLI's OSS selection.

Status/model discovery reads only Ollama's local `/api/tags`; it never loads or
pulls a model. Missing service or no eligible models reports unavailable.
The model menu requires an explicit choice. Send requires an installed,
explicitly named model, excludes cloud/remote models, and validates the server's
model/provider before releasing input. There
is no subscription login, implicit default model or cloud fallback on this path.
The candidate uses ephemeral threads with Local's completed context on every
Send; native history/resume, follow-ups, attachments, commands, file completion
and reasoning-effort selection remain unsupported. Tools, approvals, thinking,
plans and questions reuse the Codex protocol and action coordinator. The host
gate must still establish actual tool reliability, locality and memory use.

## 4. UI rules (acceptance criteria)

From the maintainer's feedback; a violation fails review.

- Layout as in the Codex and Claude Code apps: sidebar with projects and chats
  (status dot per chat), transcript in the centre, changes panel on the right that
  appears only when there are changes.
- Chat with no selection and New Chat open the empty unified transcript and ready
  composer immediately. First Send creates the chat; there is no creation dialog.
- The flat project menu (`chat.project`) sits beside the provider/model controls.
  Selection order: explicitly requested project, optional default, most recently
  used visible project. “Add project…” is the last item and opens the folder picker.
  With no projects: “Choose project”, disabled Send, one short explanation.
- Default project starts unset, is stored per profile and has one project context
  item (“Set as default” / “Remove as default”) and a small row marker. Hiding or
  removing it silently unsets it.
- Projects stay expanded with chats directly underneath. One click opens any chat,
  including in another project, without an intermediate selection or reload flash.
  Selection remains highlighted and visible. Each project shows five recent chats
  plus all running/waiting chats and the selected chat; “Show more” / “Show less”
  (`chat.project.<id>.more`) reveals the rest. A project's + opens its new composer.
- Old project-less conversations are only reached through the bottom “Earlier
  chats” reader group, collapsed behind “Show more” and hidden when empty. Keep
  `LocalChatView`, voice and the companion.
- Composer holds everything per-chat: provider switcher (Claude, Codex, Local),
  model, effort, permission mode, gauges for context and usage.
- Status is gauges and icons, not sentences. No walls of text. Sidebar icons reuse
  M3.12: animated running, prominent accent needs-you, filled dot for completed/unseen,
  failed, interrupted; idle/seen has none. Each has an accessibility label and
  `chat.sidebar.<id>.status.<state>`. Opening a chat clears its persisted unseen
  receipt; a turn completing while visible remains seen. The main Chat icon is
  badged whenever any chat needs approval, a plan decision or a question answered.
- New provider defaults to the last used. Fresh profiles choose Local unless no
  local model is available and a signed-in provider exists. Signed-out providers
  stay selectable; Send offers the existing single sign-in action.
- Setup has a visible “AI providers” card (`settings.providers`) opening provider
  settings.
- At most one popover level. No sheet on top of a sheet.
- No start or connect buttons. No "check setup". No consent checkboxes. Nothing
  like "conversation" as a concept separate from chat. No link, boundary-review or
  account-mode screens.
- Provider settings: one row each in Settings with status, gauge and sign-in.
- Errors appear once, inline, with the single action that fixes them.
- Native Liquid Glass, Apple HIG, light and dark, usable at minimum window size,
  full keyboard support, no layout jumps during streaming.

## 5. Same actions as the native apps

Streaming with thinking; tool runs with expandable input and output; file edits
with diffs; inline approvals; plan mode with an approve card; questions from the
agent; Stop; follow-ups while running; slash commands from the CLI's own list;
`@` file mentions; image and file attachments; native skills, MCP and project
instructions; git worktree per chat; changes panel with commit and discard;
several chats running in parallel and in the background; resume after restart;
context and quota gauges; rename and archive.

Chat lifecycle (M3.12): closing the window only detaches its observers; runs
belong to the application. Sidebar icons distinguish running, needs-you, completed/unseen, failed
and interrupted chats, with durable last-seen tracking (D32). Rename and archive edit the shared chat's local metadata,
preserving every provider session and transcript. Archive does not stop active
work or expire approvals; Stop and replies remain available, and new messages
require Restore. Running chats cannot expire automatically. Pending permission,
plan and question cards wait without a timeout until answered, stopped, resolved
or cancelled by the provider, or cleared on process exit. Send and turn end
update activity ordering without unarchiving a chat. Quit journals active and
queued inputs as interrupted before disposing runs; startup recovers crash
leftovers without sending. The next explicit Send resumes the saved native
session with new input, never replaying the interrupted input. An interrupted
icon occupies the composer's existing status space; an archived chat offers
Restore there. Native rename/archive propagation is outside this shared-chat
metadata operation.

Git (M3.9–M3.11): the unsaved composer's project picker has a small **Use
worktree** button control beside it only for a git project, off by default. Ownership, primary cwd and additional folder
mappings survive restart; failed creation blocks Send instead of using the original
checkout. The right inspector appears for changed files and shows a file list,
unified diff, commit message and Commit. The entered message goes directly to git,
with normal hooks and no added attribution. Discard has one native confirmation
and restores only the selected chat's verified owned worktree. It leaves the
worktree, branch, ignored files and other checkouts in place. Ordinary checkouts
support Commit; Discard is unavailable there. Binary/large files remain listed
with an unavailable preview. Refresh and mutations reject command failures and
stale snapshots. Worktree creation currently requires an existing HEAD commit.

Composer inputs (M3.7/M3.8): drag, paste or the paperclip adds removable file
chips. Selection snapshots the bytes; subsequent source edits do not change a
Send or a safe sign-in retry. Up to eight files share a 512 KiB budget to fit
the bounded CLI frame. Both providers accept UTF-8 text and PNG/JPEG/GIF/WebP;
Claude also accepts PDF. Local's current text-only adapter disables attachments.
Attachment bytes never enter a provider-switch handover. Unsent selections are
scoped to the chat and provider.

Typing `@` opens one searchable project-file popover; choosing a file explicitly
inserts a quoted mention. Codex uses `fuzzyFileSearch`, Claude a bounded local
folder search. Typing `/` opens the same flat picker for the native CLI catalog:
Claude initialize commands or enabled Codex `skills/list` entries for this cwd.
Codex selections insert `$skill` and include the native skill input. Missing
catalogs show unavailable; no fallback command list is invented. Escape cancels,
arrows select and Return inserts; selection never sends a message.

Follow-up delivery (M3.5): Claude receives additional `user` frames on stdin
and queues them in submission order. Codex receives `turn/steer` with the active
`expectedTurnId`; steering does not replace the output owner. Each input has its
own durable delivery state. Send remains beside Stop, and queued inputs show
“Queued” until activated. Busy rejections before delivery retain the active turn.

Stop (M3.6) waits up to 1.4 seconds for a native turn end, then disposes an
unresponsive transport with a bounded cleanup grace. Interrupted inputs keep
partial output, delivery evidence and the native session identity. The next
explicit Send resumes that session; queued/uncertain inputs are never replayed
automatically. A forced Codex transport disposal also interrupts other runs on
that app-server connection; an acknowledged Stop leaves them running.

## 6. Testing

Each layer catches what the one below can't.

| Layer | What runs | Where | When |
|---|---|---|---|
| **Unit and contract** | Parsers and state machines against **recordings of real CLI output** plus garbage input. | Codex sandbox, CI | Every task |
| **Fake-CLI process tests** | The real process code against scripted executables: crash, hang, huge output, quota, revoked login, partial lines. | Codex sandbox, CI | Every task |
| **Backend conformance** | One scenario suite, parameterized over every backend: send, stream, tool approve and deny, stop, resume, two turns, failure typing. Fake in CI; real with `make live`. | Fake everywhere; live on host | Live at every gate and after CLI updates |
| **Environment regression** | Live conformance launched from a launchd-style environment, plus a test that `USER` survives and denied variables don't. | Host | Every gate |
| **Sign-in** | With temporary `CLAUDE_CONFIG_DIR` and `CODEX_HOME`: signed-out detection, login start yields a valid browser URL, cancel. Real browser completion once, by the maintainer. | Host | M2, M6 |
| **Real-app E2E** | New XCUITest target: launches the real app with an isolated profile, real clicks and typing, **real window screenshots**. Fake CLIs for determinism, real ones for the golden path. | Host | Every UI task |
| **Visual review** | Supervisor reads real screenshots against section 4 for a state matrix: empty, long, streaming, approval, error, signed out, light, dark, minimum size. | Supervisor | Every UI gate |
| **Golden path** | The acceptance script in section 8. | Host | M2 onward; before delivery |
| **Migration** | Open a copy of the real DB with the new build, check old chats. The copy never leaves the machine or enters git. | Host | M5, M6 |

Live runs use the cheapest model of each provider in a temporary folder, with
session persistence off where possible. The fake and real CLI share one process
path, and the fake is selected only by an explicit test variable.

Codex has no network, home folder or Keychain in its sandbox. So it builds against
fakes and recordings, and the supervisor runs the live, app and E2E layers on the
host and feeds failures back. The supervisor's gate is the source of truth, not
the worker's report.

## 7. Milestones

Each ends in a gate the supervisor runs. Work isn't presented until its gate passes.

| | Delivers | Gate |
|---|---|---|
| **M0** | Plan review by Codex. Seed port from `claude-workspace`. `AitvarasAgents` target. XCUITest target proven with a real-window screenshot. `make live`, `make e2e`, harness support. | E2E test clicks through the current app and yields a true screenshot. |
| **M1** | `ProviderEnvironment`, Claude and Codex backends, conformance suite, recordings, CLI schema check. No UI. | Live conformance passes for both from a launchd-style environment. |
| **M2** | New Chat screen, vertical slice: sidebar, transcript, composer, provider switch, inline sign-in, gauges. | Golden path steps 1–5 on real CLIs; visual review. **Maintainer's one checkpoint: try it before the rest is built on it.** |
| **M3** | All of section 5. | E2E for each action, both providers. |
| **M4** | Local gate decided, `LocalBackend`. | Conformance plus golden path on a local model, within the memory budget. |
| **M5** | Native sessions in project lists, continue both ways, provider-switch catch-up, transcript migration. | Chat started here continues in the native CLI and back; DB-copy migration. |
| **M6** | Remove old adapters, Node helpers, link and consent views, SDK download, old models. Update D14, D30, new D31, `TESTING.md`, `ARCHITECTURE.md`; mark the old integration docs as superseded. | Full golden path, full test suite, one PR. |

Out of scope, kept possible by the design: shared project knowledge service, capture
discussion, usage ledger, supervisor continuation inside the app, phone dashboard.

## 8. Golden path

Disposable project, isolated app profile, real CLIs.

1. Launch the app; Chat opens the unified composer with no setup step or dialog.
   Without projects, verify “Choose project”, disabled Send and the short hint.
2. Add a project on a temp git repo; New Chat writes no record until Send. Send
   “Reply with only this word spelled backwards: nacilep” on Claude; verify
   “pelican” in `chat.transcript`, never in the whole window.
3. Switch to Codex with one click; send “Which word did you just reply with? Reply
   with only that word, in capitals.” Verify case-sensitive “PELICAN” inside
   `chat.transcript`.
4. Switch to Local; send; reply.
5. With a signed-out temp profile: Send shows one sign-in button; the browser URL
   is correct; after sign-in the message goes out by itself.
6. Ask for a file edit in Ask mode: card appears; deny is respected; approve works;
   diff appears in the changes panel.
7. Ask for a shell command: card, approve, output in the transcript.
8. Plan mode: plan card, approve, it executes.
9. Stop mid-stream: stops within 2 s; the next message continues.
10. Two chats running at once; one click switches between them without losing
    text, including across projects. Send six chats through the composer to expose
    Show more. Expand/collapse it; running/waiting and selected chats remain visible.
    While approval is pending, verify its sidebar needs-you icon and Chat badge.
11. Quit during a turn; relaunch; chat is marked interrupted; next Send resumes the
    same native session.
12. Open that chat in the native CLI; it is there and continues; back in Aitvaras
    the new messages appear.
13. Activity log shows the chain with provenance. No API key was used. Open Setup's
    AI providers card before the final settings screenshot.

The debug-only in-process self-driver accepts `AITVARAS_SELF_DRIVE_PROJECT` as an
existing disposable folder. After isolated bootstrap it registers that project
before running the scenario; it seeds no chats or approval states. The scenario
creates its six chats through real Send. `$project` resolves to that project ID;
`$chat1`, `$chat2`, etc. refer to chat IDs observed in selection order during the
scenario, allowing assertions against real sidebar rows without fixed UUIDs.
`waitFor.within` bounds traversal to the named accessibility subtree and
`caseSensitive` defaults to false. Missing subtrees cannot satisfy positive checks.

Native menu tracking is outside the in-process driver's reliable press surface
(`picker-probe.json` tests that boundary separately from the golden path):
project/model/mode/effort menus fail explicitly and require XCUITest for opening
and selection. Keep tree dumps of both `chat.provider` and `chat.project`; the host
must verify whether segmented provider items expose their identifiers and accept
presses. If they do not, the smallest honest alternative is an XCUITest click on
the actual segment/menu item, followed by the same transcript assertion. Never
replace an unsuccessful press with a direct model mutation.

## 9. Running Codex

The harness in `.claude/skills/supervise` on branch `codex/unified-chat`: small
tasks, supervisor reviews each diff and commits; `run` exits 75 at a usage limit,
`wait-limit` waits for the reset, then the same session continues. Credits are
never bought. If a task fails review three times, the supervisor changes the
approach or does it directly. One PR at the end; the maintainer merges. The
installed app isn't replaced without asking, and never during a recording.

## 10. Risks

| Risk | Mitigation |
|---|---|
| CLI protocols change (`app-server` is labelled experimental; the control protocol is the SDK's). | Unknown events kept and ignored; recordings and schema check flag drift; `make live` after CLI updates. Failures appear as typed errors. |
| Anthropic's docs bar third-party developers from offering claude.ai login or limits in their products without approval. | Aitvaras holds no login: it runs the official CLI for its owner. Treat this as personal use, and revisit before distributing builds. No "Claude Code" branding in the UI. |
| Parallel use of one session in two clients. | Separate chats are fine. Aitvaras only holds a session during a turn and re-reads after; it doesn't claim a lock. |
| XCUITest needs a one-time macOS permission. | Supervisor asks once, at M0. |
| A local model may be too weak for agent work. | Gate at M4 with a defined fallback. |
| Usage limits stretch the calendar time. | Automatic waits. Time is hard to predict until M1 shows the burn rate. |

## 11. Results of the plan review and CLI checks (2026-11-04)

Codex reviewed this plan against the code; the supervisor then checked the open
questions against the real CLIs. These override earlier sections where they differ.

**Verified on real CLIs** (recordings in `Tests/AitvarasCoreTests/Fixtures/agents/`):

- **Claude, hard rule on side effects:** `initialize` can register `PreToolUse` and
  `PostToolUse` hook callbacks. They fire before every tool, also when `can_use_tool`
  doesn't fire because of Accept edits or the user's allow rules. So
  `AgentActionCoordinator` sees, can deny and logs each action before it runs.
- **Claude, other:** `initialize` returns models, slash commands and account;
  `rate_limit_event` carries 5-hour and 7-day utilization for the gauges. Plan
  approval and questions arrive through `can_use_tool`. Interrupt ends the turn at
  once with `error_during_execution`. Signed out gives `assistant.error:
  authentication_failed` plus `result` with `subtype: success, is_error: true`.
- **Codex, hard rule on side effects:** the sandbox enforces limits and approvals
  come as server requests. `untrusted` asks for commands; `on-request` with
  `workspace-write` writes inside the workspace without asking (the policy's
  `reversibleWrite`); `read-only` wrote nothing. Item events feed the log.
- **Codex, other:** full `thread/*` API including list, read, resume, fork, name,
  archive, `turn/steer`, `fuzzyFileSearch`, `skills/list`, `account/rateLimits/read`.
  `account/login/start` returns a browser URL and works with a temporary `CODEX_HOME`.

**Plan changes from the review:**

1. `AgentActionCoordinator` (new) is the single place for policy and audit before a
   provider action runs. A `Suggestion` alone can't answer a CLI, so it holds a scoped
   reply handler, expires on exit, and rejects duplicates.
2. Persistence comes before the UI: new tables, because existing owned-session tables
   and triggers require tool-free context and immutable settings.
3. A durable turn journal with explicit delivery states. Automatic resend needs proof
   of non-delivery recorded in that journal, not zero cost.
4. `AgentSessionManager` owns chats per chat. Today's one-active-turn models and the
   global selection lock can't support parallel chats.
5. Seed code isn't copied blindly: the process layer has a timeout deadlock and
   unbounded buffers, the parser keeps only the first content block, unknown control
   requests get a false success, the git layer force-removes.
6. M2's gate needed M4 and M5 parts, so minimal catch-up and today's Local path move
   into M2. Note today's Local mode is text-only in project chats.
7. Environment-only checks can't exclude configured credential helpers or endpoints.
   Check `apiKeySource: none` and first-party status at session start and refuse
   otherwise. Same for Codex's account type.
8. Provider-run guards: `AITVARAS_UI_TEST_MODE` and the disabled-integrations flag
   block all clients today. Add a separate, explicit test configuration that allows
   providers and keeps personal connectors off.
9. Native identity includes host and profile, not just folder; worktrees map to their
   chat through durable ownership records. Conflicts are shown, not merged silently.
10. Keep working: companion, voice, shortcuts, capture targets, memory-archiver project
    isolation, Activity Stop, quit coordination, the four `CloudAgentService` features
    and saved native evidence. Replace history readers before deleting the SDK.

**Task list:** the review's M1.1 to M6.4 table, stored at
`.build/agent-recordings/tasks.md` next to the worktree build output.

