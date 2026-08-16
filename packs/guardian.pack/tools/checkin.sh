#!/bin/bash
# Guardian's daily check-in snapshot. Prints today's log status so Guardian
# can ground its check-in in what was actually recorded, not vibes.
set -u
LOG_DIR="/workspace/log"
TODAY="$(date +%Y-%m-%d)"

echo "guardian-checkin v1 (${TODAY})"
if [ -d "$LOG_DIR" ] && [ -n "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
  ENTRIES=$(ls "$LOG_DIR" | wc -l | tr -d ' ')
  echo "log entries on file: ${ENTRIES}"
  LATEST=$(ls -t "$LOG_DIR" | head -1)
  echo "latest entry: ${LATEST}"
else
  echo "log entries on file: 0"
  echo "latest entry: none — nothing logged yet"
fi
echo "token: GUARDIAN-CHECKIN-OK"
