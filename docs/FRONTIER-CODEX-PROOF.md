# Codex interactive text-only proof

This is a checkpoint-specific feasibility and isolation record, not a claim
that the complete interactive integration or authenticated provider path has
passed verification. The intended first scope is **no filesystem, shell,
browser, web, MCP, plugin or other external-action tools**. The native
`request_user_input` tool may remain; it does not itself authorize an action.

## Installed protocol and native evidence

The inspected CLI identified itself as `0.163.0-alpha.10.2`. Its experimental
JSON schema was generated locally, without a model invocation. Version alone
is insufficient: changes require renewed schema and behavioral checks.

- `thread/start` and `turn/start` support a named `permissions` profile.
- The installed legacy `SandboxPolicy.readOnly` has `type` and optional
  `networkAccess`, **not** the `access/readableRoots` fields shown in some
  current documentation. Never send those fields and assume enforcement.
- A native `codex sandbox -P <profile>` probe with `":root" = "deny"`,
  `":minimal" = "read"`, an explicitly readable synthetic directory, and
  `network.enabled = false` denied an outside file read and allowed an inside
  file read. It also blocked a controlled loopback HTTP request which succeeded
  outside the sandbox. `:minimal` includes some OS files; it is not zero read
  access, and `/etc/hosts` is not a suitable denied-read canary.
- A real app-server sent Responses requests to a synthetic loopback HTTP
  fixture. The fixture produced fixed SSE events, not model inference.
  An outer Seatbelt policy blocked non-loopback networking during this audit.
  No account, credentials, official model service or paid quota was used.
- With dedicated clean `HOME` and `CODEX_HOME`, the outgoing tool inventory
  contained exactly `request_user_input`. No seeded host/project/global
  AGENTS, skill or config-instruction markers appeared. The explicit base
  instruction marker did appear. Native environment/permission/mode context
  still exists; this is not a claim that the wire contains only user text.
  The authenticated export review must disclose that native environment metadata
  too. Choose non-personal scratch paths; an app-owned directory under a user's
  home can still reveal a username through the native working-directory context.
- A fabricated provider `exec_command` call was rejected with
  `unsupported call: exec_command`; its synthetic side-effect marker did not
  appear. A fabricated `read_file` call was likewise rejected with
  `unsupported call: read_file`. The fixture then completed a text response.
- In a deliberately contaminated synthetic home, global `CODEX_HOME/AGENTS.md`
  and a HOME-level skill catalog marker entered context despite
  `project_doc_max_bytes=0`, `skip_host_skill_discovery=true`, empty developer
  instructions and explicit base instructions. Therefore **host-context isolation
  and filesystem preflight are mandatory**. The Keychain correction below
  replaces the empty-HOME mechanism with an enforced filesystem boundary.
  Disabled synthetic MCP and hook marker files were absent. Hook trust was not
  established, so that alone does not independently prove every hook-disable
  path.

The fixture model lacked catalog metadata and the CLI used fallback metadata.
This proof covers that installed binary and fixture configuration. It does not
establish identical tool selection for every authenticated model/catalog.
Real authentication, available model selection, streamed live responses,
interrupt/resume, crash recovery and production packaging need their own
approved checks. The fixture HTTP provider override must never be shipped as
a runtime fallback.

## Tested launch controls

The fixture used `app-server --stdio` with the following known feature switches
set false through repeated `--disable <name>` arguments:

```text
apps hooks plugins remote_plugin shell_tool shell_snapshot shell_snapshot_v2
unified_exec view_image image_generation browser_use browser_use_external
browser_use_full_cdp_access computer_use code_mode code_mode_host code_mode_prewarm
multi_agent multi_agent_v2 memories skill_search skill_mcp_dependency_install
request_permissions_tool tool_suggest workspace_dependencies realtime_conversation
goals sleep_tool enable_request_compression api_key_model_discovery
```

Additional tested runtime-relevant `-c` overrides were:

```toml
web_search = "disabled"
analytics.enabled = false
feedback.enabled = false
features.skip_host_skill_discovery = true
project_doc_max_bytes = 0
developer_instructions = ""
skills.bundled.enabled = false
memories.use_memories = false
memories.generate_memories = false
default_permissions = "aitvaras_text_only"
permissions.aitvaras_text_only.filesystem = { ":root" = "deny", ":minimal" = "read" }
permissions.aitvaras_text_only.network.enabled = false
approval_policy = "never"
approvals_reviewer = "user"
```

`skip_host_skill_discovery` is under development and emitted a warning. It is
defense in depth, not the isolation boundary. The synthetic MCP test also
explicitly set its one known server's `enabled=false`; this is not a global
MCP-disable mechanism. Empty maps must not be assumed to erase inherited map
entries. Runtime must refuse inherited MCP/config instead of enumerating and
silently tolerating it.

The production profile uses the official OpenAI provider and official login,
not the fixture's provider, endpoint, model or service-URL overrides. Keep
provider selection and API-key environment variables out of user-controlled
turn input. Do not copy a native credential store or implement a token/API
fallback. The necessary official model/auth service network traffic is separate
from the disabled command-network permission.

Before implementing the authenticated path, require the native CLI's macOS
Keychain credential store in its dedicated profile. Aitvaras must not read,
copy, migrate or log credential files. The proof below uses no credentials.

On `thread/start`, explicitly send the owned scratch `cwd`, the named
`permissions`, `approvalPolicy="never"`, `approvalsReviewer="user"`,
`environments=[]`, `runtimeWorkspaceRoots=[]`, `selectedCapabilityRoots=[]`,
`dynamicTools=[]`, approved `baseInstructions`, empty `developerInstructions`,
and `allowProviderModelFallback=false`. Repeat the named permissions on each
turn/resume. Do not also pass legacy `sandbox`/`sandboxPolicy` values.
`dynamicTools=[]` alone does not disable native tools. The proof used ephemeral
threads; durable owned-session persistence and resumption remain separate tests.

## Preflight and ownership gate

Use private app-owned directories, no symlinks, and an allowlisted environment
with dedicated `CODEX_HOME`, working directory and temporary directory. `HOME`
uses the canonical OS user home only under the Keychain boundary below.
Do not inherit API keys, proxies, provider endpoints or native configuration.
Before loading a thread, refuse unexpected instruction/skill/plugin/config
files or changes in the owned profile; do not silently remove user additions.
Credential files must remain opaque to Aitvaras. Define the allowed native
runtime artifacts separately from configuration and instruction sources.

Read `config/read` with `{ "cwd": "<owned scratch>", "includeLayers": true }`.
The clean probe returned:

| Layer source | Observed raw config | Gate |
| --- | --- | --- |
| `sessionFlags` | Explicit fixture overrides | Exact approved override structure/values |
| `user` | Empty object (`{}`, two serialized bytes) at owned CODEX_HOME | Exact owned path, no profile; empty unless explicitly app-owned and reviewed |
| `system` | Empty object (`{}`, two serialized bytes) | Refuse nonempty or unknown external layers |

No project or managed layers were observed. Do not require the absence of an
empty system layer; the server reports it even when it contributes nothing.
Inspect raw `layers[].config`, not only typed `result.config`: the latter does
not enumerate all features, permissions, MCP or skill settings in this schema.
Also inspect `configRequirements/read`; unknown or incompatible managed
requirements must fail closed rather than being bypassed. A post-start read
does not prevent earlier startup effects, so owned-directory and known external
configuration checks belong before process launch too. Recheck before turns
and resume, and terminate on incompatible config changes.

Only session IDs returned by successful Aitvaras-owned creation belong in the
execution registry. Imported/native identities remain read-only and must fail
at the helper boundary if supplied to resume, turn, interrupt or mutation APIs.
The process owner must reap the complete process group on cancellation/quit.
Do not automatically retry a turn whose effects or terminal state are unknown.

## Prototype runtime follow-up

### Keychain persistence correction

An empty HOME makes Security.framework report no default Keychain, even after
successful browser OAuth. The corrected child uses the canonical OS user HOME
for Keychain discovery. An additional macOS process sandbox denies reads/writes
throughout that home except the dedicated owned profile, OS Keychain directory
and exact Keychain preferences file. Personal files, host instructions/skills
and native Codex configuration remain inaccessible. Existing thread permissions,
disabled tools and raw-config gates remain in force. No plaintext fallback or
token copying is used.

`scripts/check-codex-keychain.mjs` tests lookup and addition/deletion of a unique
nonsensitive fixture item with network denied. It also checks a denied private
home canary and allowed owned-profile read. It never reads existing items or
changes Keychain defaults. The synthetic-provider proof adds a shielded,
contaminated-HOME scenario and verifies its skill marker is absent from context.

The UI verifies the saved account and loads models after browser sign-in before
marking it ready. Native failure details are reduced to fixed safe messages.
The real OAuth retry remains a supervised user action.

The app-owned text prototype uses the same native version and additionally
checks hashes of the relevant generated protocol schemas before execution. This
is a compatibility gate, not a cryptographic claim about executable integrity.
The separate profile is Keychain-only and accepts an exact raw configuration;
unknown requirements, instruction/config files and symlinks are refused.

A deny-all-network unauthenticated native startup passed the production
configuration gate. Native startup ordinarily stages executable shims even with
shell tools disabled. The prototype pre-creates its empty shim directory and
uses an additional macOS write restriction to keep it empty; inability to apply
that restriction fails closed. Known native SQLite/runtime artifacts have an
explicit allowlist. No exception for arbitrary symlinks was introduced.

### Native runtime-artifact correction

The pinned CLI's unauthenticated status-only startup did not expose every
artifact needed by the later thread lifecycle. A network-denied native
`thread/start`, without login or `turn/start`, reproduced a false
`unsafeProfile` rejection from artifacts created by that same CLI:

| Artifact | Observed native type/mode/size | Additional gate |
| --- | --- | --- |
| `.sandbox_migration` | Regular file, `0600`, 3 bytes | At most 64 bytes; private and non-executable |
| `thread-writer-locks` | Directory, `0755`, inside private CODEX_HOME | Not group/other writable; no arbitrary nested directories |
| `thread-writer-locks/.coordination.lock` | Regular file, `0644`, empty | Empty, non-executable, not group/other writable |
| `thread-writer-locks/<UUIDv7>.lock` | Regular file, `0644`, empty while thread is active | Exact lowercase canonical UUIDv7 filename; same lock-file checks |

All new paths must be owned by the current user, must not be symlinks, and
regular files must have a single link. Marker/lock contents are not read.
The observed per-thread lock disappeared at native shutdown. Unknown filenames,
configuration, instructions, plaintext authentication, skills, hooks and plugins
remain rejected, including inside the lock directory. Existing private-root,
empty owned-home directory, immutable-shim and exact raw-config checks are unchanged.
This is a pinned-runtime exception, not permission to accept future native files
without review.

The helper suite now includes positive repeated-preflight cases plus negative
type, symlink, hardlink, mode, size and contamination cases (19 contract tests).
The native preflight performs two complete launches on the same synthetic
profile, creates one native thread per launch without sending a turn, and checks
preflight both with its writer lock active and after shutdown. Both rounds pass;
adding a synthetic `config.toml` afterward still fails before native launch.
This was also checked with a synthetic profile under the OS home in a path
containing spaces, exercising the production home-isolation boundary.

Repeat without credentials or model traffic:

```sh
node scripts/check-codex-interactive.mjs
node scripts/check-codex-interactive.mjs --native-preflight /absolute/path/to/codex
node scripts/check-codex-interactive.mjs --native-preflight /absolute/path/to/codex --profile-in-home
```

Only disposable fixtures are created/removed. The native test denies all network
access and rejects any login, turn, model-list or quota RPC. It never opens the
real application profile or reads credentials/private transcripts. This verifies
runtime-artifact compatibility, not real account recovery, authenticated turns,
or persistence artifacts that may appear only after a real model response.

The helper's synthetic contract tests exercise new-session acknowledgement,
owned-only resume, early stop (including request/stop in one input chunk), actual
interrupt acknowledgement, model mismatch, action-item rejection and quota
metadata. Swift transport fixtures additionally exercise small streaming frames,
split UTF-8, rejected binding callbacks and sanitized malformed-frame errors.
Those fixtures use no real Codex account or provider. App-level fixtures verify
durable state and context isolation, not live provider correctness.

`account/rateLimits/read` supplies account quota when available; per-turn token
counts come separately from native usage events. Missing values remain
unavailable. Setup/sign-in/send are explicit actions; there is no idle native
process or automatic account polling. A stale process lock fails closed rather
than assuming an earlier uncertain operation can be replayed. Recovering an
abruptly orphaned lock remains supervised work, not an automatic retry path.

Authenticated sign-in, model/tool inventory, browser return and native persisted
multi-turn operation remain unverified until a separately approved live check.
The prototype does not support native tool questions, approvals, files or edits;
server-initiated action requests are rejected rather than granted automatically.

## Official account and model methods

The installed schema exposes:

- `account/read`: `GetAccountParams`, use `refreshToken=false` for a status
  check. Do not dump account payloads into logs.
- `account/login/start`: `LoginAccountParams`; official ChatGPT flow accepts
  `{ "type": "chatgpt" }`. The `chatgptAuthTokens` variant explicitly says it
  is internal-only and must not be used. Login is a separate user action into
  the dedicated profile; never migrate native tokens.
- `model/list`: `ModelListParams`, optional `cursor`, `limit`, `includeHidden`.
  Preserve available model IDs/efforts; do not invent availability or fall back
  to a different provider when a choice is unavailable.

## Repeating the isolated proof

The checked-in manual fixture runs the native wire/context and fabricated-tool
tests without any live model service:

```sh
node scripts/check-codex-text-isolation.mjs /absolute/path/to/codex
```

It creates and removes its own temporary profiles, restricts the native server
to loopback networking with Seatbelt, uses fixed SSE responses, and reports
structural results only. It fails on unexpected credential headers, changed
tool inventory, context canaries in the clean profile or unexpected side effects.
It does not perform authentication or establish production readiness. The model
identifier is a fixture input, not an availability or account-entitlement claim.

Use a new ignored scratch directory, with synthetic `home`, `codex`, `project`
and `temp` directories. Resolve the installed executable at runtime; do not
copy installation-specific paths into checked-in fixtures.

1. Generate the installed app-server JSON schema into scratch. Verify required
   methods, named-permission fields and feature names before launching.
2. Seed unique nonsecret markers in synthetic HOME skills, global/project
   AGENTS and config instructions. Place hook/MCP side-effect destinations
   only inside scratch. Keep a separate completely clean HOME/CODEX_HOME pair.
3. Start a loopback-only HTTP fixture with a synthetic Responses provider that
   requires no authentication. Restrict the app-server's external networking
   for the audit. Never pass native credentials or an API key. Reject all
   unexpected fixture routes and bound runtime/output.
4. Initialize, inspect raw config layers, create an ephemeral synthetic thread
   using the controls above, and send one synthetic text input. Capture only
   tool names, marker presence and structural assertions, not private account
   or configuration values. Return fixed SSE message/completion events.
5. Assert only `request_user_input` is advertised, approved base text appears,
   and no seeded marker appears with the clean home. Record the contaminated
   home's leakage as a negative control, not a passing isolation result.
6. In separate runs, return a fabricated `exec_command` and `read_file` function
   call, then a fixed text completion. Assert the native unsupported-call
   outputs and absence of synthetic side effects. Kill/reap all processes.
7. Independently repeat native command read/network canaries with the same
   named permission profile. Preserve failure evidence; never silently replace
   an unsupported restriction with ordinary read-only/full-read mode.

Sources: [app-server](https://learn.chatgpt.com/docs/app-server),
[permission scope and enforcement](https://learn.chatgpt.com/docs/permissions),
[hooks](https://learn.chatgpt.com/docs/hooks),
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
The installed schema and observed behavior take precedence where documentation
and binary differ.

## Thread-history runtime regression

The first authenticated chat preparation creates `thread_history_1.sqlite`
and its `-wal`/`-shm` companions. Account-status and no-model startup checks did
not cover this artifact. The pinned runtime allowlist now accepts only this
exact database version, retaining owned regular-file, single-link and
no-symlink checks. Unknown versions and configuration files remain refused.

The helper suite has 21 passing contracts, including creation during
`thread/start`, completion, repeated startup, and negative link/version checks.
With explicit user approval, one real provider turn used synthetic context and
the prompt `Reply only OK`, without files or prior chat history. It reached
`completed` and returned `OK`. No failed user prompt was replayed. The profile
error wording no longer claims that a turn was never sent when delivery may be
uncertain.

## Optional brokered project reads

The native Codex sandbox remains unchanged: no project filesystem grant, shell,
writes, web, MCP or arbitrary tools. An explicit **Read project files** switch
in Project settings grants two app-controlled dynamic functions: list and read.
Existing metadata-only folder registrations do not acquire this permission.
The grant is bound to the saved policy revision; changing that revision creates
a fresh backend thread and invalidates the old grant unless explicitly saved.

Each turn pins approved root directory descriptors. Relative traversal uses
`openat` with `O_NOFOLLOW`; symlinks, hardlinked files, hidden entries, credential
names, broad roots and non-UTF-8/binary data are rejected. Limits are 16 roots,
32 requests, 200 visible entries per listing, 64 KiB per file and 512 KiB per
turn. Returned text is untrusted project data, not a permission instruction.
Only successful tool metadata—not file contents—is added to Activity history.
Tool results go to OpenAI only in a user-started turn under that saved grant.

The helper binds each owned provider thread to a hash of its approved roots,
rejects scope-changing resumes and unexpected function calls, and discards tool
results after cancellation. Token/context gauges use native structured fields;
missing limits remain unknown. Quota windows use validated provider percentages
and Unix reset timestamps, never text parsing or inferred denominators.

Current code-mode-only models need the functions grouped in the
`aitvaras_project` namespace with that namespace configured as direct-only in
`features.code_mode`. The JavaScript host remains disabled. The native loopback
proof checks that both functions are advertised directly and that a synthetic
read crosses the app-server callback boundary without enabling shell or writes.
This is a tool-exposure compatibility setting, not an expanded native sandbox.
Model metadata can also select the V2 agent runtime despite boolean feature
flags. `features.multi_agent_v2.disable_native_tools` explicitly suppresses its
native tools; the loopback proof confirms an injected spawn call is rejected.
With explicit approval, a live turn using synthetic context and one temporary
file successfully invoked the broker and returned the exact generated marker.
No personal files or chat history were supplied. The earlier failed probe made
no file read and was not replayed automatically.
