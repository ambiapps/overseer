#!/bin/bash
# Builds Overseer.app and packages it as build/Overseer-<version>-<build>.dmg with an Applications
# shortcut. Prints the DMG path on the last line.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
DMG="build/Overseer-$VERSION-$BUILD_NUMBER.dmg"

BUILD_NUMBER="$BUILD_NUMBER" ./scripts/build-app.sh >&2

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto build/Overseer.app "$STAGING/Overseer.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Overseer" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
