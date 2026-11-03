#!/bin/zsh
# Offline focused checks; no app build/launch/install and no native Codex process.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CHECK="$ROOT/.build/codex-native-checks"
mkdir -p "$CHECK/Core" "$CHECK/Connectors/Resources" "$CHECK/Tests"
cp scripts/codex-native-harness/Package.template.swift "$CHECK/Package.swift"
ln -sfn "$ROOT/Sources/AitvarasCore/Workspace/CodexNativeProtocol.swift" "$CHECK/Core/CodexNativeProtocol.swift"
ln -sfn "$ROOT/Sources/AitvarasCore/AitvarasPaths.swift" "$CHECK/Core/AitvarasPaths.swift"
for FILE in CodexNativeClient.swift CodexSharedRuntimeClient.swift; do
    ln -sfn "$ROOT/Sources/AitvarasConnectors/$FILE" "$CHECK/Connectors/$FILE"
done
ln -sfn "$ROOT/scripts/codex-native-harness/Support.swift" "$CHECK/Connectors/Support.swift"
for FILE in codex-native.mjs codex-shared-runtime.mjs; do
    ln -sfn "$ROOT/Sources/AitvarasConnectors/Resources/$FILE" "$CHECK/Connectors/Resources/$FILE"
done
ln -sfn "$ROOT/Tests/AitvarasCoreTests/CodexNativeClientTests.swift" "$CHECK/Tests/CodexNativeClientTests.swift"
node scripts/check-codex-native.mjs
swift test --package-path "$CHECK" --jobs 2
