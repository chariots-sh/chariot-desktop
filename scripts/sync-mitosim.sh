#!/bin/bash
# Refresh the mitosim copy vendored in packs/guardian.pack/sim from a local
# checkout (default ~/mitosim). Rewrites SOURCE.md's commit line so the pack
# always says exactly what it ships.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-$HOME/mitosim}"
DEST=packs/guardian.pack/sim

[ -d "$SRC/mitosim" ] || { echo "no mitosim package at $SRC" >&2; exit 1; }

rsync -a --delete --exclude '__pycache__' --exclude '.mypy_cache' \
  "$SRC/mitosim" "$DEST/"
rsync -a --delete "$SRC/examples" "$DEST/"

COMMIT=$(git -C "$SRC" rev-parse HEAD)
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$SRC/pyproject.toml" | head -1)
sed -i '' "s|^- Vendored from commit .*|- Vendored from commit \`$COMMIT\` (v$VERSION)|" \
  "$DEST/SOURCE.md"

echo "vendored mitosim $VERSION ($COMMIT) into $DEST"
