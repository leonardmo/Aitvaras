# Agent transport fixtures

## Hand-written project setup fixture

`claude/setup-hooks.jsonl` is authored by hand from the verified Claude CLI
2.1.300 P0 field shapes. It is not a captured recording. It uses generic
`echo`/`docs` servers, `shout`/`review` commands, a `reviewer` agent and synthetic
IDs. `initialize` supplies the argument hint; `system/init` supplies server
status/source, skills and agents. Hook events exercise started, success,
exit-code-2 block and error outcomes. Settings created by `AgentSetupTests`
supply `statusMessage`; that field is absent from the hook events.

`BackendExecutableFixture` replays it through the real process transport and
checks client frames. Generated MCP, settings/rules, OAuth and conversation
fixtures in the Swift tests likewise use hand-written generic data. Never copy
real init output: it can list private plugins, skills and account connectors.
Use synthetic secrets only; never print them. Stub processes must use bounded
`sleep 1` idle loops and exit on their own, with cleanup on failure/cancellation.
See [D34 testing](../../../../docs/TESTING.md#project-agent-setup-d34) for the
offline coverage and the separate browser/user live gate.

## Earlier sanitized recordings

Real CLI output, recorded from a neutral folder such as `/tmp/aitvaras-rec` (tool input streams in fragments, which a scrubber can miss) and sanitized by `scripts/sanitize-agent-recording.py`. Lines starting
with `# SENT ` are what the client wrote; the rest is what the CLI answered.
Recorded with Claude Code 2.1.300 and codex-cli 0.166.0-alpha.6.

`BackendExecutableFixture` generates a fake executable from each recording and
compares parsed client frames, including every control/approval response. It
maps client correlation IDs and the temporary working directory. For Claude,
it releases the recorded initialize response before waiting for the first user
frame (the recorder pipelined them), and requires hook registration even in the
two recordings that omitted it. For Codex, it handles the added `account/read`
subscription preflight and checks the app's client metadata shape. Recorder-only
`ephemeral: true` is omitted for native persistent threads; turn frames include
the selected approval/sandbox policy so subsequent mode changes take effect.

`opencode/allow-deny-stop.jsonl` preserves event order and payload field shapes
from the host's opencode 2.2.6 HTTP/SSE recording with a local Ollama model.
The source is `.build/agent-recordings/opencode/session-allow-deny-stop.jsonl`;
all event types are retained, including instructions and server/project updates.
Session/tool/request/message IDs, text, reasoning, commands, usage and outputs
are replaced with generic values; adjacent identical sanitized deltas are
coalesced. It contains no host paths, timestamps, native IDs or startup password.
`OpencodeFakeTransport` releases each segment at Send, permission reply or Stop
and checks the app’s actual reply/interrupt requests separately. This fixture
is protocol evidence, not a live-app or sandbox acceptance result.
