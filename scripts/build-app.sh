#!/bin/bash
# Build "Chariot Desktop.app": SPM release build + manual bundle + ad-hoc
# signature carrying the virtualization entitlement.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ChariotMac"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Chariot Desktop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ChariotDesktopApp" "$APP/Contents/MacOS/Chariot Desktop"
cp "$ROOT/guest/bridge.py" "$ROOT/guest/user-data.template" "$APP/Contents/Resources/"
if [[ ! -f "$ROOT/build/AppIcon.icns" ]]; then
  swift "$ROOT/scripts/gen-icon.swift" "$ROOT/build/icon-1024.png"
  mkdir -p "$ROOT/build/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/build/icon-1024.png" --out "$ROOT/build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d "$ROOT/build/icon-1024.png" --out "$ROOT/build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Chariot Desktop</string>
    <key>CFBundleIdentifier</key><string>dev.chariot.desktop</string>
    <key>CFBundleName</key><string>Chariot Desktop</string>
    <key>CFBundleDisplayName</key><string>Chariot Desktop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - \
  --entitlements "$ROOT/ChariotMac/virtualization.entitlements" "$APP"
echo "built: $APP"
