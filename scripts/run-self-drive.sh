#!/usr/bin/env bash
# Runs a self-drive scenario against a separately identified Debug build, with no
# system permission, password or effect on the mouse and keyboard. Real CLIs on the
# real login, in a throwaway profile and project. See docs/TESTING.md.
# Usage: scripts/run-self-drive.sh [scenario] [timeout seconds] [--no-build]
set -uo pipefail
cd "$(dirname "$0")/.."
scenario="${1:-golden-path}"; limit="${2:-900}"; nobuild="${3:-}"
derived=.build-e2e
out="$PWD/$derived/self-drive/$scenario"
if [[ "$nobuild" != "--no-build" ]]; then
    mkdir -p "$derived"
    xcodegen generate --quiet || exit 2
    xcodebuild -project Aitvaras.xcodeproj -scheme Aitvaras -configuration Debug \
        -skipMacroValidation -skipPackagePluginValidation -derivedDataPath "$derived" \
        AITVARAS_BUNDLE_ID=app.aitvaras.AitvarasE2E build > "$derived/self-drive-build.log" 2>&1 \
        || { grep -E ' error: |BUILD FAILED' "$derived/self-drive-build.log" | sort -u | head -30; exit 2; }
fi
app="$derived/Build/Products/Debug/Aitvaras.app/Contents/MacOS/Aitvaras"
[[ -x "$app" ]] || { echo "No app build at $app"; exit 2; }
state="$(mktemp -d)"; project="$(mktemp -d)"
rm -rf "$out"; mkdir -p "$out"
git -C "$project" init -q
echo "Throwaway test project" > "$project/README.md"
git -C "$project" add README.md
git -C "$project" -c user.name=test -c user.email=test@example.invalid commit -q -m init
env AITVARAS_SELF_DRIVE="$PWD/UITests/self-drive/$scenario.json" AITVARAS_SELF_DRIVE_OUTPUT="$out" \
    AITVARAS_SELF_DRIVE_PROJECT="$project" AITVARAS_SELF_DRIVE_CODEX_MODEL="${AITVARAS_SELF_DRIVE_CODEX_MODEL:-gpt-6-luna}" \
    AITVARAS_STATE_DIR="$state" AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS=1 \
    AITVARAS_AGENT_TEST_PROVIDERS=real "$app" > "$out/app.log" 2>&1 &
pid=$!
elapsed=0
while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $limit ]]; do
    /bin/sleep 2; elapsed=$((elapsed + 2))
done
if kill -0 "$pid" 2>/dev/null; then echo "Timed out after ${limit}s"; kill "$pid"; fi
wait "$pid" 2>/dev/null
[[ -f "$out/startup-error.txt" ]] && { cat "$out/startup-error.txt"; echo; exit 1; }
python3 - "$out/results.json" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception as error:
    sys.exit(f"No results: {error}")
failed = [r for r in rows if r.get("status") == "failed"]
for row in failed:
    print(f"step {row.get('index')} failed: {row.get('action')}: {(row.get('reason') or '')[:200]}")
print(f"{len(rows)} steps, {len(failed)} failed")
sys.exit(1 if failed else 0)
PY
status=$?
echo "Screenshots: $out"
exit "$status"
