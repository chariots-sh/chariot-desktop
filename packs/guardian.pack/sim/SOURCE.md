# Vendored: mitosim

Mitochondria In Silico — possible skeletal-muscle energy mechanisms during
running, as distributions with explicit uncertainty.

- Source: https://github.com/Immortal-Protocols/mitosim
- Vendored from commit `a78621319685717b3b6e337b26fa5e8cd141515c` (v0.2.0)
- Contents: the `mitosim/` package (including `validation/` and `web/`) and
  `examples/`. Tests, docs, and CI are deliberately not shipped to the guest.

To refresh, run `scripts/sync-mitosim.sh` from the repo root (it re-copies
from `~/mitosim` and rewrites the commit line above). Pack sync pushes the
changed files into existing Guardian VMs on their next turn.

Runtime dependencies (numpy, scipy) are NOT vendored — the guest installs
them into `/workspace/sim/.venv` on first use via `tools/mitosim.sh`.
