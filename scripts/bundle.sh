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
# The models' weights (name, address and context models) and the name lists; all are looked for in Contents/Resources.
ditto "$BIN/Scrub_ScrubCore.bundle" "$APP/Contents/Resources/Scrub_ScrubCore.bundle"
# The span tagger's weights live outside git (scripts/make-span-tagger.py builds them). A release
# carries them, checked against the checksum the code pins; a build without them only warns.
WEIGHTS=Models/SpanTagger.bin
PINNED=$(sed -n 's/.*static let checksum = "\([0-9a-f]\{64\}\)".*/\1/p' Sources/ScrubCore/SpanTagger.swift)
if [ -f "$WEIGHTS" ]; then
  [ "$(shasum -a 256 "$WEIGHTS" | cut -d' ' -f1)" = "$PINNED" ] || { echo "$WEIGHTS does not match the checksum SpanTagger.swift pins" >&2; exit 1; }
  cp "$WEIGHTS" "$APP/Contents/Resources/Scrub_ScrubCore.bundle/SpanTagger.bin"
elif [ "${SCRUB_REQUIRE_TAGGER:-0}" = 1 ]; then
  echo "$WEIGHTS is missing; run scripts/make-span-tagger.py" >&2; exit 1
else
  echo "warning: $WEIGHTS is missing, so this build has no span tagger" >&2
fi
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
TIMESTAMP=$([ "$IDENTITY" = "-" ] && echo "--timestamp=none" || echo "--timestamp")
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements Support/Scrub.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
