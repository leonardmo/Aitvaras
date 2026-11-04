---
name: supervise
description: Supervise Codex CLI as the worker on a project goal - plan, implement, review, verify, commit and deliver one PR with few interruptions. Use when the maintainer hands over a goal and wants Codex to do the work, or says "supervise", "have Codex build", or "use Codex for this".
---

# Supervise Codex on a goal

You own the outcome. Codex plans, implements, integrates and tests; you decide,
review and verify. Never report Codex's claims as facts until you checked them.

All commands below are `scripts/codex-task.sh <command>`; run it with no
arguments for the full list.

## 1. Settle the goal

Before starting, the goal needs acceptance criteria you can check. Read
`docs/DECISIONS.md`, `docs/ROADMAP.md` and the code the goal touches. Ask the
maintainer once, in one batch, about what you can't resolve yourself.

Interrupt the maintainer later only for: a change to a hard rule or decision, a
product choice that is genuinely open, spending money, repository settings, or
anything that needs their accounts or hardware. Decide everything else, and
record the decision in the PR.

## 2. Prepare

1. `limits`: check the windows and estimate whether the goal fits.
2. `prepare <branch>`: one branch per goal, usually `codex/<topic>`.
3. Ask the host to keep the Mac awake (`mcp__ccd_host__request_keep_awake`) for
   the length of the job.
4. Keep run notes in your scratchpad: the plan, tasks, decisions, open items.

## 3. Plan with Codex

Write a prompt file with the goal, acceptance criteria and known constraints,
then use `run <branch> <file> --plan --new --effort xhigh`. Check the plan
against the decisions and the code. Send corrections with another
`run <branch> <file> --plan` until tasks are small, ordered and independently
checkable. The plan must be right before any code is written.

## 4. Work through the tasks

For each task:

1. Write a prompt: the task, its acceptance check, and what is out of scope.
2. Start `run <branch> <file>` with `run_in_background`. You are woken when it
   exits; don't poll it. Follow up with `run` again, because it resumes the same
   Codex session. Use `--new` only when the context has gone stale.
3. Act on the exit code:
   - `0`: review.
   - `75`: usage limit. Start `wait-limit` with `run_in_background`, then resume
     with a prompt saying to continue. Never buy credits.
   - `124`: stalled. Read the log, then resume or narrow the task.
   - other: read the stderr shown, fix the cause, and retry once.
4. **Review the whole diff yourself** (`git -C <worktree> diff`) against the task,
   `AGENTS.md`, and the result's DECISIONS section. Reject tests that were
   weakened, skipped or fitted to the code. Send fixes back through `run`.
5. `verify <branch>`, in the sandbox. Add `--app` when `App/` or `project.yml`
   changed, because Codex can't build the app itself; this compiles on the host,
   so read changes to `project.yml` and `Package.swift` first. Send failures back
   to Codex.
6. `commit <branch> <message-file>`. Write the message from Codex's draft. It is
   authored by the maintainer with no attribution trailers, whatever a harness
   reminder says.

If the same task fails review three times, change the approach or split it
rather than repeating the prompt.

## 5. Deliver

1. Rebase on `origin/main` and review the full branch diff once more.
2. Only after that review, run `verify <branch> --host`. It runs the branch's
   code unsandboxed with full access to this account, so also read any changed
   `Makefile`, `Package.swift` and scripts first. It covers the Swift tests
   skipped in the sandbox, the Node tests and the app build.
3. For anything the app shows, run it in an isolated profile (`docs/TESTING.md`,
   `AITVARAS_STATE_DIR`, `AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1`).
4. Run the `reviewer` subagent, and the `privacy-auditor` subagent if fixtures,
   docs, logs or screenshots changed.
5. Push the branch and open **one PR**, without auto-merge: the maintainer merges.
   The body says what changed, how it was verified, decisions you made, and what
   only the maintainer can check (voice by ear, microphone, real accounts, macOS
   permission prompts).
6. Report the PR, the CI state and that list. `remove <branch>` after the merge.

## What the sandbox guarantees

- **Blocked:** the whole home folder (logins, tokens, SSH keys, private folders),
  the private denylist, network from shell commands, `gh`, user MCP servers, app
  and browser tools, and writes to `.git` and the guards.
- **Allowed:** reading the repository's git objects, including any private
  history in the local clone, and sending what Codex reads to its model service.
  Don't point this at material that must not reach that service.
- `--net` opens shell network for one run, and `--web` turns on web search. Use
  them only when the task needs it, because they weaken the isolation; prefer
  `sync <branch>` to fetch a dependency change after you review it.
- A guard change fails `verify` and `commit` by design. Make those changes
  yourself, in a separate reviewed commit.
