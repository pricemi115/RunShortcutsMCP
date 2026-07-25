#!/usr/bin/env bash
set -euo pipefail

# Notarizes the signed .app for Developer ID distribution (NOT the App Store —
# this architecture can't be sandboxed; see README "Distribution").
#
# Authenticates with an App Store Connect API key — no Apple ID, no app-specific
# password, and nothing personal is embedded in the app. The key only authorizes
# the upload to Apple's notary service.
#
# One-time credential setup — store the API key in a keychain profile:
#   xcrun notarytool store-credentials "grumptech-notary" \
#       --key   /path/to/AuthKey_ABCD1234.p8 \
#       --key-id ABCD1234 \
#       --issuer 11111111-2222-3333-4444-555555555555
#
# To keep the profile OUT of the default (login) keychain, create a dedicated
# keychain and add --keychain to BOTH store-credentials and submit:
#   security create-keychain -p "<pw>" ~/Library/Keychains/grumptech.keychain-db
#   security unlock-keychain  -p "<pw>" ~/Library/Keychains/grumptech.keychain-db
#   xcrun notarytool store-credentials "grumptech-notary" ... \
#       --keychain ~/Library/Keychains/grumptech.keychain-db
# then run this script with NOTARY_KEYCHAIN set (see below). Note: --keychain
# cannot be combined with --sync (iCloud Keychain).
#
# Get these from App Store Connect -> Users and Access -> Integrations ->
# App Store Connect API:
#   --key      the .p8 private key file (downloadable ONCE — store it safely)
#   --key-id   the Key ID listed next to the key
#   --issuer   the Issuer ID shown at the top of the Keys page
#
# Usage:
#   ./scripts/notarize.sh
#
# CI / no stored profile: set these env vars and the script uses the key directly:
#   NOTARY_KEY (path to .p8), NOTARY_KEY_ID, NOTARY_ISSUER
#
# Non-default keychain: set NOTARY_KEYCHAIN to the keychain that holds the profile
# (e.g. ~/Library/Keychains/grumptech.keychain-db). Unlock it first if it's locked.
#
# Requires: scripts/build-app.sh already produced a *signed* build/RunShortcutsMCP.app

APP_NAME="RunShortcutsMCP"
PROFILE="${NOTARY_PROFILE:-grumptech-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/$APP_NAME.app"
ZIP="build/$APP_NAME.zip"

[[ -d "$APP" ]] || { echo "Missing $APP — run scripts/build-app.sh (signed) first."; exit 1; }

# Prefer an explicit API key from the environment; otherwise use the stored profile.
if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    CREDS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    CREDS=(--keychain-profile "$PROFILE")
    [[ -n "${NOTARY_KEYCHAIN:-}" ]] && CREDS+=(--keychain "$NOTARY_KEYCHAIN")
fi

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${CREDS[@]}" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "Notarized and stapled: $APP"
