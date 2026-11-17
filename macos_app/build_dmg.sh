#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$REPO_ROOT/PDF Scanner.app"
DMG_PATH="$REPO_ROOT/PDF-Scanner.dmg"

"$SCRIPT_DIR/build_app.sh"

STAGE_DIR="$(mktemp -d /tmp/pdf_scanner_dmg.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -R "$APP_DIR" "$STAGE_DIR/PDF Scanner.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "PDF Scanner" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Created DMG: $DMG_PATH"
ls -lh "$DMG_PATH"
