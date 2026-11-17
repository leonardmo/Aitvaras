#!/usr/bin/env bash
# Runs the XCUITest suite against a separately identified Debug build and exports
# its screenshots. Usage: scripts/run-e2e.sh [AitvarasUITests/Class[/testMethod]]
set -euo pipefail
cd "$(dirname "$0")/.."
out=.build-e2e
result="$out/result.xcresult"
shots="$out/screenshots"
rm -rf "$result" "$shots"
mkdir -p "$shots"
filter=()
if [[ $# -gt 0 ]]; then filter=("-only-testing:$1"); fi
status=0
xcodebuild test -project Aitvaras.xcodeproj -scheme Aitvaras -configuration Debug \
    -skipMacroValidation -skipPackagePluginValidation \
    -derivedDataPath "$out" -resultBundlePath "$result" \
    -destination 'platform=macOS,arch=arm64' \
    AITVARAS_BUNDLE_ID=app.aitvaras.AitvarasE2E \
    "${filter[@]+"${filter[@]}"}" > "$out/test.log" 2>&1 || status=$?
grep -E "^(Test Suite|Test Case|.*error:|\*\* TEST)|Test run with" "$out/test.log" | tail -40 || true
if [[ -d "$result" ]]; then
    xcrun xcresulttool export attachments --path "$result" --output-path "$shots" >/dev/null 2>&1 || true
    python3 - "$shots" <<'PY'
import json, os, sys
root = sys.argv[1]
manifest = os.path.join(root, "manifest.json")
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for item in test.get("attachments", []):
            source = os.path.join(root, item["exportedFileName"])
            name = item.get("suggestedHumanReadableName", item["exportedFileName"])
            name = name.split("_")[0] + os.path.splitext(source)[1]
            if os.path.exists(source):
                os.replace(source, os.path.join(root, name))
PY
    echo "Screenshots: $shots"
fi
[[ $status -eq 0 ]] || echo "Full log: $out/test.log"
exit "$status"
