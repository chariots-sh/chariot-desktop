#!/bin/bash
# Build a distributable "Chariot Desktop.app": Developer ID signed, hardened
# runtime, notarized, stapled, and packaged as a DMG that is itself notarized
# and stapled.
#
# This is the only path that produces something safe to put on the web.
# scripts/build-app.sh produces an ad-hoc signed bundle for local development;
# Gatekeeper refuses that one outright once it carries a quarantine flag.
#
# Required environment:
#   SPARKLE_PUBLIC_ED_KEY   EdDSA public key from Sparkle's generate_keys
#   NOTARY_PROFILE          notarytool keychain profile name (see docs/distribution.md)
# Optional:
#   VERSION                 marketing version; defaults to the git tag, else 0.0.0-dev
#   SIGNING_IDENTITY        defaults to the sole "Developer ID Application" identity
#   SPARKLE_FEED_URL        defaults to the GitHub Pages appcast
#   SKIP_NOTARIZE=1         build and sign only — for testing the pipeline
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Chariot Desktop"
BUNDLE_ID="dev.chariot.desktop"
OUT="$ROOT/build/release"

# --- preconditions -----------------------------------------------------------

: "${SPARKLE_PUBLIC_ED_KEY:?set SPARKLE_PUBLIC_ED_KEY (see docs/distribution.md); shipping without it would leave the update feed unverifiable}"
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE, or SKIP_NOTARIZE=1 to build without notarizing}"
fi

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  # `|| true`: under `set -o pipefail` a grep miss would abort the script here,
  # swallowing the explanation below — which is the case a first-time release
  # is most likely to hit.
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  cat >&2 <<'MSG'
No "Developer ID Application" certificate found in the keychain.

An "Apple Development" certificate cannot be used for distribution outside the
App Store. Only the team's Account Holder can create a Developer ID cert, at
https://developer.apple.com/account/resources/certificates → "+" → Developer ID
Application. See docs/distribution.md.
MSG
  exit 1
fi

TEAM_ID="$(echo "$SIGNING_IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0-dev)}"
# Monotonic build number; Sparkle compares CFBundleVersion to order releases.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
FEED_URL="${SPARKLE_FEED_URL:-https://chariots-sh.github.io/chariot-desktop/appcast.xml}"

echo "==> Chariot Desktop $VERSION (build $BUILD_NUMBER)"
echo "    identity: $SIGNING_IDENTITY"
echo "    team:     $TEAM_ID"
echo "    feed:     $FEED_URL"

# --- generate the Xcode project ---------------------------------------------

command -v xcodegen >/dev/null || { echo "xcodegen not installed: brew install xcodegen" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" >/dev/null

# --- archive -----------------------------------------------------------------

# Xcode embeds and signs Sparkle.framework (with its nested XPC services and
# Updater.app) and the agent-tailnet helper as part of the archive, which is why
# the release path goes through xcodebuild rather than the hand-rolled bundle.
ARCHIVE="$OUT/ChariotDesktop.xcarchive"
xcodebuild archive \
  -project "$ROOT/Chariot.xcodeproj" \
  -scheme ChariotDesktop \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  SPARKLE_FEED_URL="$FEED_URL" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  | grep -E "^(\*\*|error:|warning: .*deprecated)" || true

[[ -d "$ARCHIVE" ]] || { echo "archive failed" >&2; exit 1; }

# --- export ------------------------------------------------------------------

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  | grep -E "^(\*\*|error:)" || true

APP="$OUT/export/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "export failed: no $APP" >&2; exit 1; }

# --- verify the signature before spending a notarization round trip ----------

codesign --verify --deep --strict --verbose=2 "$APP"
# The virtualization entitlement must survive to the shipped binary; without it
# the app launches and then fails to create any VM.
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -extract com.apple.security.virtualization raw - >/dev/null \
  || { echo "signed app is missing com.apple.security.virtualization" >&2; exit 1; }

PLIST_PATH="$APP/Contents/Info.plist"
embedded_key="$(plutil -extract SUPublicEDKey raw "$PLIST_PATH" 2>/dev/null || echo "")"
[[ "$embedded_key" == "$SPARKLE_PUBLIC_ED_KEY" ]] \
  || { echo "SUPublicEDKey did not make it into Info.plist" >&2; exit 1; }

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> Signed, notarization skipped: $APP"
  exit 0
fi

# --- notarize the app --------------------------------------------------------

echo "==> Notarizing the app…"
ZIP="$OUT/$APP_NAME.zip"
# ditto preserves the bundle's symlinks and extended attributes; `zip` does not.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# --- package the DMG ---------------------------------------------------------

echo "==> Building the DMG…"
DMG="$OUT/ChariotDesktop-$VERSION.dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# The DMG is signed and notarized separately: the staple on the app inside does
# not cover the disk image the user actually downloads.
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# --- final check -------------------------------------------------------------

echo "==> Verifying Gatekeeper acceptance…"
spctl --assess --type open --context context:primary-signature -v "$DMG"
xcrun stapler validate "$DMG"

echo
echo "distributable: $DMG"
echo "sha256:        $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "Next: scripts/make-appcast.sh \"$DMG\" to sign it into the update feed."
