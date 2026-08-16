#!/bin/bash
# End-to-end transport test over loopback (no tailnet, no VM): builds chariotd
# and a phone-simulating harness, then exercises QR v2 pairing (incl. atomic
# single-use replay rejection), WebSocket challenge-response auth (incl. a
# forged signature), message roundtrip with acks, duplicate delivery, offline
# replay after reconnect, and revocation. The same code paths carry the
# tailnet traffic in production — agent-tailnet just fronts them with TLS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${CHARIOT_E2E_PORT:-9787}"
WORK="$(mktemp -d)"
trap 'kill $CHARIOTD_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

cd "$ROOT/ChariotMac" && swift build >/dev/null
BIN="$(swift build --show-bin-path)"
codesign --force --sign - --entitlements "$ROOT/ChariotMac/virtualization.entitlements" "$BIN/chariotd" 2>/dev/null

xcrun swiftc -parse-as-library -module-name E2EPhone \
  "$ROOT/tests/e2e-phone.swift" "$ROOT"/AgentLinkKit/Sources/AgentLinkKit/*.swift \
  -o "$WORK/e2e-phone"

"$BIN/chariotd" --data-dir "$WORK/data" --base-image /dev/null \
  --guest-resources "$ROOT/guest" --port "$PORT" --no-vm --no-tailscale \
  > "$WORK/chariotd.log" 2>&1 &
CHARIOTD_PID=$!
sleep 2

CHARIOT_E2E_PORT="$PORT" "$WORK/e2e-phone"
