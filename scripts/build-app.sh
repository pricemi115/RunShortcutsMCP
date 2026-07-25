#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
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

# Render the manual to a standalone HTML page end users can just double-click.
# The Markdown in assets/MANUAL.md stays the maintainable source of truth.
mkdir -p build
"$BIN_DIR/md2html" assets/MANUAL.md build/MANUAL.html

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp packaging/Info.plist "$APP/Contents/Info.plist"

# Stamp the marketing version from the single-source VERSION file into the bundle.
VERSION_STR="$(tr -d ' \t\r\n' < VERSION)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION_STR" "$APP/Contents/Info.plist"
echo "Stamped version: $VERSION_STR"

# Bundle the (HTML) manual + example config so the app can self-provision them
# into the per-user config folder on first run. Copied before signing so they're
# inside the signed bundle.
cp build/MANUAL.html "$APP/Contents/Resources/MANUAL.html"
cp assets/RunShortcutsMCP.config.example "$APP/Contents/Resources/RunShortcutsMCP.config.example"
cp assets/TagNote.shortcut "$APP/Contents/Resources/TagNote.shortcut"

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

# Ship the HTML manual and a sample allowlist next to the app (outside the signed
# bundle so they stay editable and don't affect the signature). MANUAL.html was
# already rendered into build/ above.
cp assets/RunShortcutsMCP.config.example "build/RunShortcutsMCP.config.example"
cp assets/TagNote.shortcut build/

echo "Built: $APP"
echo "Executable for MCP config: $ROOT/$APP/Contents/MacOS/$APP_NAME"
echo "Distributables in build/: $APP_NAME.app, MANUAL.html, RunShortcutsMCP.config.example, TagNote.shortcut"
