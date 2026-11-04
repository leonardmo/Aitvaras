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
