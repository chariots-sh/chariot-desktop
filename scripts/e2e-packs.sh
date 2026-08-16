#!/bin/bash
# End-to-end agent-pack test (Guardian on Chariot, Milestone 1): builds
# chariotd and the pack harness, seeds a fresh data dir with the two sample
# packs, then proves the acceptance criteria against REAL VMs — two
# concurrent agents, per-pack workspaces, per-agent pairing, hot pack edits,
# pack tools, and reset-with-reseed. Needs the Debian ARM64 base image
# (downloaded if missing) and ~4 GB of RAM headroom; runs locally, not in CI
# (GitHub runners cannot nest Virtualization.framework).
#
# Optional: CHARIOT_E2E_CODEX_AUTH=<path to a codex auth.json> additionally
# runs the persona checks through real Codex turns in both VMs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${CHARIOT_E2E_PORT:-9787}"
BASE_IMAGE="${CHARIOT_BASE_IMAGE:-$ROOT/guest-images/debian-12-genericcloud-arm64.raw}"
WORK="$(mktemp -d)"
trap 'kill $CHARIOTD_PID 2>/dev/null || true; sleep 3; rm -rf "$WORK"' EXIT

if [ ! -f "$BASE_IMAGE" ]; then
  echo "downloading Debian ARM64 cloud image to $BASE_IMAGE…"
  mkdir -p "$(dirname "$BASE_IMAGE")"
  curl -L --fail -o "$BASE_IMAGE" \
    https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.raw
fi

cd "$ROOT/ChariotMac" && swift build >/dev/null
BIN="$(swift build --show-bin-path)"
codesign --force --sign - --entitlements "$ROOT/ChariotMac/virtualization.entitlements" "$BIN/chariotd" 2>/dev/null

xcrun swiftc -parse-as-library -module-name E2EPacks \
  "$ROOT/tests/e2e-packs.swift" "$ROOT"/AgentLinkKit/Sources/AgentLinkKit/*.swift \
  -o "$WORK/e2e-packs"

# Fresh data dir seeded with the sample packs (the harness edits guardian's
# AGENTS.md in place to prove hot re-push).
mkdir -p "$WORK/data/packs"
cp -R "$ROOT/packs/guardian.pack" "$ROOT/packs/scribe.pack" "$WORK/data/packs/"

"$BIN/chariotd" --data-dir "$WORK/data" --base-image "$BASE_IMAGE" \
  --guest-resources "$ROOT/guest" --port "$PORT" --no-vm --no-tailscale \
  > "$WORK/chariotd.log" 2>&1 &
CHARIOTD_PID=$!
sleep 2

set +e
CHARIOT_E2E_PORT="$PORT" CHARIOT_E2E_DATA_DIR="$WORK/data" \
  CHARIOT_E2E_CODEX_AUTH="${CHARIOT_E2E_CODEX_AUTH:-}" "$WORK/e2e-packs"
RESULT=$?
set -e
if [ $RESULT -ne 0 ]; then
  echo "--- chariotd.log (tail) ---"
  tail -40 "$WORK/chariotd.log"
fi
exit $RESULT
