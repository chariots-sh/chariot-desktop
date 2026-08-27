# Vendored: mitosim

Mitochondria In Silico — possible skeletal-muscle energy mechanisms during
running, as distributions with explicit uncertainty.

- Source: https://github.com/Immortal-Protocols/mitosim
- Vendored from commit `ef695a9a942c7a0890abe12080c2f362e9a5ca0d` (v0.2.0)
- Contents: the `mitosim/` package (including `validation/` and `web/`) and
  `examples/`. Tests, docs, and CI are deliberately not shipped to the guest.

To refresh, run `scripts/sync-mitosim.sh` from the repo root (it re-copies
from `~/mitosim` and rewrites the commit line above). Pack sync pushes the
changed files into existing Guardian VMs on their next turn.

Runtime dependencies (numpy, scipy) are NOT vendored — the guest installs
them into `/workspace/sim/.venv` on first use via `tools/mitosim.sh`.
