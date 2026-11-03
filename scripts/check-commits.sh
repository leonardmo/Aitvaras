#!/usr/bin/env bash
# Checks commit metadata before it becomes public: author emails must be
# GitHub noreply addresses and messages must not carry tool attribution.
#
#   scripts/check-commits.sh <rev...>         # e.g. origin/main..HEAD (CI, pre-push)
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

[[ $# -gt 0 ]] || { echo "usage: check-commits.sh <rev...> | --message <file>" >&2; exit 2; }
FAILED=0
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
for sha in $(git rev-list --no-merges "$@"); do
    for email in $(git log -1 --format='%ae %ce' "$sha"); do
        case "$email" in
            *@users.noreply.github.com|noreply@github.com) ;;
            *) echo "✗ ${sha:0:12}: author/committer email is not a GitHub noreply address" >&2; FAILED=1 ;;
        esac
    done
    git log -1 --format=%B "$sha" > "$TMP"
    check_message "$TMP" "$sha" || FAILED=1
done
[[ "$FAILED" -eq 0 ]] && echo "✓ commit metadata checks passed"
exit "$FAILED"
