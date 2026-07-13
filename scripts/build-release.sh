#!/bin/zsh
# Build Aitvaras (Release) and install to /Applications.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodegen generate
xcodebuild -project Aitvaras.xcodeproj -scheme Aitvaras -configuration Release \
    -derivedDataPath .build/DerivedData -skipMacroValidation -skipPackagePluginValidation build | tail -3

APP=.build/DerivedData/Build/Products/Release/Aitvaras.app
if [ -d "$APP" ]; then
    rm -rf /Applications/Aitvaras.app
    cp -R "$APP" /Applications/Aitvaras.app
    echo "Installed /Applications/Aitvaras.app"
else
    echo "Build product not found" >&2
    exit 1
fi
