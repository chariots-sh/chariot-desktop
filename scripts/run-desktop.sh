#!/bin/bash
# Launch the Chariot Desktop GUI app with sensible defaults for this checkout.
# Stop chariotd first if it is running (both default to port 8787):
#   pkill -TERM -f chariotd
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CHARIOT_BASE_IMAGE="${CHARIOT_BASE_IMAGE:-$ROOT/guest-images/debian-12-genericcloud-arm64.raw}"
export CHARIOT_DATA_DIR="${CHARIOT_DATA_DIR:-$ROOT/chariot-data}"
exec "$ROOT/build/Chariot Desktop.app/Contents/MacOS/Chariot Desktop"
