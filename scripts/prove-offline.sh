#!/bin/bash
# Proves the App Sandbox without a network entitlement refuses every way out:
# the probe runs as an app signed with Scrub's exact entitlements and launched
# the way users launch apps, after an unsandboxed control run shows the same
# probe does get through.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product NetworkProbe
BIN="$(swift build -c release --show-bin-path)/NetworkProbe"
rm -rf build/probe
for kind in control sandboxed; do
  APP="build/probe/$kind.app"
  mkdir -p "$APP/Contents/MacOS"
  cp "$BIN" "$APP/Contents/MacOS/NetworkProbe"
  plutil -convert xml1 -o "$APP/Contents/Info.plist" Support/Info.plist
  plutil -replace CFBundleIdentifier -string "app.scrub.mac.probe.$kind" "$APP/Contents/Info.plist"
  plutil -replace CFBundleExecutable -string NetworkProbe "$APP/Contents/Info.plist"
  plutil -replace LSUIElement -bool true "$APP/Contents/Info.plist"
done
codesign --force --sign - --options runtime build/probe/control.app
codesign --force --sign - --options runtime --entitlements Support/Scrub.entitlements build/probe/sandboxed.app
/usr/bin/python3 scripts/prove-offline.py build/probe build/Scrub.app
