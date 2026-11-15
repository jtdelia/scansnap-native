#!/bin/zsh
# Builds Yomi.app and installs it into ~/Applications.
set -euo pipefail

ROOT=${0:A:h:h}
BUILD="$ROOT/.build/app"
APP="$BUILD/Yomi.app"
INSTALL_DIR="$HOME/Applications"

cd "$ROOT"
swift build -c release --product YomiApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/YomiApp "$APP/Contents/MacOS/Yomi"

if [[ ! -f "$BUILD/AppIcon.icns" ]]; then
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$BUILD/icon-1024.png"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$BUILD/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$BUILD/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Yomi</string>
    <key>CFBundleDisplayName</key><string>Yomi</string>
    <key>CFBundleIdentifier</key><string>io.github.jtdelia.Yomi</string>
    <key>CFBundleExecutable</key><string>Yomi</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPhotoLibraryUsageDescription</key><string>Yomi saves scanned photos to the album you choose in its scan profiles.</string>
    <key>NSPhotoLibraryAddUsageDescription</key><string>Yomi saves scanned photos to Photos.</string>
    <key>NSHumanReadableCopyright</key><string>Native driver for ScanSnap S1300 / S1300i.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

mkdir -p "$INSTALL_DIR"
LOG="$HOME/Library/Logs/Yomi.log"
while pgrep -x Yomi >/dev/null && [[ -f "$LOG" ]] && grep "connection:" "$LOG" | tail -1 | grep -q "Scanning"; do
  echo "Waiting for the current scan to finish before replacing the app…"
  sleep 3
done
pkill -x Yomi 2>/dev/null || true
rm -rf "$INSTALL_DIR/Yomi.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "Installed $INSTALL_DIR/Yomi.app"
