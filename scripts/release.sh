#!/bin/bash
# Builds build/Scrub.dmg: the app signed with a Developer ID, notarized and
# stapled, inside a signed, notarized and stapled disk image. The app is
# stapled on its own too, so Gatekeeper accepts it offline after it has been
# copied out of the image.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SCRUB_SIGN_IDENTITY:?set SCRUB_SIGN_IDENTITY to a Developer ID Application certificate name}"
PROFILE="${SCRUB_NOTARY_PROFILE:-scrub-notary}"
APP=build/Scrub.app
DMG=build/Scrub.dmg

# The real-text gate first, the ordinary sets and then the holdout (see scripts/eval-gate.sh).
# Strict: a release never goes out without both corpora and their baselines.
scripts/eval-gate.sh --strict
scripts/eval-gate.sh --strict --holdout

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait | tee build/notary.log
  grep -q "status: Accepted" build/notary.log
}

scripts/bundle.sh
ditto -c -k --keepParent "$APP" build/Scrub.zip
notarize build/Scrub.zip
xcrun stapler staple "$APP"
rm build/Scrub.zip

STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Scrub.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Scrub -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$SCRUB_SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG"
