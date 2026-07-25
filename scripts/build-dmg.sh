#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

# Builds a signed, notarized .dmg for RunShortcutsMCP (drag-to-Applications).
#
# Prerequisite: scripts/build-app.sh has already produced a signed
#   build/RunShortcutsMCP.app
#
# Signing uses your Developer ID Application identity:
#   export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#
# Notarization uses the same credentials as scripts/notarize.sh:
#   - a stored keychain profile (NOTARY_PROFILE, default "grumptech-notary"),
#     optionally in a non-default keychain via NOTARY_KEYCHAIN; or
#   - an App Store Connect API key via NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER.
#
# Usage:
#   ./scripts/build-dmg.sh

APP_NAME="RunShortcutsMCP"
VOL_NAME="RunShortcutsMCP"
SIGN_ID="${CODESIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-grumptech-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/$APP_NAME.app"
DMG="build/$APP_NAME.dmg"

[[ -d "$APP" ]] || { echo "Missing $APP — run scripts/build-app.sh first."; exit 1; }

# Stage the disk-image contents: the app, a drag target, and the manual/example.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Tuck the reference files into a Resources/ subfolder so the disk-image window
# shows just the app and the Applications drag target at the top level. The
# manual ships as HTML (rendered by build-app.sh into build/MANUAL.html) so users
# can open it in a browser without a Markdown viewer.
[[ -f build/MANUAL.html ]] || { echo "Missing build/MANUAL.html — run scripts/build-app.sh first."; exit 1; }
mkdir -p "$STAGE/Resources"
cp build/MANUAL.html "$STAGE/Resources/MANUAL.html"
cp assets/RunShortcutsMCP.config.example "$STAGE/Resources/RunShortcutsMCP.config.example"
cp assets/TagNote.shortcut "$STAGE/Resources/TagNote.shortcut"

rm -f "$DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# Sign the disk image with Developer ID Application (same cert as the app).
if [[ -n "$SIGN_ID" ]]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
    codesign --verify --verbose=2 "$DMG"
    echo "Signed DMG with: $SIGN_ID"
else
    echo "WARNING: CODESIGN_IDENTITY not set — DMG is unsigned (won't notarize)."
    echo "Built (unsigned): $DMG"
    exit 0
fi

# Notarize + staple, mirroring scripts/notarize.sh credential resolution.
if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    CREDS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    CREDS=(--keychain-profile "$PROFILE")
    [[ -n "${NOTARY_KEYCHAIN:-}" ]] && CREDS+=(--keychain "$NOTARY_KEYCHAIN")
fi

xcrun notarytool submit "$DMG" "${CREDS[@]}" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "Notarized and stapled: $DMG"
