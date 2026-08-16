#!/bin/bash
# Guardian's daily check-in snapshot. Grounds the check-in in what was
# actually recorded: the phone's data archive first (the source of truth,
# re-uploaded before every message), Guardian's own observation log second.
set -u
ARCHIVE="/workspace/data/alist-archive.json"
LOG_DIR="/workspace/log"
TODAY="$(date +%Y-%m-%d)"

echo "guardian-checkin v2 (${TODAY})"

if [ -f "$ARCHIVE" ]; then
  python3 - "$ARCHIVE" <<'PYEOF'
import json, sys
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    doc = json.load(f)
data = doc.get("data", {})
manifest = doc.get("manifest", {})
today = datetime.now(timezone.utc).date().isoformat()

def day(value):
    """Row dates are Unix epoch seconds (manifest dates are ISO strings)."""
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc).date().isoformat()
    return str(value)[:10]

def clock(value):
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc).strftime("%H:%M")
    return str(value)[11:16]

entries = data.get("entries", [])
print(f"phone archive: {manifest.get('exportedAt', 'unknown time')}, "
      f"{len(entries)} entries total")

# Derived rows (e.g. hydration synthesized from a meal's water_ml) shadow
# the entry the person actually made — count only what they logged.
authored = [e for e in entries if not e.get("derivedFrom")]
todays = [e for e in authored if day(e.get("effectiveDate", "")) == today]
print(f"entries today (UTC {today}): {len(todays)}")
for e in sorted(todays, key=lambda e: e.get("createdAt") or 0)[-5:]:
    content = str(e.get("content", "")).replace("\n", " ")[:80]
    print(f"  - {clock(e.get('createdAt', ''))} {content}")

doses = [d for d in data.get("supplementDoses", [])
         if day(d.get("takenAt", d.get("createdAt", ""))) == today]
meds = [d for d in data.get("medicationDoses", [])
        if day(d.get("takenAt", d.get("createdAt", ""))) == today]
print(f"supplement doses today: {len(doses)}, medication doses today: {len(meds)}")
PYEOF
else
  echo "phone archive: none — the phone has not uploaded data yet"
fi

if [ -d "$LOG_DIR" ] && [ -n "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
  echo "guardian log entries on file: $(ls "$LOG_DIR" | wc -l | tr -d ' ')"
else
  echo "guardian log entries on file: 0"
fi
echo "token: GUARDIAN-CHECKIN-OK"
