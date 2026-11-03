---
name: ship
description: Finish a change in this repo — run the checks, commit only the intended files, push the branch and open a squash-auto-merging PR. Use when a task is done and the user wants it landed, or says "ship it".
---

# Ship a change

Follow `AGENTS.md` → "How work flows". Steps:

1. **Branch.** If you are on `main`, create a branch first:
   `git switch -c <agent>/<topic>`. Never push to `main` directly.
2. **Check.** Run `make check`. If anything under `App/` or `project.yml`
   changed, run `make smoke` instead. Fix failures; never skip a check.
3. **Stage.** Review `git status` and stage only files that belong to this
   task. Leave other agents' untracked or modified files alone. Read
   `git diff --cached` once in full.
4. **Privacy.** If the diff touches fixtures, docs, logs, screenshots or
   connector configuration, run the `privacy-auditor` subagent and fix what
   it reports.
5. **Commit.** Write an imperative subject of 72 characters or fewer and a
   body that says why. Add no attribution trailers; the commit-msg hook
   rejects them.
6. **Rebase and push.**
   `git fetch origin && git rebase origin/main`. On conflicts in migrations
   or `D<n>` numbers, follow the collision rules. Then
   `git push -u origin HEAD`.
7. **PR.** Run `gh pr create --fill` (edit the body: what changed, how it was
   verified, what wasn't verified), then `gh pr merge --auto --squash`.
8. **Report** the PR link and CI state. If CI goes red, read the failing
   job log (`gh run view --log-failed`) and fix it on the same branch.
