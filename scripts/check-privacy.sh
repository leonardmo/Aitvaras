#!/usr/bin/env bash
# Privacy and secret sweep. Runs locally (make privacy, the git hooks) and in
# CI. This repository is public: anything that identifies a real person,
# installation, institution or place must not be committed, test data
# included.
#
#   scripts/check-privacy.sh                      # tracked files in the working tree
#   scripts/check-privacy.sh --staged             # lines added in the index (pre-commit)
#   scripts/check-privacy.sh --commits <rev...>   # lines added and messages in commits
#                                                 # (pre-push, CI), e.g. origin/main..HEAD
#
# Three kinds of checks:
# - generic patterns (credentials, home paths, real email addresses), below;
# - the maintainer's private denylist, which is never committed: one
#   case-insensitive extended regex per line, read from
#   `$(git rev-parse --git-common-dir)/info/privacy-denylist` and from the
#   AITVARAS_PRIVACY_DENYLIST environment variable (a CI secret). Denylist
#   hits print only file and line, never the matched text, so CI logs stay
#   clean;
# - the local account name (`whoami`) outside CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

MODE=tree
case "${1:-}" in
    --staged) MODE=staged ;;
    --commits) MODE=commits; shift; [[ $# -gt 0 ]] || { echo "usage: $0 --commits <rev...>" >&2; exit 2; } ;;
    "") ;;
    *) echo "usage: $0 [--staged | --commits <rev...>]" >&2; exit 2 ;;
esac

# Files that legitimately contain the patterns themselves.
EXCLUDED_FILES='^(scripts/check-privacy\.sh|scripts/check-commits\.sh|\.githooks/.*)$'

# Turns a unified diff into "file:line:text" records of its added lines.
added_lines() {
    awk '
        /^\+\+\+ / { file = substr($0, 7); next }
        /^@@/ { split($3, a, ","); line = substr(a[1], 2) + 0; next }
        /^\+/ { if (file != "" && file != "dev/null") print file ":" line ":" substr($0, 2); line++; next }
        /^ / { line++ }
    '
}

# Writes "file:line:text" records for everything under scan to stdout.
scan_input() {
    case "$MODE" in
        tree)
            git grep -I -n -e '' -- . ;;
        staged)
            git diff --cached --no-color -U0 --no-ext-diff --text | added_lines ;;
        commits)
            local sha
            for sha in $(git rev-list "$@"); do
                git log -1 --format=%B "$sha" | sed "s|^|commit ${sha:0:12} message:0:|"
                git show --no-color -U0 --no-ext-diff --format= "$sha" | added_lines
            done ;;
    esac | awk -F: -v ex="$EXCLUDED_FILES" '$1 !~ ex'
}

INPUT=$(mktemp)
DENYLIST=$(mktemp)
trap 'rm -f "$INPUT" "$DENYLIST"' EXIT
if [[ "$MODE" == commits ]]; then scan_input "$@" > "$INPUT"; else scan_input > "$INPUT"; fi

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }
show() { head -5 >&2; }
locations() { cut -d: -f1,2 | sort -u | sed 's/^/    /'; }

FIXED=(
    "/Users/"
    "@gmail.com"
    "Co-Authored-By"
    "BEGIN OPENSSH PRIVATE KEY"
    "BEGIN RSA PRIVATE KEY"
    "BEGIN PRIVATE KEY"
    "xoxb-"
    "ghp_"
    "github_pat_"
    "sk-ant-"
)
for pattern in "${FIXED[@]}"; do
    if hits=$(grep -F -e "$pattern" "$INPUT"); then
        fail "forbidden pattern: $pattern"
        echo "$hits" | show
    fi
done

# Home directories other than the documented placeholder /home/user.
if hits=$(grep -E '/home/[a-z][a-z0-9_-]*' "$INPUT" | grep -v -E '/home/user([^a-z0-9_-]|$)'); then
    fail "personal home path"
    echo "$hits" | show
fi

# A pasted Home Assistant long-lived token and many other bearer credentials
# are JWT-shaped. Fixtures should use short, plainly synthetic values instead.
if hits=$(grep -E '[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' "$INPUT"); then
    fail "likely JWT/bearer token"
    echo "$hits" | show
fi

# Email addresses must use reserved example domains (RFC 2606/6761) or the
# GitHub noreply addresses. URL userinfo (https://user@host) is not an address.
ADDRESS='(^|[^/:A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
ALLOWED='@([A-Za-z0-9-]+\.)*(example\.(com|org|net|edu)|example|invalid|test|localhost)$|@users\.noreply\.github\.com$|^noreply@github\.com$|\.(png|jpe?g|gif|svg|webp|pdf)$'
hits=$(grep -E "$ADDRESS" "$INPUT" | while IFS= read -r record; do
    text=${record#*:}; text=${text#*:}
    if grep -o -E "$ADDRESS" <<<"$text" | sed -E 's/^[^A-Za-z0-9._%+-]//' \
        | grep -q -v -i -E "$ALLOWED"; then
        echo "$record"
    fi
done || true)
if [[ -n "$hits" ]]; then
    fail "real email address (use example.org or *.invalid placeholders)"
    echo "$hits" | show
fi

# The maintainer's private denylist.
{
    f="$(git rev-parse --git-common-dir)/info/privacy-denylist"
    if [[ -f "$f" ]]; then cat "$f"; fi
    printf '%s\n' "${AITVARAS_PRIVACY_DENYLIST:-}"
    if [[ -z "${CI:-}" ]]; then printf '%s\n' "${AITVARAS_PRIVACY_USER:-$(whoami)}"; fi
} | sed -e 's/[[:space:]]*$//' | { grep -v -E '^(#|$)' || true; } > "$DENYLIST"
if [[ -s "$DENYLIST" ]]; then
    if hits=$(grep -i -E -f "$DENYLIST" "$INPUT"); then
        fail "private denylist match (text withheld):"
        echo "$hits" | locations >&2
    fi
elif [[ -n "${CI:-}" ]]; then
    echo "! no private denylist configured (secret PRIVACY_DENYLIST); generic checks only" >&2
fi

# Repository-state checks, only meaningful for the working tree.
if [[ "$MODE" == tree ]]; then
    # Live speech recognition itself never saves audio. Source-audio persistence
    # belongs exclusively to the separately consented CaptureAudioRecorder path.
    if git grep -q -F -e "AVAudioFile" -- Sources/AitvarasVoice/TranscriberSession.swift; then
        fail "live transcriber contains an audio-file persistence path"
    fi
    # Focus sampling is explicitly memory-only. App names may influence a local
    # nudge or spoken session summary, but must never enter the durable event JSON.
    if git grep -q -F -e "detailJSON" -- App/FocusCoach.swift; then
        fail "Focus Coach contains a durable detail payload for memory-only app usage"
    fi
    # Machine-local notes must stay untracked.
    for local in CLAUDE.local.md AGENTS.local.md .claude/settings.local.json; do
        if git ls-files --error-unmatch "$local" >/dev/null 2>&1; then
            fail "$local is tracked; it must stay gitignored"
        fi
    done
fi

if [[ "$FAILED" -eq 0 ]]; then echo "✓ privacy checks passed ($MODE)"; fi
exit "$FAILED"
