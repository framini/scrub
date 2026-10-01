#!/bin/bash
# Builds Scrub.app into build/. Signs ad hoc unless SCRUB_SIGN_IDENTITY names a
# Developer ID; either way with the hardened runtime and the App Sandbox.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SCRUB_SIGN_IDENTITY:--}"
swift build -c release --product Scrub
APP=build/Scrub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --show-bin-path)"
cp "$BIN/Scrub" "$APP/Contents/MacOS/Scrub"
# The models' weights (name model, context model parts); both look for them in Contents/Resources.
ditto "$BIN/Scrub_ScrubCore.bundle" "$APP/Contents/Resources/Scrub_ScrubCore.bundle"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
TIMESTAMP=$([ "$IDENTITY" = "-" ] && echo "--timestamp=none" || echo "--timestamp")
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements Support/Scrub.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
