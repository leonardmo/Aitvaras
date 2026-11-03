#!/usr/bin/env bash
# Privacy and secret sweep over tracked files. Runs locally (make privacy, the
# pre-commit hook) and in CI. This repository is public: anything that
# identifies a real installation or person must not be committed.
#
#   scripts/check-privacy.sh            # scan the working tree's tracked files
#   scripts/check-privacy.sh --staged   # scan the index (pre-commit)
#
# AITVARAS_PRIVACY_USER adds the local account name as a forbidden pattern
# (defaults to `whoami` outside CI).
set -euo pipefail
cd "$(dirname "$0")/.."

GREP=(git grep -I)
[[ "${1:-}" == "--staged" ]] && GREP+=(--cached)

# These files carry the pattern lists themselves.
EXCLUDES=(":(exclude)scripts/check-privacy.sh" ":(exclude)scripts/check-commits.sh" ":(exclude).githooks/")

PATTERNS=(
    "/Users/"
    "@gmail.com"
    "Co-Authored-By"
    "BEGIN OPENSSH PRIVATE KEY"
    "BEGIN RSA PRIVATE KEY"
    "xoxb-"
    "ghp_"
    "github_pat_"
    "sk-ant-"
)
if [[ -z "${CI:-}" ]]; then
    LOCAL_USER="${AITVARAS_PRIVACY_USER:-$(whoami)}"
    [[ -n "$LOCAL_USER" ]] && PATTERNS+=("$LOCAL_USER")
fi

FAILED=0
fail() { echo "✗ $1" >&2; FAILED=1; }

for pattern in "${PATTERNS[@]}"; do
    if hits=$("${GREP[@]}" --line-number --fixed-strings -e "$pattern" -- . "${EXCLUDES[@]}"); then
        fail "forbidden pattern tracked: $pattern"
        echo "$hits" | head -5 >&2
    fi
done

# A pasted Home Assistant long-lived token and many other bearer credentials
# are JWT-shaped. Fixtures should use short, plainly synthetic values instead.
if hits=$("${GREP[@]}" --line-number -E -e '[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' -- . "${EXCLUDES[@]}"); then
    fail "likely JWT/bearer token tracked"
    echo "$hits" | head -5 >&2
fi

# Live speech recognition itself never saves audio. Source-audio persistence
# belongs exclusively to the separately consented CaptureAudioRecorder path.
if "${GREP[@]}" --quiet --fixed-strings -e "AVAudioFile" -- Sources/AitvarasVoice/TranscriberSession.swift; then
    fail "live transcriber contains an audio-file persistence path"
fi

# Focus sampling is explicitly memory-only. App names may influence a local
# nudge or spoken session summary, but must never enter the durable event JSON.
if "${GREP[@]}" --quiet --fixed-strings -e "detailJSON" -- App/FocusCoach.swift; then
    fail "Focus Coach contains a durable detail payload for memory-only app usage"
fi

# Machine-local notes must stay untracked.
for local in CLAUDE.local.md AGENTS.local.md .claude/settings.local.json; do
    if git ls-files --error-unmatch "$local" >/dev/null 2>&1; then
        fail "$local is tracked; it must stay gitignored"
    fi
done

[[ "$FAILED" -eq 0 ]] && echo "✓ privacy checks passed"
exit "$FAILED"
