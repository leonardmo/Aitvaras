# Claude connection: shared or separate subscription profile

**Superseded for interactive Chat by [UNIFIED-CHAT-PLAN.md](UNIFIED-CHAT-PLAN.md)
and D31/D32.** The current UI drives the official CLI directly with its default
login/store; the account-mode and consent flows below document the retained
legacy adapter. Saved evidence remains readable. M6.3 removal waits for the
owner's review, and Claude through the unified UI has never run live because
its CLI login expired. This checkpoint is not current UI acceptance evidence.

Implementation checkpoint — 2026-10-30. This is the on-demand live chat adapter,
not a claim of complete Claude desktop/web synchronization.

## Account modes

- **Existing Claude Code profile:** use the official default Claude Code login.
  Do not set `CLAUDE_CONFIG_DIR`, even to the default directory: the pinned macOS
  CLI uses the presence of that variable to select a different Keychain service.
- **Separate Claude Code profile:** set `CLAUDE_CONFIG_DIR` only in the adapter's
  child process. The official CLI owns sign-in and credential storage. This
  profile may use the same subscription account or another one.
- A profile/account change clears connection/session selection and requires
  fresh history-sharing consent before previous chat messages can leave for
  that account. A signed-in account is shown in the account settings.
- No global environment changes, credential copying, token extraction, custom
  OAuth, automatic logout, account rotation or quota pooling.

The official CLI can fall back to a credentials file if macOS Keychain fails.
Aitvaras does not read that file or implement a plaintext fallback: the adapter
must refuse a selected profile with such a file present. Resolve Keychain access
before retrying; never automatically delete credentials or sign other clients out.

## Sign-in and billing

AI Settings has one **Sign in to Claude** action. It checks the selected profile
first, reusing an existing subscription login. If signed out, Aitvaras hosts the
official CLI's `auth login --claudeai` browser flow and verifies the account when
that process finishes. The app displays waiting, verifying, connected, cancelled
and failure states; no separate manual Check step is required. A chat-composer
shortcut opens this same settings panel. Checking and sending are
separate from signing in. Opening an unconnected chat does not initialize a
provider. After an explicit account check, returning to the foreground may
refresh the selected, already-bound session's history without sending a prompt,
only when reviewed connected-service checks are enabled and not paused.

The adapter accepts only the official first-party Claude subscription credential
source. API keys, injected OAuth tokens, custom endpoints and alternate providers
are not accepted or inherited. No pay-as-you-go fallback is implemented.
Metadata/model discovery uses SDK initialization without supplying a user prompt.

The CLI still owns OAuth, browser callbacks and credential storage. Auth output
is transient, bounded and never logged. The optional Open Browser shortcut only
accepts the official HTTPS Claude authorization endpoint. Cancel stops only the
app-owned sign-in process and waits for its actual exit. Manual code-entry or
blocked-callback environments can use **Advanced → Sign in using Terminal**;
after finishing there, the main sign-in action checks the resulting login without
starting another one when already connected. No automatic login runs on startup.

Anthropic's [account documentation](https://code.claude.com/docs/en/authentication)
supports independent configuration directories. Its
[subscription SDK notice](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
describes subscription-backed SDK usage, while the
[SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) restricts offering
custom Claude-account login in third-party products without approval. This private
adapter delegates authentication to the official CLI; do not turn it into a
distributed product login or publish it without revisiting those requirements.

## Chat and permissions

- The existing Local / Codex / Claude selector uses one visible chat transcript.
  Model and supported reasoning options are in the composer; account settings
  remain in its single settings panel.
- Project settings must explicitly enable Claude. Approved file reads have a
  separate, revision-bound Claude grant; Codex's read grant does not enable it.
- The current adapter has bounded read-only project listing/reading through
  the native broker. No arbitrary shell, editing, native hooks, skills, plugins,
  unreviewed MCP servers or global RAG are enabled.
- The first Send can offer history sharing for the verified account. History
  remains bounded and attributed; imported chats, captures and other projects
  are not silently included. Changing provider alone sends nothing.
- Context and quota gauges show unknown when the official interface supplies no
  reliable measurement. Session token counts are saved when supplied; subscription
  quota windows are not fabricated from token counts.

## Delivery and recovery

The app reserves a turn before execution. Session binding and prompt release each
require a durable acknowledgement. Provider acknowledgement uses an actual SDK
message/response identity, never the locally generated release-barrier ID.
Partial text is checkpointed. A stop request remains pending until an actual
terminal outcome, or is marked unknown if the connection ends without one.

No automatic replay follows a crash, quota failure, disconnect, monitoring error
or uncertain result. App-owned sessions are account/profile partitioned and cannot
be replaced by imported native IDs. The adapter owns only its own child processes;
there is no global Claude process termination or native writer-lock deletion.

## Supported history continuity and remaining boundaries

The SDK persists app-created sessions in the selected official profile. This
adapter resumes only IDs it created and durably bound. Refresh reads a complete,
bounded canonical text snapshot using the official local history interface;
exact message UUIDs prevent duplicates. Refresh runs after confirmed outcomes,
on explicit request, and on foreground return for an already-verified session.
Account verification may contact Anthropic, but history refresh sends no model
prompt. Completed app replies can display canonical corrections without changing
the execution journal. Previously unattributed native messages are marked as
observed evidence, not confirmed completed work or automatic handover context.

Existing imported sessions stay read-only. Native history has no reliable
per-turn completion or creation times; observed messages cannot settle an
unknown execution outcome. Aitvaras serializes its own workers, not every native
Claude Code client. Do not drive the same session concurrently in both clients.

Ordinary Claude app/web chats and projects are a different surface. No supported
claude.ai synchronization interface has been established here. Same-account
authentication is not proof of cloud chat access, cross-client locking or safe
simultaneous control.

## Verification

Use synthetic providers and isolated state first. Run package/store/transport
checks, then `--claude-workspace-check` and the Claude UI fixture. Never use a
personal transcript as a fixture. A live subscription test is a separate final
gate after the implementation is ready; it must not be repeated automatically.

Checkpoint evidence: 592 package tests in 63 suites and 16 no-provider Node
contracts passed. The release build, signature verification and isolated Claude
and Codex app lifecycle checks passed. Initial transport
fixtures exposed a macOS path-alias issue; POSIX canonicalization now precedes
the no-follow lease walk, with the transport suite passing afterward. The
metadata-only live check reported signed out, so no live model prompt was sent;
real subscription response/file-read acceptance still requires sign-in.

The guided-sign-in follow-up passed 601 package tests, including nine synthetic
CLI-host tests, plus the release app fixture for login reuse, automatic account
verification, cancellation and refusal of a successful exit with no authenticated
account. It was installed after confirming capture/voice were idle. No real login
or model prompt was initiated by these checks; browser acceptance is user-driven.

### Authentication-shape correction — 2026-10-31

The real pinned SDK returns optional credential-source fields unset and a display
plan such as `Claude Pro`. The earlier exact-string check incorrectly reported
signed out even after successful official login. Verification now pairs that SDK
metadata with `claude auth status` in the same sanitized profile, requiring
first-party claude.ai subscription authentication, matching plan and account/org
identity. API-key/injected-token evidence is still refused. Namespace identity
uses the verified organization ID rather than its display name.

Seventeen helper contracts passed, including the actual SDK response shape and
negative API/account-mismatch cases. A single previously authorized live test
successfully read a disposable synthetic file, returned its exact contents and
refreshed the saved session history. No personal files or chat history were used.

### Revoked credentials and SDK error envelopes — 2026-11-01

Local account metadata is not a live token-validity check. A subscription login
can be revoked after a successful test; Aitvaras must not promise continued access
from cached metadata or silently replay a failed message. The SDK can emit a
synthetic assistant with `error: authentication_failed`, followed by a result
whose subtype is `success` but whose `is_error` flag is true. These are failed
provider outcomes, not successful assistant replies.

The adapter now suppresses typed SDK error prose, preserves error message UUIDs
for history deduplication, records the failed outcome and offers explicit
reconnection. Cached metadata cannot clear that reconnect requirement in the
current process; only an explicitly completed official sign-in can. Other typed
provider errors and usage limits are also kept separate from assistant answers.
No token copying, silent login or automatic resend is introduced.

Verification status for this correction: 19 helper contracts and Swift syntax
checks passed. Full transport/app compilation is pending restoration of the
updated Xcode environment: its Metal Toolchain is missing and its cached
SwiftSyntax macro binaries target the previous SDK. Do not treat this source
checkpoint as installed or runtime-accepted until those gates pass.
