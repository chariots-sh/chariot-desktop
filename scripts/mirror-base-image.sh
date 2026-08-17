#!/bin/bash
# Mirror the Debian guest base image as a GitHub release asset, and print the
# BaseImageRelease values to paste into ChariotCore/BaseImageInstaller.swift.
#
# Why mirror at all: cloud.debian.org keeps only about three dated builds and
# prunes the rest, so a pinned upstream URL 404s within weeks. `latest/` stays
# up but silently changes bytes, which would mean two installs of the same
# Chariot version running different guests. The mirror is permanent and the
# digest names exactly one image.
#
#   scripts/mirror-base-image.sh              # mirror current upstream latest
#   scripts/mirror-base-image.sh 20260806-2562 # mirror a specific dated build
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-chariots-sh/chariot-desktop}"
WORK="$ROOT/build/base-image-mirror"
IMAGE="debian-12-genericcloud-arm64"

BUILD="${1:-latest}"
BASE="https://cloud.debian.org/images/cloud/bookworm/$BUILD"
if [[ "$BUILD" == "latest" ]]; then
  TARBALL_URL="$BASE/$IMAGE.tar.xz"
  JSON_URL="$BASE/$IMAGE.json"
else
  TARBALL_URL="$BASE/$IMAGE-$BUILD.tar.xz"
  JSON_URL="$BASE/$IMAGE-$BUILD.json"
fi

mkdir -p "$WORK"
cd "$WORK"

echo "==> Downloading $TARBALL_URL"
curl -fL --progress-bar -o "$IMAGE.tar.xz" "$TARBALL_URL"

# Debian's own build stamp becomes the asset tag and the pinned version.
VERSION="$(curl -sfL "$JSON_URL" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["data"]["info"]["version"])')"
[[ -n "$VERSION" ]] || { echo "could not read the Debian build version" >&2; exit 1; }

SHA="$(shasum -a 256 "$IMAGE.tar.xz" | cut -d' ' -f1)"
COMPRESSED="$(stat -f%z "$IMAGE.tar.xz")"

# Confirm the archive is shaped the way BaseImageInstaller expects before it
# becomes the thing every user downloads.
echo "==> Verifying archive contents"
MEMBERS="$(tar -tf "$IMAGE.tar.xz")"
[[ "$MEMBERS" == "disk.raw" ]] || {
  echo "expected a single disk.raw member, got:" >&2; echo "$MEMBERS" >&2; exit 1; }
EXPANDED="$(tar -tvf "$IMAGE.tar.xz" | awk '{print $5}')"

TAG="base-image-$VERSION"
echo
echo "==> Debian $VERSION"
echo "    compressed: $COMPRESSED bytes"
echo "    expanded:   $EXPANDED bytes"
echo "    sha256:     $SHA"
echo

cat <<SWIFT
Paste into ChariotMac/Sources/ChariotCore/BaseImageInstaller.swift:

    public static let pinned = BaseImageRelease(
        version: "$VERSION",
        url: URL(string: "https://github.com/$REPO/releases/download/$TAG/$IMAGE.tar.xz")!,
        sha256: "$SHA",
        compressedBytes: $COMPRESSED,
        expandedBytes: $EXPANDED)
SWIFT

if [[ "${UPLOAD:-0}" != "1" ]]; then
  echo
  echo "Dry run. Re-run with UPLOAD=1 to publish the asset to $REPO."
  exit 0
fi

command -v gh >/dev/null || { echo "gh CLI required to upload" >&2; exit 1; }
echo "==> Publishing $TAG to $REPO"
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" \
    --title "Guest base image $VERSION" \
    --notes "Debian 12 (bookworm) genericcloud arm64, build $VERSION, mirrored from cloud.debian.org.

sha256: \`$SHA\`

Downloaded by Chariot Desktop on first run. Not an app release." \
    --latest=false
fi
gh release upload "$TAG" "$IMAGE.tar.xz" --repo "$REPO" --clobber
echo "==> Uploaded. Update BaseImageRelease.pinned, then rebuild."
