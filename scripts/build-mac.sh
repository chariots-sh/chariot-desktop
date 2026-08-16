#!/bin/bash
# Build chariotd and sign it with the virtualization entitlement.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ChariotMac"
swift build "$@"
BIN="$(swift build "$@" --show-bin-path)"
codesign --force --sign - --entitlements "$ROOT/ChariotMac/virtualization.entitlements" "$BIN/chariotd"
echo "signed: $BIN/chariotd"
