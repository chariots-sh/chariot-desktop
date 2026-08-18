#!/bin/bash
# Run a tool on your person's phone. The call executes in their app right
# away — logging water logs it for real — and the phone's answer comes back
# as this script's output.
#
#   bash /workspace/tools/phone.sh log_water '{"millilitres": 600}'
#   bash /workspace/tools/phone.sh day_summary
#
# Args are a single JSON object (default {}). Exit 0 with the result JSON on
# stdout when the phone says ok; exit 1 (with the failure on stdout/stderr)
# when it declines, errors, or cannot be reached. Call phone tools *before*
# your reply.sh — a call made after the turn ends gets no answer.
set -u
TOOL="${1:-}"
ARGS="${2:-}"
[ -n "$ARGS" ] || ARGS="{}"

if [ -z "$TOOL" ]; then
  echo "phone.sh: usage: phone.sh <tool_name> ['<json_args>']" >&2
  exit 1
fi

DIR="${CHARIOT_TOOLCALLS:-/workspace/.chariot/toolcalls/default}"
mkdir -p "$DIR" || { echo "phone.sh: cannot open $DIR" >&2; exit 1; }

# The uuid doubles as the wire request_id and the dropbox filename, so the
# bridge and this script agree on where the answer lands.
ID="$(cat /proc/sys/kernel/random/uuid)"
REQ="$DIR/$ID.req"
RES="$DIR/$ID.res"

# Write, then rename: the bridge only picks up *.req, so it never reads a
# half-written request.
PART="$DIR/.$ID.part"
printf '{"request_id": "%s", "name": "%s", "arguments": %s}' "$ID" "$TOOL" "$ARGS" > "$PART" \
  || { echo "phone.sh: write failed" >&2; exit 1; }
mv "$PART" "$REQ" || { echo "phone.sh: delivery failed" >&2; exit 1; }

# The Mac times the phone out at ~25s and answers with an error, so a healthy
# channel always beats this 30s ceiling.
DEADLINE=$((SECONDS + 30))
while [ ! -f "$RES" ]; do
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    rm -f "$REQ"
    echo "phone.sh: no answer from the phone after 30s" >&2
    exit 1
  fi
  sleep 0.2
done

RESULT="$(cat "$RES")"
rm -f "$RES"
echo "$RESULT"
case "$RESULT" in
  *'"ok": true'*|*'"ok":true'*) exit 0 ;;
  *) exit 1 ;;
esac
