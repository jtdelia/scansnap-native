#!/bin/zsh
# Builds ScanSnap.app and installs it into ~/Applications.
set -euo pipefail

ROOT=${0:A:h:h}
BUILD="$ROOT/.build/app"
APP="$BUILD/ScanSnap.app"
INSTALL_DIR="$HOME/Applications"

cd "$ROOT"
swift build -c release --product ScanSnapNative

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScanSnapNative "$APP/Contents/MacOS/ScanSnap"

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
    <key>CFBundleName</key><string>ScanSnap</string>
    <key>CFBundleDisplayName</key><string>ScanSnap</string>
    <key>CFBundleIdentifier</key><string>com.taii.ScanSnapNative</string>
    <key>CFBundleExecutable</key><string>ScanSnap</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Native driver for ScanSnap S1300 / S1300i.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

mkdir -p "$INSTALL_DIR"
LOG="$HOME/Library/Logs/ScanSnap.log"
while pgrep -x ScanSnap >/dev/null && [[ -f "$LOG" ]] && grep "connection:" "$LOG" | tail -1 | grep -q "Scanning"; do
  echo "Waiting for the current scan to finish before replacing the app…"
  sleep 3
done
pkill -x ScanSnap 2>/dev/null || true
rm -rf "$INSTALL_DIR/ScanSnap.app"
cp -R "$APP" "$INSTALL_DIR/"
echo "Installed $INSTALL_DIR/ScanSnap.app"
