#!/bin/bash
# Guardian's mitochondria simulator (mitosim), vendored at /workspace/sim.
# Usage: bash /workspace/tools/mitosim.sh <mitosim args>
#   e.g. bash /workspace/tools/mitosim.sh run /workspace/sim/profile.json --intensity 0.65 --duration 45
#
# First run bootstraps a virtualenv with numpy/scipy (needs the network; a
# couple of minutes). Later runs start instantly. The venv lives outside the
# pack's file list, so pack re-syncs never touch it; a VM reset wipes it and
# the next run rebuilds it.
set -euo pipefail

SIM=/workspace/sim
VENV="$SIM/.venv"

if [ ! -x "$VENV/bin/python" ]; then
  echo "mitosim: first run — installing python3-venv, numpy, scipy…" >&2
  # Debian ships python3 without ensurepip: install python3-venv first or the
  # venv is a pip-less husk (same dance as the hermes harness preinstall).
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv >/dev/null
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --no-cache-dir numpy scipy
  echo "mitosim: ready" >&2
fi

cd "$SIM"
exec env PYTHONPATH="$SIM" "$VENV/bin/python" -m mitosim.cli "$@"
