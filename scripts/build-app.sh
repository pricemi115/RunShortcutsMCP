#!/usr/bin/env bash
set -euo pipefail

# Builds the RunShortcutsMCP executable and wraps it in a .app bundle so macOS
# TCC attributes automation permissions to a stable, signed bundle identity.
#
# Usage:
#   ./scripts/build-app.sh [debug|release]
#
# To sign, export your Developer ID before running:
#   export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"

APP_NAME="RunShortcutsMCP"
CONFIG="${1:-release}"
SIGN_ID="${CODESIGN_IDENTITY:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp packaging/Info.plist "$APP/Contents/Info.plist"

if [[ -n "$SIGN_ID" ]]; then
    codesign --force --options runtime \
        --entitlements packaging/RunShortcutsMCP.entitlements \
        --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Signed with: $SIGN_ID"
else
    echo "WARNING: CODESIGN_IDENTITY not set — bundle is unsigned."
    echo "         Set CODESIGN_IDENTITY to your Developer ID and re-run to sign."
fi

# Ship the user manual and a sample allowlist next to the app (outside the signed
# bundle so they stay editable and don't affect the signature).
cp MANUAL.md build/
cp allowlist.example.json "build/$APP_NAME.config.example"

echo "Built: $APP"
echo "Executable for MCP config: $ROOT/$APP/Contents/MacOS/$APP_NAME"
echo "Distributables in build/: $APP_NAME.app, MANUAL.md, $APP_NAME.config.example"
