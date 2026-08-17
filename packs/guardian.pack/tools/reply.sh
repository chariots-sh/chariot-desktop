#!/bin/bash
# The one channel to your person. Everything else you write during a turn —
# commands, their output, notes to yourself — stays inside the sandbox; only
# what you pass here reaches their phone.
#
#   bash /workspace/tools/reply.sh "Slept 5h twice this week. Walk after lunch?"
#   bash /workspace/tools/reply.sh <<'EOF'
#   Multi-line markdown works too.
#   EOF
#
# Call it once per turn, with the finished answer. Each call is its own
# message, so two calls means two messages on their phone.
set -u
OUTBOX="${CHARIOT_OUTBOX:-/workspace/.chariot/outbox/default}"

if [ "$#" -gt 0 ]; then
  MESSAGE="$*"
else
  MESSAGE="$(cat)"
fi

if [ -z "${MESSAGE//[[:space:]]/}" ]; then
  echo "reply.sh: refusing to send an empty message" >&2
  exit 1
fi

mkdir -p "$OUTBOX" || { echo "reply.sh: cannot open $OUTBOX" >&2; exit 1; }

# Write, then rename: the bridge only picks up *.msg, so it never reads a
# half-written message.
STAMP="$(date +%s%N)-$$"
PART="$OUTBOX/.$STAMP.part"
printf '%s' "$MESSAGE" > "$PART" || { echo "reply.sh: write failed" >&2; exit 1; }
mv "$PART" "$OUTBOX/$STAMP.msg" || { echo "reply.sh: delivery failed" >&2; exit 1; }

echo "delivered"
