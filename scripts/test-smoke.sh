#!/bin/zsh
# Pre-push smoke gate (docs/TESTING.md Layer 4):
# package tests + app compile + tracked-file privacy sweep.
set -e
cd "$(dirname "$0")/.."

echo "── Layer 1: swift test ──────────────────────────────"
swift test 2>&1 | tail -3

echo "── Layer 2: app target build ────────────────────────"
xcodegen generate --quiet 2>/dev/null || xcodegen generate
xcodebuild -project Aitvaras.xcodeproj -scheme Aitvaras -configuration Debug \
    -derivedDataPath .build-xcode \
    -skipMacroValidation -skipPackagePluginValidation build 2>&1 \
    | grep -E "BUILD (SUCCEEDED|FAILED)"

echo "── Privacy sweep (tracked files) ────────────────────"
SELF="scripts/prepare-public-release.sh scripts/test-smoke.sh"
LOCAL_USER="$(whoami)"
PATTERNS=(
    "/Users/"
    "@gmail.com"
    "@tum.de"
    "Co-Authored-By"
    "M4 Max"
    "36 GB"
    "$LOCAL_USER"
)
FAILED=0
for pattern in "${PATTERNS[@]}"; do
    if git grep -I --fixed-strings -- "$pattern" -- . \
        ":(exclude)scripts/prepare-public-release.sh" \
        ":(exclude)scripts/test-smoke.sh" >/dev/null 2>&1; then
        echo "✗ forbidden pattern tracked: $pattern"
        FAILED=1
    fi
done

# A pasted Home Assistant long-lived token and many other bearer credentials
# are JWT-shaped. Reject likely three-segment tokens from every tracked file;
# fixtures should use short, plainly synthetic values instead.
if git grep -I -E -- '[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}' \
    -- . >/dev/null 2>&1; then
    echo "✗ likely JWT/bearer token tracked"
    FAILED=1
fi

# Live speech recognition itself never saves audio. Source-audio persistence
# belongs exclusively to the separately consented CaptureAudioRecorder path.
if git grep -I --fixed-strings -- "AVAudioFile" -- \
    Sources/AitvarasVoice/TranscriberSession.swift >/dev/null 2>&1; then
    echo "✗ live transcriber contains an audio-file persistence path"
    FAILED=1
fi

# Focus sampling is explicitly memory-only. App names may influence a local
# nudge or spoken session summary, but must never enter the durable event JSON.
if git grep -I --fixed-strings -- "detailJSON" -- \
    App/FocusCoach.swift >/dev/null 2>&1; then
    echo "✗ Focus Coach contains a durable detail payload for memory-only app usage"
    FAILED=1
fi
[ "$FAILED" -eq 0 ] && echo "✓ tracked-file privacy checks passed"
exit $FAILED
