@AGENTS.md

# Claude Code notes

- Machine-local context lives in `CLAUDE.local.md` (gitignored). Create your
  own if it's missing, and never copy its contents into tracked files.
- Shared permissions and hooks are in `.claude/settings.json`; personal
  overrides go in `.claude/settings.local.json` (gitignored).
- Project subagents: `reviewer` (correctness review of a diff against these
  rules) and `privacy-auditor` (checks outgoing changes for
  installation-specific data). Use the `ship` skill to check, commit and open
  an auto-merging PR.
- Nested `CLAUDE.md` files import the `AGENTS.md` next to them, so area rules
  load when you work in that directory.
