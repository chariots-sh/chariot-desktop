#!/bin/bash
# Build the cloud-init NoCloud seed ISO for a Chariot instance.
# Usage: make-seed.sh <instance-dir>
# Expects/creates <instance-dir>/access-key(.pub); writes <instance-dir>/seed.iso
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCE_DIR="${1:?usage: make-seed.sh <instance-dir>}"
mkdir -p "$INSTANCE_DIR"

# Per-instance developer-access SSH keypair (design §1.5).
if [[ ! -f "$INSTANCE_DIR/access-key" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "chariot-developer-access" -f "$INSTANCE_DIR/access-key"
fi
PUBKEY="$(cat "$INSTANCE_DIR/access-key.pub")"
BRIDGE_B64="$(base64 -i "$ROOT/guest/bridge.py" | tr -d '\n')"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/cidata"

sed -e "s|__SSH_PUBKEY__|$PUBKEY|" \
    -e "s|__BRIDGE_B64__|$BRIDGE_B64|" \
    "$ROOT/guest/user-data.template" > "$WORK/cidata/user-data"

cat > "$WORK/cidata/meta-data" <<EOF
instance-id: chariot-$(basename "$INSTANCE_DIR")
local-hostname: chariot-sandbox
EOF

rm -f "$INSTANCE_DIR/seed.iso"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata \
  -o "$INSTANCE_DIR/seed.iso" "$WORK/cidata"
echo "seed written: $INSTANCE_DIR/seed.iso"
