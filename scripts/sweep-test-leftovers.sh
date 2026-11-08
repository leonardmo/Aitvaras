#!/usr/bin/env bash
# Stops processes that test runs left behind. Runs after `make test`, `make live`,
# `make e2e` and `make ui`, and can be run by hand at any time.
#
# Only orphans count (parent is launchd, pid 1), so nothing a running test or app
# still owns is touched. An orphan is a leftover when it is one of:
#   - a program run from a test folder in $TMPDIR (fixtures, fake CLIs, throwaway profiles)
#   - a Local opencode server (`opencode serve --hostname 127.0.0.1`); the app keeps
#     its own server as a child, so an orphaned one has lost its app
#   - an app built for UI tests (.build-e2e)
# Each gets SIGTERM, then SIGKILL after 2 seconds, because test stubs ignore SIGTERM.
# Usage: scripts/sweep-test-leftovers.sh [--dry-run]
set -uo pipefail
dry="${1:-}"
tmp="${TMPDIR:-/tmp/}"; tmp="${tmp%/}"
me="$(id -u)"

leftovers=()
while read -r pid ppid uid command; do
    [[ "$ppid" == 1 && "$uid" == "$me" && "$pid" != "$$" ]] || continue
    case "$command" in
        *"$tmp"/*|*"/private$tmp"/*)
            shopt -s nocasematch
            [[ "$command" =~ (aitvaras|synthetic|fixture|agent-test|opencode|-test) ]] && leftovers+=("$pid")
            shopt -u nocasematch ;;
        *opencode*" serve "*"--hostname 127.0.0.1"*) leftovers+=("$pid") ;;
        */.build-e2e/Build/Products/*) leftovers+=("$pid") ;;
    esac
done < <(ps -axww -o pid=,ppid=,uid=,command=)

[[ ${#leftovers[@]} -eq 0 ]] && exit 0
for pid in "${leftovers[@]}"; do
    echo "Leftover test process $pid: $(ps -o command= -p "$pid" | cut -c1-160)"
done
[[ "$dry" == "--dry-run" ]] && exit 0
kill -TERM "${leftovers[@]}" 2>/dev/null
/bin/sleep 2
kill -KILL "${leftovers[@]}" 2>/dev/null
exit 0
