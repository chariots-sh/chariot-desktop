#!/bin/bash
# Build the agent-tailnet helper (embedded Tailscale node) reproducibly:
# pure-Go (CGO off), trimmed paths, stripped build IDs, versions pinned by
# go.mod/go.sum. Produces a universal binary covering every architecture the
# app supports.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/agent-tailnet}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

cd "$ROOT/agent-tailnet"
FLAGS=(-trimpath -ldflags "-s -w -buildid=")

CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build "${FLAGS[@]}" -o "$OUT.arm64" .
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build "${FLAGS[@]}" -o "$OUT.amd64" .
lipo -create "$OUT.arm64" "$OUT.amd64" -output "$OUT"
rm "$OUT.arm64" "$OUT.amd64"
echo "built: $OUT ($(lipo -archs "$OUT"))"
