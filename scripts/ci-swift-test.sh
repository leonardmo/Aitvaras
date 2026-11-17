#!/usr/bin/env bash
# Runs `swift test` for CI with a hang watchdog.
#
# The tests run under a pseudo-terminal so output is line-buffered: piped into
# the Actions log it arrives in 16 KB chunks, and the last test shown is then
# not the one that hung. When no output arrives for AITVARAS_TEST_IDLE_LIMIT
# seconds (default 300), the script prints the last lines, the test process
# tree and a stack sample, stops the run and fails.
#
#   scripts/ci-swift-test.sh [swift test arguments...]
set -uo pipefail

idle_limit="${AITVARAS_TEST_IDLE_LIMIT:-300}"
log="$(mktemp -t aitvaras-swift-test)"
trap 'rm -f "$log"' EXIT

# `script` gives the child a terminal; -F flushes its copy in $log after every
# write, so the watchdog sees when output last moved.
script -qF "$log" swift test "$@" &
runner=$!

hung=false
while kill -0 "$runner" 2>/dev/null; do
    sleep 10
    idle=$(( $(date +%s) - $(stat -f %m "$log") ))
    if (( idle >= idle_limit )); then
        hung=true
        break
    fi
done

if $hung; then
    echo
    echo "::error::swift test printed nothing for ${idle_limit}s; treating it as hung."
    echo "── Last test output"
    tail -15 "$log" | tr -d '\r'
    echo "── Processes under the test run"
    descendants() { local child; for child in $(pgrep -P "$1"); do echo "$child"; descendants "$child"; done; }
    pids="$(descendants "$runner" | paste -sd, -)"
    [[ -n "$pids" ]] && ps -o pid,ppid,etime,stat,command -p "$pids" | cut -c1-220
    tester="$(pgrep -f 'PackageTests' | head -1)"
    if [[ -n "$tester" ]]; then
        echo "── Stack sample of $tester (main and test threads)"
        sample "$tester" 3 -file /tmp/aitvaras-hang.sample >/dev/null 2>&1 \
            && grep -vE '^\s*$' /tmp/aitvaras-hang.sample | sed -n '1,400p'
    fi
    pkill -TERM -P "$runner" 2>/dev/null
    pkill -TERM -f 'PackageTests' 2>/dev/null
    sleep 5
    pkill -KILL -f 'PackageTests' 2>/dev/null
    kill -KILL "$runner" 2>/dev/null
    exit 124
fi

wait "$runner"
