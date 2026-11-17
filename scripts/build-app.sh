#!/bin/bash
# Builds Overseer.app (Release) into ./build. Pass --install to copy it to ~/Applications and open it.
# The version comes from ./VERSION; set BUILD_NUMBER to stamp CFBundleVersion (CI uses the run number).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
APP="build/Overseer.app"

xcodebuild -project Overseer.xcodeproj -scheme Overseer -configuration Release \
    -derivedDataPath build/DerivedData \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build -quiet

rm -rf "$APP"
/usr/bin/ditto build/DerivedData/Build/Products/Release/Overseer.app "$APP"
codesign --verify --deep "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x Overseer 2>/dev/null || true
    rm -rf ~/Applications/Overseer.app
    /usr/bin/ditto "$APP" ~/Applications/Overseer.app
    open ~/Applications/Overseer.app
    echo "Installed to ~/Applications/Overseer.app"
fi
