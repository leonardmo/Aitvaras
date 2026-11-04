#!/bin/zsh
# Compile the actual avatar renderer without starting or building ML engines.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CHECK="$ROOT/.build/avatar-renderer-checks"
HOST="$ROOT/.build/AvatarRendererDiagnostic.app"
FRAMEWORK="${GLTFKIT2_FRAMEWORK:-$ROOT/.build/DerivedData/Build/Products/Release/GLTFKit2.framework}"
if [[ ! -d "$FRAMEWORK" ]]; then
    print -u2 'Resolve the app packages first, or set GLTFKIT2_FRAMEWORK to its downloaded macOS framework.'
    exit 1
fi
mkdir -p "$CHECK/Tests" "$HOST/Contents/MacOS" "$HOST/Contents/Resources" "$HOST/Contents/Frameworks"
cp scripts/avatar-renderer-harness/Package.template.swift "$CHECK/Package.swift"
ln -sfn ../../Sources/AitvarasCore "$CHECK/Core"
for FILE in AvatarRenderPolicyTests.swift DragonRuntimeAssetTests.swift; do
    ln -sfn "../../../Tests/AitvarasCoreTests/$FILE" "$CHECK/Tests/$FILE"
done
swift test --package-path "$CHECK" --jobs 4
BIN="$(swift build --package-path "$CHECK" --show-bin-path)"
if [[ -f "$BIN/AitvarasCore.o" ]]; then
    CORE_OBJECTS=("$BIN/AitvarasCore.o")
    CORE_MODULES="$BIN"
else
    CORE_OBJECTS=("$BIN/AitvarasCore.build/"*.o)
    CORE_MODULES="$BIN/Modules"
fi
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -target arm64-apple-macos26.0 -I "$CORE_MODULES" -F "$(dirname "$FRAMEWORK")" \
    -framework GLTFKit2 -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${CORE_OBJECTS[@]}" \
    App/Companion/AvatarView.swift App/Companion/AvatarRenderLifecycle.swift \
    App/AvatarShot.swift App/AvatarEfficiencyCheck.swift \
    scripts/avatar-renderer-harness/DiagnosticApp.swift \
    -o "$HOST/Contents/MacOS/AvatarRendererDiagnostic"
cp scripts/avatar-renderer-harness/Info.plist "$HOST/Contents/Info.plist"
cp App/Resources/AitvarasDragonRuntime.glb App/Resources/AitvarasAvatar.glb "$HOST/Contents/Resources/"
ditto "$FRAMEWORK" "$HOST/Contents/Frameworks/GLTFKit2.framework"
codesign --force --deep --sign - "$HOST"
"$HOST/Contents/MacOS/AvatarRendererDiagnostic" "$@"
