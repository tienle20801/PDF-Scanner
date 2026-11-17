#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$SCRIPT_DIR/Sources"
APP_DIR="$REPO_ROOT/PDF Scanner.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"

echo "==> Building PDF Scanner.app ($TARGET)..."
rm -rf "$REPO_ROOT/CamScanner.app" "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/scripts" "$RESOURCES_DIR/bin"

# Bundle scanner scripts + precompiled Vision binary so the app runs standalone when installed via DMG
cp "$REPO_ROOT/scripts/batch_scanner.py" "$RESOURCES_DIR/scripts/batch_scanner.py"
cp "$REPO_ROOT/scripts/pdf_compressor.py" "$RESOURCES_DIR/scripts/pdf_compressor.py"
cp "$REPO_ROOT/scripts/doc_scanner.swift" "$RESOURCES_DIR/scripts/doc_scanner.swift"

echo "==> Precompiling Vision helper (doc_scanner)..."
swiftc -O \
  -target "$TARGET" \
  -framework Foundation \
  -framework CoreImage \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework Vision \
  "$REPO_ROOT/scripts/doc_scanner.swift" \
  -o "$RESOURCES_DIR/bin/doc_scanner"

# Bundle standalone Python runtime + .venv site-packages if .venv is present
VENV_PY="$REPO_ROOT/.venv/bin/python"
if [[ -x "$VENV_PY" ]]; then
  echo "==> Bundling relocatable Python runtime & dependencies..."
  "$VENV_PY" - "$RESOURCES_DIR/python_runtime" << 'PY_BUNDLE'
import os, pathlib, shutil, site, sys

dest = pathlib.Path(sys.argv[1])
base_prefix = pathlib.Path(sys.base_prefix)
site_pkgs = next((pathlib.Path(p) for p in site.getsitepackages() if p.endswith("site-packages") and os.path.isdir(p)), None)
ver_dir = f"python{sys.version_info.major}.{sys.version_info.minor}"
py_bin = pathlib.Path(os.path.realpath(sys.executable))

(dest / "bin").mkdir(parents=True, exist_ok=True)
(dest / "lib").mkdir(parents=True, exist_ok=True)
shutil.copy2(py_bin, dest / "bin" / ver_dir)
os.chmod(dest / "bin" / ver_dir, 0o755)
shutil.copytree(
    base_prefix / "lib" / ver_dir,
    dest / "lib" / ver_dir,
    ignore=shutil.ignore_patterns("__pycache__", "test", "tkinter", "idlelib", "turtledemo", "ensurepip"),
)
if site_pkgs is not None:
    shutil.copytree(
        site_pkgs,
        dest / "site-packages",
        ignore=shutil.ignore_patterns("__pycache__", "*.dist-info"),
    )
PY_BUNDLE
fi

# 1. Generate Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>PDF Scanner</string>
    <key>CFBundleExecutable</key>
    <string>PDFScanner</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.pdfscanner.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PDF Scanner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Document Image or PDF</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
                <string>public.image</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 2. Generate AppIcon.icns using CoreGraphics + iconutil
ICON_TMP="$(mktemp -d /tmp/pdfscanner_icon.XXXXXX)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET_DIR="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" << 'SWIFT_ICON'
import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Rounded background card
    let pad = s * 0.08
    let bgRect = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = s * 0.20
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    let gradColors = [
        CGColor(red: 0.09, green: 0.42, blue: 0.92, alpha: 1.0),
        CGColor(red: 0.05, green: 0.72, blue: 0.76, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: cs, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: bgRect.minX, y: bgRect.maxY),
            end: CGPoint(x: bgRect.maxX, y: bgRect.minY),
            options: []
        )
    }

    // Crisp white paper sheet inside
    let docW = s * 0.48
    let docH = s * 0.60
    let docX = (s - docW) / 2.0
    let docY = (s - docH) / 2.0
    let docRect = CGRect(x: docX, y: docY, width: docW, height: docH)
    let docPath = CGPath(roundedRect: docRect, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.addPath(docPath)
    ctx.fillPath()

    // Document lines
    ctx.setFillColor(CGColor(red: 0.14, green: 0.46, blue: 0.88, alpha: 0.75))
    let lineX = docX + docW * 0.18
    let lineW = docW * 0.64
    let lineH = max(1.0, s * 0.038)
    for step in [0.68, 0.50, 0.32] {
        let ly = docY + docH * step
        let w = (step < 0.4) ? lineW * 0.65 : lineW
        let lr = CGRect(x: lineX, y: ly, width: w, height: lineH)
        ctx.addPath(CGPath(roundedRect: lr, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
        ctx.fillPath()
    }

    // Scan laser line across sheet
    let scanY = docY + docH * 0.58
    ctx.setFillColor(CGColor(red: 0.08, green: 0.85, blue: 0.62, alpha: 0.95))
    ctx.fill(CGRect(x: docX - s * 0.05, y: scanY, width: docW + s * 0.10, height: max(1.5, s * 0.025)))

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

for (name, px) in specs {
    if let data = renderIcon(size: px) {
        try? data.write(to: outDir.appendingPathComponent(name))
    }
}
SWIFT_ICON

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

# 3. Compile Swift sources (including subdirectories under Sources/)
SWIFT_SOURCES=()
while IFS= read -r src_file; do
  SWIFT_SOURCES+=("$src_file")
done < <(find "$SRC_DIR" -type f -name "*.swift" | sort)

swiftc -O -swift-version 5 -parse-as-library \
  -target "$TARGET" \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreText \
  -framework PDFKit \
  -framework Vision \
  -framework CoreImage \
  -framework UniformTypeIdentifiers \
  "${SWIFT_SOURCES[@]}" \
  -o "$MACOS_DIR/PDFScanner"

# 4. Ad-hoc codesign (sign bundled Mach-O executables/extensions before bundle sign)
if [[ -d "$RESOURCES_DIR/python_runtime" ]]; then
  while IFS= read -r macho; do
    codesign --force --sign - "$macho" >/dev/null 2>&1 || true
  done < <(find "$RESOURCES_DIR/python_runtime" -type f \( -name "*.so" -o -name "*.dylib" \))
  codesign --force --sign - "$RESOURCES_DIR/python_runtime/bin"/python* >/dev/null 2>&1 || true
fi
codesign --force --sign - "$RESOURCES_DIR/bin/doc_scanner"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Successfully built: $APP_DIR"
ls -lh "$MACOS_DIR/PDFScanner"
