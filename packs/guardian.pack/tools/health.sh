#!/bin/bash
# Guardian's HealthKit snapshot summary: what the phone's sensors recorded,
# as opposed to what your person logged by hand (that's checkin.sh). Reads
# the read-only snapshot the phone uploads before each turn.
set -u
RECORDS="/workspace/data/healthkit-records.json"
TODAY="$(date +%Y-%m-%d)"

echo "guardian-health v1 (${TODAY})"

if [ -f "$RECORDS" ]; then
  python3 - "$RECORDS" <<'PYEOF'
import json, sys
from collections import Counter
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    doc = json.load(f)
records = doc.get("records", [])

collected = doc.get("collected_at")
if isinstance(collected, (int, float)):
    collected = datetime.fromtimestamp(collected, tz=timezone.utc).isoformat()
print(f"healthkit snapshot: collected {collected or 'unknown time'} "
      f"(tz {doc.get('timezone', 'unknown')}), {len(records)} records")

counts = Counter(r.get("healthkit_data_type") or "unknown" for r in records)
print("records per type:")
for dtype, n in counts.most_common():
    print(f"  {dtype}: {n}")

today = datetime.now(timezone.utc).date()

def payload(record):
    """`json_data` is stringified JSON; a row we cannot parse counts as empty."""
    try:
        data = json.loads(record.get("json_data") or "{}")
        return data if isinstance(data, dict) else {}
    except ValueError:
        return {}

def is_today(record):
    ts = record.get("relevant_timestamp_seconds")
    return (isinstance(ts, (int, float))
            and datetime.fromtimestamp(ts, tz=timezone.utc).date() == today)

def quantity(record):
    for key in ("value", "quantity", "sum", "count"):
        v = payload(record).get(key)
        if isinstance(v, (int, float)):
            return v
    return None

def todays(fragment):
    return [r for r in records if fragment in (r.get("healthkit_data_type") or "")
            and is_today(r)]

print(f"today (UTC {today}):")
for label, fragment, reduce in (("steps", "StepCount", "sum"),
                                ("active energy", "ActiveEnergyBurned", "sum"),
                                ("resting heart rate", "RestingHeartRate", "avg")):
    values = [v for r in todays(fragment) for v in [quantity(r)] if v is not None]
    if not values:
        print(f"  {label}: no data")
    elif reduce == "sum":
        print(f"  {label}: {round(sum(values), 1)}")
    else:
        print(f"  {label}: {round(sum(values) / len(values), 1)} (avg of {len(values)})")
sleep_rows = todays("SleepAnalysis")
print(f"  sleep records: {len(sleep_rows)}")
PYEOF
else
  echo "no health data — the phone has not uploaded any yet"
fi
echo "token: GUARDIAN-HEALTH-OK"
