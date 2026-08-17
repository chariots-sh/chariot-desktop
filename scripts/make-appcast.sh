#!/bin/bash
# Sign a released DMG into the Sparkle update feed and emit the appcast.xml to
# publish to GitHub Pages.
#
#   scripts/make-appcast.sh build/release/ChariotDesktop-0.2.0.dmg
#
# The existing feed is fetched first and updated in place, so entries for past
# releases keep the download URLs they were published with — generate_appcast
# applies --download-url-prefix only to archives it has not seen before, and
# each release lives under its own tag.
#
# The private key never appears on the command line. By default it is read from
# the login keychain, where `generate_keys` put it; CI passes it as a file via
# SPARKLE_PRIVATE_KEY_FILE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DMG="${1:-}"
[[ -f "$DMG" ]] || { echo "usage: $0 <path-to-notarized.dmg>" >&2; exit 1; }

REPO="${GITHUB_REPOSITORY:-chariots-sh/chariot-desktop}"
VERSION="${VERSION:-$(basename "$DMG" .dmg | sed 's/^ChariotDesktop-//')}"
TAG="${TAG:-v$VERSION}"
FEED_URL="${SPARKLE_FEED_URL:-https://chariots-sh.github.io/chariot-desktop/appcast.xml}"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

GENERATE="$(find "$ROOT/ChariotMac/.build/artifacts" -type f -name generate_appcast | head -1)"
if [[ -z "$GENERATE" ]]; then
  echo "generate_appcast not found — run 'swift package resolve' in ChariotMac" >&2
  exit 1
fi

STAGE="$ROOT/build/appcast"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"

# Seed with the published feed so this release is appended rather than
# replacing the history. A missing feed (first ever release) is fine.
if curl -sfL "$FEED_URL" -o "$STAGE/appcast.xml"; then
  echo "==> Updating the existing feed ($(grep -c "<item>" "$STAGE/appcast.xml" || echo 0) entries)"
else
  echo "==> No published feed yet; creating the first one"
fi

SIGNING_ARGS=()
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  SIGNING_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
else
  # generate_keys stores the key under this account in the login keychain.
  SIGNING_ARGS=(--account "ed25519")
fi

"$GENERATE" \
  "${SIGNING_ARGS[@]}" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/$REPO" \
  --maximum-versions 5 \
  -o "$STAGE/appcast.xml" \
  "$STAGE"

echo
echo "appcast: $STAGE/appcast.xml"
echo "publish this file at $FEED_URL"
echo
grep -E "sparkle:(version|shortVersionString|edSignature)|<enclosure" "$STAGE/appcast.xml" | tail -6
