#!/bin/zsh
# Prepare a clean-history branch for the FIRST public push of this repo.
#
# Why: the private history contains early revisions of CLAUDE.md/docs with
# machine-local paths and personal context. Publishing `main` would leak
# them through old commits even though the current tree is clean. This
# script snapshots the CURRENT tree as a single parentless commit on a
# separate branch — private history on `main` stays untouched, and the
# public repo has exactly one author and zero third-party co-author
# trailers by construction.
#
# Usage:
#   ./scripts/prepare-public-release.sh [branch-name]   # default: public-main
#   git push <public-remote> public-main:main
set -e
cd "$(dirname "$0")/.."

BRANCH="${1:-public-main}"
PUBLIC_GIT_NAME="${PUBLIC_GIT_NAME:-leonardmo}"
PUBLIC_GIT_EMAIL="${PUBLIC_GIT_EMAIL:-70542941+leonardmo@users.noreply.github.com}"
LOCAL_USER="$(whoami)"

# 1. Refuse on a dirty tree — the snapshot must be reviewable.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ Working tree has uncommitted changes — commit or stash first." >&2
    exit 1
fi

# 2. Nothing machine-local may be tracked.
if git ls-files --error-unmatch CLAUDE.local.md >/dev/null 2>&1; then
    echo "✗ CLAUDE.local.md is tracked — it must stay gitignored." >&2
    exit 1
fi

# 3. Forbidden-pattern sweep over tracked files (personal identifiers,
#    absolute home paths, secrets-looking strings). Extend as needed.
PATTERNS=(
    "/Users/"
    "@gmail.com"
    "@tum.de"
    "Co-Authored-By"
    "M4 Max"
    "36 GB"
    "$LOCAL_USER"
    "BEGIN OPENSSH PRIVATE KEY"
    "xoxb-"
    "ghp_"
)
FAILED=0
# The sweep scripts carry the pattern list themselves — exempt them.
EXCLUDES=(":(exclude)scripts/prepare-public-release.sh" ":(exclude)scripts/test-smoke.sh")
for pattern in "${PATTERNS[@]}"; do
    if git grep -I --line-number --fixed-strings -- "$pattern" -- . "${EXCLUDES[@]}" >/dev/null 2>&1; then
        echo "✗ Tracked files still contain forbidden pattern: $pattern" >&2
        git grep -I --line-number --fixed-strings -- "$pattern" -- . "${EXCLUDES[@]}" | head -5 >&2
        FAILED=1
    fi
done
[ "$FAILED" -eq 1 ] && exit 1

# 4. Snapshot the current tree as one parentless commit.
TREE=$(git rev-parse "HEAD^{tree}")
COMMIT=$(
    GIT_AUTHOR_NAME="$PUBLIC_GIT_NAME" \
    GIT_AUTHOR_EMAIL="$PUBLIC_GIT_EMAIL" \
    GIT_COMMITTER_NAME="$PUBLIC_GIT_NAME" \
    GIT_COMMITTER_EMAIL="$PUBLIC_GIT_EMAIL" \
    git commit-tree "$TREE" -m "Aitvaras — initial public release"
)
git branch -f "$BRANCH" "$COMMIT"

echo "✓ Clean single-commit branch '$BRANCH' created at $COMMIT"
echo
echo "Next steps:"
echo "  1. Review it:   git log --stat $BRANCH"
echo "  2. Public author email: $PUBLIC_GIT_EMAIL"
echo "  3. Push:        git push <public-remote> $BRANCH:main"
echo
echo "Your full private history remains on 'main' — never push that branch"
echo "to the public remote."
