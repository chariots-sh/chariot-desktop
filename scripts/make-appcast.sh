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

# generate_appcast ships inside Sparkle's SPM binary artifact. `2>/dev/null`
# and `|| true` matter: the directory does not exist until the package has been
# resolved, and under `set -o pipefail` a failing find aborts the script before
# the diagnostics below can run.
find_tool() {
  find "$ROOT/ChariotMac/.build/artifacts" -type f -name "$1" 2>/dev/null | head -1 || true
}

GENERATE="$(find_tool generate_appcast)"
if [[ -z "$GENERATE" ]]; then
  # A release built with xcodebuild resolves packages into DerivedData, never
  # into ChariotMac/.build, so on a fresh runner this artifact is simply absent.
  # Fetch it rather than making the caller know that.
  echo "==> Fetching Sparkle's release tools"
  swift package resolve --package-path "$ROOT/ChariotMac" >/dev/null
  GENERATE="$(find_tool generate_appcast)"
fi
if [[ -z "$GENERATE" ]]; then
  echo "generate_appcast not found even after resolving Sparkle in ChariotMac" >&2
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

ARGS=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --link "https://github.com/$REPO"
  --maximum-versions 5
  -o "$STAGE/appcast.xml"
)

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  # Sparkle's own documented CI pattern: the key arrives on stdin, so it never
  # lands on the runner's filesystem where a later step could pick it up.
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE" --ed-key-file - "${ARGS[@]}" "$STAGE"
elif [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$GENERATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "${ARGS[@]}" "$STAGE"
else
  # No key supplied: generate_appcast falls back to the login keychain, under
  # the default "ed25519" account that generate_keys writes to.
  "$GENERATE" "${ARGS[@]}" "$STAGE"
fi

echo
echo "appcast: $STAGE/appcast.xml"
echo "publish this file at $FEED_URL"
echo
# `|| true`: a grep miss here must not fail a run that already succeeded.
grep -E "sparkle:(version|shortVersionString|edSignature)|<enclosure" "$STAGE/appcast.xml" | tail -6 || true
