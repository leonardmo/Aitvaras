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
[ "$FAILED" -eq 0 ] && echo "✓ no personal identifiers in tracked files"
exit $FAILED
