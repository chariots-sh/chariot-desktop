#!/bin/bash
# Build "Chariot Desktop.app": SPM release build + manual bundle + ad-hoc
# signature carrying the virtualization entitlement.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ChariotMac"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

"$ROOT/scripts/build-helper.sh" "$ROOT/build/agent-tailnet"

APP="$ROOT/build/Chariot Desktop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/ChariotDesktopApp" "$APP/Contents/MacOS/Chariot Desktop"
# The embedded Tailscale node ships inside the bundle and is signed with it.
cp "$ROOT/build/agent-tailnet" "$APP/Contents/MacOS/agent-tailnet"

# Sparkle. `swift build` links it but embeds nothing, so the framework is
# copied in by hand and the rpath added; the release build (scripts/release-app.sh
# → xcodebuild) gets all of this from Xcode instead. This bundle carries no
# SUFeedURL/SUPublicEDKey, so UpdaterController.isConfigured is false and the
# updater stays dormant in dev builds.
# `2>/dev/null` and `|| true`: under `set -o pipefail` a find over a directory
# that does not exist yet aborts before the message below can explain why.
SPARKLE="$(find "$ROOT/ChariotMac/.build/artifacts" -maxdepth 6 -type d -name Sparkle.framework 2>/dev/null | head -1 || true)"
if [[ -z "$SPARKLE" ]]; then
  echo "Sparkle.framework not found — run 'swift package resolve' in ChariotMac" >&2
  exit 1
fi
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Chariot Desktop"
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

# Sign inside-out: nested code first, the app last. `--deep` is not used —
# it would stamp the virtualization entitlement onto Sparkle's helpers, which
# notarization rejects. Release builds swap `-` for a Developer ID and add
# --timestamp; see scripts/release-app.sh.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for nested in "$FW/Versions/B/XPCServices/Downloader.xpc" \
              "$FW/Versions/B/XPCServices/Installer.xpc" \
              "$FW/Versions/B/Updater.app" \
              "$FW/Versions/B/Autoupdate"; do
  [[ -e "$nested" ]] && codesign --force --options runtime --sign - "$nested"
done
codesign --force --options runtime --sign - "$FW"
codesign --force --options runtime --sign - "$APP/Contents/MacOS/agent-tailnet"
# ChariotDesktop-adhoc.entitlements, not virtualization.entitlements: the
# hardened runtime validates that embedded frameworks share the main binary's
# Team ID, and ad-hoc signatures have none — so without the exception in that
# file the app cannot load Sparkle.framework and dies at launch.
codesign --force --options runtime --sign - \
  --entitlements "$ROOT/ChariotMac/ChariotDesktop-adhoc.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "built: $APP"
