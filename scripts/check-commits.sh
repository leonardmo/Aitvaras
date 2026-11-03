#!/usr/bin/env bash
# Checks commit metadata before it becomes public: author emails must be
# GitHub noreply addresses and messages must not carry tool attribution.
#
#   scripts/check-commits.sh <rev-range>      # e.g. origin/main..HEAD (CI)
#   scripts/check-commits.sh --message <file> # one message (commit-msg hook)
set -euo pipefail

ATTRIBUTION='^co-authored-by:.*(claude|anthropic|openai|codex|chatgpt|copilot)|generated (with|by) \[?(claude|codex|chatgpt|copilot)'

check_message() {
    if grep -iEq "$ATTRIBUTION" "$1"; then
        echo "✗ $2: commit message contains tool attribution:" >&2
        grep -iE "$ATTRIBUTION" "$1" | sed 's/^/    /' >&2
        return 1
    fi
}

if [[ "${1:-}" == "--message" ]]; then
    check_message "$2" "this commit"
    exit $?
fi

RANGE="${1:?usage: check-commits.sh <rev-range> | --message <file>}"
FAILED=0
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
for sha in $(git rev-list --no-merges "$RANGE"); do
    email=$(git log -1 --format=%ae "$sha")
    case "$email" in
        *@users.noreply.github.com|noreply@github.com) ;;
        *) echo "✗ $sha: author email is not a GitHub noreply address" >&2; FAILED=1 ;;
    esac
    git log -1 --format=%B "$sha" > "$TMP"
    check_message "$TMP" "$sha" || FAILED=1
done
[[ "$FAILED" -eq 0 ]] && echo "✓ commit metadata checks passed"
exit "$FAILED"
