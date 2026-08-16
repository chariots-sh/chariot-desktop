#!/bin/bash
# Scribe's rollup: list the notes on file, newest first, so the digest is
# grounded in what was actually filed.
set -u
NOTES_DIR="/workspace/notes"

echo "scribe-rollup v1 ($(date +%Y-%m-%d))"
if [ -d "$NOTES_DIR" ] && [ -n "$(ls -A "$NOTES_DIR" 2>/dev/null)" ]; then
  COUNT=$(ls "$NOTES_DIR" | wc -l | tr -d ' ')
  echo "notes on file: ${COUNT}"
  for f in $(ls -t "$NOTES_DIR" | head -10); do
    TAGS=$(grep -m1 '^Tags:' "$NOTES_DIR/$f" 2>/dev/null || echo "Tags: (none)")
    echo "- ${f} — ${TAGS}"
  done
else
  echo "notes on file: 0"
fi
echo "token: SCRIBE-ROLLUP-OK"
