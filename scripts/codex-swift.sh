#!/usr/bin/env bash
# SwiftPM inside the supervised Codex sandbox (see .claude/skills/supervise).
# Keeps SwiftPM's caches in the worktree, avoids the keychain and the nested
# sandbox, and skips the tests that cannot pass with no network and restricted
# reads. `scripts/codex-task.sh verify <branch> --host` runs those on the host.
#
# Usage: scripts/codex-swift.sh build [swift build args]
#        scripts/codex-swift.sh test  [swift test args]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/.build/codex-home"
mkdir -p "$work/cache" "$work/config" "$work/security" "$work/clang" "$work/tmp"

flags=(--disable-sandbox --disable-keychain
    --cache-path "$work/cache" --config-path "$work/config" --security-path "$work/security")
export CLANG_MODULE_CACHE_PATH="$work/clang"
cd "$root"

command="${1:?usage: codex-swift.sh build|test [args]}"
shift
case "$command" in
    build) exec swift build "${flags[@]}" "$@" ;;
    test)
        exec swift test "${flags[@]}" --no-parallel \
            --skip ProjectFileReaderTests \
            --skip manifestIsPrivateAndCrashLeftoversAreInspectable \
            --skip fileEventsReindexAndPruneWithoutWaitingForPoll \
            --skip redirectToPrivateHostIsRejectedBeforeSecondRequest \
            --skip feedRedirectToPrivateHostIsRejectedBeforeSecondRequest \
            "$@"
        ;;
    *) echo "usage: codex-swift.sh build|test [args]" >&2; exit 2 ;;
esac
