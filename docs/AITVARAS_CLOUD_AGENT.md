# Aitvaras-owned cloud agent instructions

The canonical runtime policy is shipped as
`Sources/AitvarasConnectors/Resources/AITVARAS_CLOUD_AGENT.md` and prepended to
every Claude Code and Codex CLI request made by Aitvaras. It is deliberately
provider-neutral: native user skills, MCP servers, hooks and personal CLI
configuration are disabled for these calls.

For non-delegation calls Claude's tools are disabled. Codex runs read-only in
an empty temporary workspace with its user configuration ignored. Confirmed
delegation is the only feature granted a selected writable workspace.

The policy is versioned. Every local usage-ledger row records the version that
was used, the feature, provider, duration, data categories and provider-reported
usage metadata. Prompt and response text are never copied into the usage
ledger.

Feature settings explain the exact categories that leave the Mac before a
cloud provider can be enabled. Selecting **Local only** disables cloud transfer
for that feature. Provider changes are read at the start of every new call and
do not require restarting Aitvaras. Enabling routine review also reviews
existing candidates that have not previously received a cloud review.

Tool access is task-specific rather than a general cloud-agent switch:
confirmed delegation needs tools inside the selected workspace; Claude tools
are disabled for the three structured tasks, and Codex is restricted to
read-only execution in an empty temporary directory. Aitvaras retrieves public
connector documentation itself so connector drafting does not need a general
web or file tool.
