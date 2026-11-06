# Shared native Codex setup

**Legacy setup, superseded for current Chat by
[UNIFIED-CHAT-PLAN.md](UNIFIED-CHAT-PLAN.md) and D31/D32.** The unified UI drives
the official app-server with its default login/store and discovers native chats
without a connect/link step. The flow below documents the retained adapter;
M6.3 removal waits for the owner's review. Use the current plan for open gates.

## User flow

1. Choose Codex in a project chat and open its settings gear.
2. Connect the shared Codex runtime. This uses the native profile/account; the
   separate Aitvaras-only account is not copied or adopted.
3. Link the Aitvaras project to a native Codex project. Review the actual ordered
   folders; Aitvaras-only sources remain private and separate.
4. Select an existing native chat, or prepare a new one with an explicit working
   folder. Review native writable scope, network access and approval rules, then
   link. No prompt is sent by browsing or linking.
5. Send normally. The canonical native chat is shared with Codex. Native tools
   use native permissions, with supported approvals/questions shown inline.

Model/reasoning remain in the composer, and context/quota use the existing
gauges. Aitvaras-only chats retain their old restricted connection and history.
Switching backends does not silently copy local messages into native Codex.

## Runtime preparation

The official `codex app-server daemon start` command starts the local daemon
idempotently. Aitvaras attaches through `codex app-server proxy`, which resolves
the native profile's control socket. The adapter performs WebSocket framing over
the raw proxy pipes; it does not start a second writer or steal locks.

The inspected desktop build supports `CODEX_APP_SERVER_WS_URL` with a
`ws+unix://localhost<absolute-control-socket>:/rpc` route. Use the socket returned
by the official daemon command, not a guessed path. The Unix socket must belong
to the current user and exclude access by other users. No public TCP listener is
necessary. This route is version-sensitive; verify after Codex updates.

Only with explicit user permission, prepare a user LaunchAgent that runs the
official idempotent daemon start and sets the desktop route in the GUI login
environment. It runs once at login, has no keep-alive loop, launches neither
Aitvaras nor an AI task, and sends no prompts. Restart only Codex after recording
and other application boundaries have been checked. Never restart Aitvaras while
capture is active.

Installation-specific paths, LaunchAgent contents and prior environment values
are local setup state, not repository data. To undo a locally installed runtime
preparation, unload/remove its LaunchAgent and unset the GUI environment route;
do not delete the native profile, project database or histories.

## Verification

- `swift test --no-parallel`: complete package regression pass.
- `node scripts/check-codex-native.mjs`: transport/approval/frame contracts.
- `scripts/check-codex-native.sh`: small isolated Swift transport harness when
  developing the adapter without rebuilding the whole app.
- `--codex-native-workspace-check`: isolated App model check covering linking,
  native IDs, streaming, approvals, usage, stop races, disconnect/reconnect,
  unknown delivery, profile gates and Activity privacy.
- Native two-client proof uses a disposable profile and fixed local provider.
  A real prompt/file-read test requires separate user approval and synthetic
  inputs; it must never use a lecture recording or personal project data.

Connection availability is not proof of completed work or desktop attestation.
No uncertainty or monitoring failure authorizes replaying provider input.

### Live synthetic verification

An explicitly approved live check passed through the shared native adapter:
one model request read a generated marker file using a native command tool and
returned its exact contents. A second client resumed the same native chat and
observed the same completed turn and answer. No personal project, recording or
existing conversation was supplied. The temporary native project was removed,
the synthetic chat archived, and Aitvaras was not restarted or modified. This
verifies the native runtime path, not the still-pending installed-app UI check.
