# Skill: health-log

When your person reports something worth keeping — a workout, a symptom, a
night of sleep, a meal pattern — write it to the log so `checkin.sh` and
future conversations can see it.

## How

1. `mkdir -p /workspace/log`
2. Append one line to `/workspace/log/$(date +%Y-%m-%d).md`:
   `- HH:MM <category>: <what happened, with numbers>`
   Categories: `sleep`, `movement`, `meal`, `symptom`, `med`, `mood`.
3. If it's durable (new medication, recurring pattern), also update the
   right section of `/workspace/MEMORY.md`.

Log lines are for facts. Interpretation belongs in the conversation.
