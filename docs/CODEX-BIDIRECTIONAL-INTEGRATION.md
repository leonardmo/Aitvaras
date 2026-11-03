# Native Codex project and chat integration

Status: native project/chat linking, canonical history, native execution,
streaming, approvals and recovery implemented. The installed app is not replaced
while a recording is active. Existing isolated chats and read-only imports stay
separate; they are not silently adopted into native threads.

## Product outcome

One native Codex thread is the source of truth for each explicitly linked Codex
chat. Aitvaras and Codex desktop display and continue that identity; they do not
copy independent transcripts back and forth. Aitvaras retains its logical
project/chat identity, provider-attributed Local/Claude segments, capture links
and an observed cache of native items.

The provider button is named **Codex**. Connecting projects or browsing history
must never send a prompt, resume uncertain work or grant file access implicitly.

## Project and folder contract

- Identify a link by provider, host, profile namespace and native project ID,
  not its title or folder name. Account changes invalidate verification without
  storing tokens or account identifiers in fixtures or documentation.
- Preserve the native project's ordered roots and explicitly record the thread's
  working directory. The installed project schema has no primary-root flag;
  neither array order nor alphabetic order establishes execution cwd by itself.
- The linked Codex workspace has the same approved primary and secondary roots
  in both clients. Extra Aitvaras-only sources remain separate and are not
  silently attached to Codex.
- Compare canonical paths and filesystem identities where available. Missing,
  moved or retargeted folders require review; never substitute their parent.
- A Git worktree is a distinct execution location associated with its
  repository. Do not replace it with the main checkout just because the Git
  remote matches. The same path on two hosts is not the same location.
- Prefer the existing native project as the initial folder authority. Linking
  shows one compact folder difference view. A deliberate Save can apply a
  supported native project update; unexpected external changes produce a
  conflict/review state rather than silently widening access.
- Native project updates currently have no expected-revision field in the
  installed schema. Read/compare/write/verify is not atomic CAS. Do not advertise
  race-free concurrent project editing; preserve both observations on conflict.

## Installed capability evidence

The inspected CLI is `0.163.0-alpha.10.2`. Generated schemas expose:

- `project/list`, `project/read`, `project/create`, `project/import`,
  `project/update`, `project/move` and `project/delete`.
- Multiple project roots, native project IDs, `thread/start.projectId`, project
  filtering and `thread/metadata/update.projectId`.
- Paged native turn/item history, thread status and streamed updates.
- Shared/local app-server transports; actual desktop connection discovery and
  cross-client behavior still need a disposable-profile compatibility proof.

Schema availability is not proof that every desktop integration path is public,
stable or works across releases. Capability checks must fail visibly and retain
history rather than fall back to provider database/configuration patching.

### Delivered protocol proof

`scripts/check-codex-shared-workspace.mjs` passed against the inspected native
CLI using two WebSocket clients, a temporary profile and fixed loopback Responses
fixtures. It verified:

- Native project creation, read and updates across both clients, including root
  order and project-change notifications.
- An explicitly chosen thread cwd different from the first project root.
- One canonical thread resumed by the second client, with two synthetic turns
  and identical paginated native turn IDs from both clients.
- A native chat rename visible from the other client.

The proof made two local fixture requests, zero live provider requests, used no
authentication, and changed no production profile. It did not prove busy-turn
handoff, restart recovery, worktree transfer or arbitrary dynamic-tool portability.

The native CLI exposes `app-server proxy`. It forwards **raw WebSocket bytes**,
not JSONL protocol messages. The native adapter performs HTTP Upgrade and bounded
RFC6455 framing over the proxy, letting the CLI resolve its own control socket.
The real local daemon has passed initialize plus bounded project metadata reads
through this adapter. No model prompt is required for connection checking.

Desktop shared-daemon mode is conditional in the inspected build. Its simple
enable flag is insufficient when desktop configuration overrides are present.
The packaged explicit WebSocket route supports a local Unix socket. Configuring
that route and restarting **only Codex** requires explicit permission. Local
socket ownership/mode are checked; a shared endpoint is not cryptographic desktop
attestation. The transport remains experimental and version-sensitive.

### Project relationship checkpoint

- Project settings has a single-level **Codex link** tab. Browsing uses the
  official read-only project APIs; selecting a project rereads its metadata.
  Linking rereads it again and checks the reviewed folder observations before
  saving a local relationship. No native project is changed.
- Separate additive tables store profile/host-qualified project and chat
  relationships, approved and observed ordered roots, canonical filesystem
  observations, local revisions and optional native-configuration consent.
  Existing imports and isolated sessions are not migrated or adopted.
- Different profiles, missing/retargeted roots and changed native metadata
  require review. Local unlink removes only the relationship. It does not
  archive/delete native chats, alter local folders or grant native tools.
- The separate shared-runtime probe accepts an explicitly supplied literal
  loopback WebSocket endpoint. It sends only initialize/initialized and a
  bounded project-list request, rejects server action requests, and has bounded
  timeout, cancellation and wire limits. It cannot start a native server.
- A reachable endpoint is explicitly **not** desktop attestation. The inspected
  handshake has no stable runtime identity; the probe reports identity unknown,
  desktop attachment unverified and continuation unsupported. Its advanced
  field is diagnostic, not an instruction to run a second writer.

The chat settings now link an existing native chat or prepare an empty native
chat with an explicit working folder. Effective sandbox, writable folders,
network access and approval rules are reviewed on the same settings page. No
checkbox ceremony or nested confirmation sheet is needed. Linking is the
explicit action; project membership alone never authorizes execution.

New Codex chats prefer native linking. Older Aitvaras-only chats keep their
isolated mode and may be selected explicitly. Native Local/Claude handover does
not automatically backfill messages: the native thread keeps its own history.

Native canonical turns/items are projected by native IDs and order, with retained
observations separate from current history. User/assistant text appears in the
shared chat timeline. Native imports remain separate read-only evidence. Native
events drive live updates; there are no new idle model or status-polling loops.

Explicit sends are durably journalled before transport, bind the returned native
turn once, and reconcile confirmed outcomes. Stop remains a request until native
confirmation. Unknown delivery is never replayed or guessed by text similarity.
Command/file approvals and native questions appear inline. Incomplete permission
previews cannot be accepted; unsupported interactions can be declined and handled
in Codex. Full Access/external sandboxes are not silently enabled by linking.

Offline checks include `CodexSessionReaderTests`, `WorkspaceCodexLinkStoreTests`,
`CodexSharedRuntimeClientTests`, and
`node scripts/check-codex-shared-runtime.mjs`. The latter verifies that the
native WebSocket implementation rejects redirects without contacting a second
listener. No live model or authentication is required by these checks.

## Execution and permission boundary

Do not relax the current immutable owned-session registry to adopt imported
native IDs. Add a separate linked-native adapter and authorization record.

The existing Aitvaras connection uses a dedicated profile, temporary cwd,
revision-bound folder grants and app-controlled `aitvaras_project` tools.
Persisting their declarations does not make their handlers available in desktop.
Existing isolated chats must stay isolated unless a supported migration is
separately demonstrated. Never copy credentials or fabricate/replay old turns
to manufacture a native transcript.

The user selected **Native Codex mode** for linked chats. This authorizes building
normal native tool support, not Full Access, automatic approvals or silently
changing the desktop configuration. The effective sandbox, roots and approval
rules still need to be displayed before a linked chat can execute.

The supported directions are:

1. **Native Codex mode (selected for shared chats):** use the native project's
   reviewed effective tools, sandbox and approval rules. Make the difference
   from isolated Aitvaras mode explicit. Do not auto-approve actions or silently
   enable hooks, MCP, shell, writes or broader file roots.
2. **One restricted environment in both clients:** requires a secured portable
   tool service or demonstrated equivalent native enforcement. The current
   app-bound reader is insufficient; do not claim this is already available.

Project membership is not itself an access grant. Native transcript observation
and cross-provider context sharing are separate permissions. Aitvaras cannot
promise to constrain independent future actions inside Codex desktop.

## Coordination, identity and recovery

- Prefer the same native runtime for both clients. An independent app-server
  process can encounter an existing live writer; never delete writer locks,
  force takeover or treat an Aitvaras-only lease as a cross-client lock.
- Block the local composer while observed native work is active. The installed
  `turn/start` contract can steer an already-active turn; an idle check followed
  by send is not an atomic idle-only reservation. Prove runtime serialization
  and define the remaining input race before promising exclusive handoff.
- Track observed controller/turn state separately from connection availability.
  Disconnection is not completion. Reconcile native turn IDs and outcomes before
  permitting another attempt; never automatically replay uncertain input.
- Native item/turn IDs determine order and deduplication. The cache must not
  become a second writer of synthetic native messages.
- Model and reasoning changes should use supported native per-turn settings
  without changing the canonical chat identity. Local/Claude work remains
  attributed separately; return to Codex uses an explicit context handover,
  never automatic backfill into native history. The handover is specified in
  [D30](DECISIONS.md): it travels inside the user's Send, with consent, and is
  recorded and shown in the transcript.
- Local hide/expiry is not native archive/delete. Unlink removes the relationship,
  not the source. Native archive/restore/rename/move are explicit operations.
  Missing list entries are not deletion evidence. Retained historical evidence
  stays distinct from the current native transcript projection.

## Delivery checkpoints

1. **Compatibility proof (basic two-client slice passed):** isolated projects with multiple roots and worktrees;
   two clients against one native runtime; project membership and primary-root
   semantics; live-status/event routing; active-turn input behavior; portable
   tools and effective permissions; cancellation, restart and unknown outcomes.
   No real project changes, authentication or paid prompts for this proof.
2. **Selected project linking:** additive profile-qualified identities and root
   snapshots, compact Project settings UI, exact differences, conflict states,
   migration tests. No automatic import or permission widening.
3. **Canonical native observation:** paginated item projection, native-ID
   deduplication, revisions, foreground/event-driven refresh and a visible sync
   state. Optional background observation obeys the existing review/pause gate.
4. **Native continuation:** explicit Send, approval handling, activity/usage,
   durable operation journal and native coordination only after proof. Keep
   unsupported hosts/sessions read-only/open-in-native.
5. **Two-way metadata and supervised verification:** explicit rename, folder and
   archive operations; actual desktop checks on a disposable project, then an
   opt-in real project. No destructive mirroring or public-repository writes.

No server deployment, remote task execution, mobile application, Claude live
control or automatic project knowledge export is included in this checkpoint.

## Remaining limits

- The native API has no atomic idle-only turn reservation. Observed active work
  blocks input and the client rechecks idle immediately before sending, but two
  clients clicking Send simultaneously can still race. Do not present this as
  an exclusive cross-client controller lock.
- A delivery with no returned native turn ID remains unresolved even after an
  idle refresh. There is deliberately no automatic retry or text-based adoption.
- Native rename/archive/project mutations are transport capabilities, not
  destructive mirroring of local UI changes. Local hide/archive/unlink is local.
- Unsupported remote hosts, external sandboxes, automatic approval reviewers
  and Full Access are not enabled through this linking flow.
- Installation and a supervised installed-app check wait until recording stops.

## Sources

- [Official app-server documentation](https://learn.chatgpt.com/docs/app-server)
- [Official projects and chats documentation](https://learn.chatgpt.com/docs/projects)
- [Official remote connections documentation](https://learn.chatgpt.com/docs/remote-connections)
- Installed generated schemas and the repository's
  [existing isolation proof](FRONTIER-CODEX-PROOF.md).
