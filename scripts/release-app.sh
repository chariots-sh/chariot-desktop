#!/bin/bash
# Build a distributable "Chariot Desktop.app" and package it as a DMG.
#
# Two signing modes:
#
#   developer-id  Developer ID signed, notarized, stapled. Opens with a double
#                 click. Requires a "Developer ID Application" certificate,
#                 which only a team's Account Holder can create.
#
#   adhoc         Ad-hoc signed (`codesign -s -`). Cannot be notarized, so
#                 Gatekeeper blocks the first launch and the user has to allow
#                 it explicitly once. Auto-update still works: Sparkle accepts
#                 an update whose EdDSA key matches, independently of the code
#                 signing identity, and it clears quarantine on what it
#                 installs — so the manual step is first-install-only.
#
# The mode is chosen automatically from whether a Developer ID certificate is
# present; ADHOC=1 forces ad-hoc even when one is.
#
# Required environment:
#   SPARKLE_PUBLIC_ED_KEY   EdDSA public key from Sparkle's generate_keys
#   NOTARY_PROFILE          notarytool keychain profile (developer-id mode only)
# Optional:
#   ADHOC=1                 force ad-hoc signing
#   VERSION                 marketing version; defaults to the git tag, else 0.0.0-dev
#   SIGNING_IDENTITY        override the auto-detected Developer ID identity
#   SPARKLE_FEED_URL        defaults to the GitHub Pages appcast
#   SKIP_NOTARIZE=1         developer-id mode: sign but skip the notarization round trip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Chariot Desktop"
OUT="$ROOT/build/release"

# --- preconditions -----------------------------------------------------------

# Required in both modes: this is the key Sparkle actually verifies updates
# against, and in ad-hoc mode it is the *only* thing standing between a user and
# a malicious update. Losing or rotating it strands every install.
: "${SPARKLE_PUBLIC_ED_KEY:?set SPARKLE_PUBLIC_ED_KEY (see docs/distribution.md); without it updates cannot be verified at all}"

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  # `|| true`: under `set -o pipefail` a grep miss would abort the script here,
  # swallowing the mode selection below.
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi

if [[ "${ADHOC:-0}" == "1" || -z "$SIGNING_IDENTITY" ]]; then
  SIGN_MODE="adhoc"
  SIGNING_IDENTITY="-"
  TEAM_ID=""
else
  SIGN_MODE="developer-id"
  TEAM_ID="$(echo "$SIGNING_IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')"
  if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE, or SKIP_NOTARIZE=1 to build without notarizing}"
  fi
fi

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0-dev)}"
# Monotonic build number; Sparkle compares CFBundleVersion to order releases.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
FEED_URL="${SPARKLE_FEED_URL:-https://chariots-sh.github.io/chariot-desktop/appcast.xml}"

echo "==> Chariot Desktop $VERSION (build $BUILD_NUMBER)"
echo "    mode:     $SIGN_MODE"
echo "    identity: $SIGNING_IDENTITY"
echo "    feed:     $FEED_URL"
if [[ "$SIGN_MODE" == "adhoc" ]]; then
  echo
  echo "    Ad-hoc build: this DMG cannot be notarized. On first launch macOS"
  echo "    will refuse to open it until the user allows it in System Settings"
  echo "    → Privacy & Security. See the INSTALL.txt placed in the DMG."
fi
echo

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
ARCHIVE_ARGS=(
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"
  SPARKLE_FEED_URL="$FEED_URL"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
)
if [[ "$SIGN_MODE" == "adhoc" ]]; then
  # An empty team keeps Xcode from demanding a provisioning profile it cannot
  # get; ad-hoc signing needs no team and no profile.
  ARCHIVE_ARGS+=(DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="")
else
  ARCHIVE_ARGS+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi

xcodebuild archive \
  -project "$ROOT/Chariot.xcodeproj" \
  -scheme ChariotDesktop \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  "${ARCHIVE_ARGS[@]}" \
  | grep -E "^(\*\*|error:)" || true

[[ -d "$ARCHIVE" ]] || { echo "archive failed" >&2; exit 1; }

# --- get the app out of the archive -----------------------------------------

mkdir -p "$OUT/export"
if [[ "$SIGN_MODE" == "developer-id" ]]; then
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
else
  # -exportArchive has no ad-hoc method, and every method it does have wants a
  # real identity. The archived bundle is already correctly signed, so take it.
  cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$OUT/export/"
fi

APP="$OUT/export/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "export failed: no $APP" >&2; exit 1; }

# --- verify the bundle before spending anything on it ------------------------

codesign --verify --deep --strict --verbose=2 "$APP"
# The virtualization entitlement must survive to the shipped binary; without it
# the app launches and then fails to create any VM. The dots in the key are
# escaped because plutil reads `.` as a key-path separator.
entitled="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -extract 'com\.apple\.security\.virtualization' raw - 2>/dev/null || echo "")"
[[ "$entitled" == "true" ]] \
  || { echo "signed app is missing com.apple.security.virtualization" >&2; exit 1; }

PLIST_PATH="$APP/Contents/Info.plist"
embedded_key="$(plutil -extract SUPublicEDKey raw "$PLIST_PATH" 2>/dev/null || echo "")"
[[ "$embedded_key" == "$SPARKLE_PUBLIC_ED_KEY" ]] \
  || { echo "SUPublicEDKey did not make it into Info.plist" >&2; exit 1; }

# Sparkle refuses an update that drops code signing, so an unsigned bundle here
# would quietly break the update path for everyone already installed. Captured
# to a variable rather than piped: `grep -q` closes the pipe on match, and the
# resulting SIGPIPE trips `set -o pipefail`.
signature_info="$(codesign -dv "$APP" 2>&1 || true)"
grep -q "Signature=" <<<"$signature_info" \
  || { echo "app is not code signed at all; Sparkle would reject updates from it" >&2; exit 1; }

# --- notarize (developer-id only) --------------------------------------------

if [[ "$SIGN_MODE" == "developer-id" && "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Notarizing the app…"
  ZIP="$OUT/$APP_NAME.zip"
  # ditto preserves the bundle's symlinks and extended attributes; `zip` does not.
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
elif [[ "$SIGN_MODE" == "developer-id" ]]; then
  echo "==> Signed, notarization skipped: $APP"
  exit 0
fi

# --- package the DMG ---------------------------------------------------------

echo "==> Building the DMG…"
DMG="$OUT/ChariotDesktop-$VERSION.dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

if [[ "$SIGN_MODE" == "adhoc" ]]; then
  # Gatekeeper's refusal is worded as though the app is broken ("damaged"),
  # which reads like a corrupt download rather than a missing signature. Say so
  # in the DMG, where someone stuck on that dialog will actually look.
  cat > "$STAGE/INSTALL.txt" <<'TXT'
Installing Chariot Desktop
==========================

1. Drag "Chariot Desktop" onto the Applications folder in this window.
2. Open it once from Applications. macOS will refuse, saying the app is
   damaged or cannot be verified.
3. Open System Settings -> Privacy & Security, scroll to the bottom, and
   click "Open Anyway" next to the message about Chariot Desktop.
4. Confirm. Chariot Desktop opens, and later launches work normally.

Why: this build is ad-hoc signed rather than signed with an Apple
Developer ID, so it cannot be notarized and Gatekeeper will not open it
without explicit permission. The wording about damage is misleading — it
is what macOS says for any app it cannot verify.

You only do this once. Chariot updates itself after that, and updates
are cryptographically signed and verified before installation.

If you prefer the command line, this achieves the same thing:

    xattr -dr com.apple.quarantine "/Applications/Chariot Desktop.app"
TXT
fi

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ "$SIGN_MODE" == "developer-id" ]]; then
  # The DMG is signed and notarized separately: the staple on the app inside
  # does not cover the disk image the user downloads.
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"

  echo "==> Verifying Gatekeeper acceptance…"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  xcrun stapler validate "$DMG"
else
  # Ad-hoc signing the DMG buys nothing (it cannot be notarized either), and
  # `spctl --assess` is expected to reject it — asserting otherwise would be
  # asserting a lie. Record the actual verdict instead.
  echo "==> Gatekeeper verdict for this build (rejection is expected):"
  spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "distributable: $DMG"
echo "sha256:        $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
if [[ "$SIGN_MODE" == "adhoc" ]]; then
  echo "Publish the sha256 next to the download so users can check it themselves —"
  echo "it is the only integrity signal an unnotarized build offers."
  echo
fi
echo "Next: scripts/make-appcast.sh \"$DMG\" to sign it into the update feed."
