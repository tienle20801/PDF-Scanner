#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PYTHON_BIN="$REPO_ROOT/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="$(command -v python3)"
fi

echo "==> Running Python Phase 1 tests..."
"$PYTHON_BIN" -m unittest discover -s tests -v

echo "==> Compiling & running Swift tests..."
TMP_BIN="$(mktemp /tmp/pdfscanner_swift_tests.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT

swiftc -parse-as-library \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework CoreText \
  -framework ImageIO \
  -framework PDFKit \
  -framework UniformTypeIdentifiers \
  -framework Vision \
  "$REPO_ROOT/macos_app/Sources/AppConstants.swift" \
  "$REPO_ROOT/macos_app/Sources/Models.swift" \
  "$REPO_ROOT/macos_app/Sources/PDFToolsService.swift" \
  "$REPO_ROOT/macos_app/Sources/ScannerBridge.swift" \
  "$REPO_ROOT/tests/test_swift_bridge_and_tools.swift" \
  -o "$TMP_BIN"

"$TMP_BIN"
