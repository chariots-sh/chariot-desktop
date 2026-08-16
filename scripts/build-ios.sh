#!/bin/bash
# Build ChariotMobile for the iOS simulator without an .xcodeproj:
# compile the app sources + shared AgentLinkKit sources directly with swiftc
# and assemble the .app bundle by hand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ChariotMobile.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios17.0-simulator"

rm -rf "$OUT"
mkdir -p "$OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -parse-as-library \
  -O \
  -module-name ChariotMobile \
  "$ROOT"/ChariotMobile/Sources/*.swift \
  "$ROOT"/AgentLinkKit/Sources/AgentLinkKit/*.swift \
  -o "$OUT/ChariotMobile"

cp "$ROOT/ChariotMobile/Info.plist" "$OUT/Info.plist"
codesign --force --sign - "$OUT"
echo "built: $OUT"
