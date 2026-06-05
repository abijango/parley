#!/usr/bin/env python3
import glob, json, os, sys
from datetime import datetime, timezone
from collections import defaultdict

# --- find session logs (override with arg) ---
pat = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/projects/*[Pp]arley*/*.jsonl")
files = glob.glob(pat)
if not files:
    sys.exit(f"No session logs at {pat}")

IDLE_GAP = 30 * 60          # >30 min with no events = you stepped away
events = []
for f in files:
    for line in open(f, errors="ignore"):
        try:
            t = json.loads(line)["timestamp"]
            events.append(datetime.fromisoformat(t.replace("Z", "+00:00")))
        except Exception:
            pass
events.sort()
if not events:
    sys.exit("No timestamped events found.")

# --- cluster into active sessions ---
sessions, start, prev = [], events[0], events[0]
for t in events[1:]:
    if (t - prev).total_seconds() > IDLE_GAP:
        sessions.append((start, prev)); start = t
    prev = t
sessions.append((start, prev))

active = sum((b - a).total_seconds() for a, b in sessions) / 3600
span   = (events[-1] - events[0]).total_seconds() / 3600

# --- bucket active minutes per calendar day (local time) ---
per_day = defaultdict(float)
for a, b in sessions:
    a, b = a.astimezone(), b.astimezone()
    per_day[a.date()] += (b - a).total_seconds() / 3600   # sessions don't cross midnight often; fine for an estimate

print(f"\n  Parley — Claude Code session analysis")
print(f"  files: {len(files)}   events: {len(events)}   work-sessions: {len(sessions)}")
print(f"  first: {events[0].astimezone():%Y-%m-%d %H:%M}   last: {events[-1].astimezone():%Y-%m-%d %H:%M}")
print(f"  calendar span: {span:.1f} h     ACTIVE time: {active:.1f} h\n")

mx = max(per_day.values())
for d in sorted(per_day):
    h = per_day[d]
    bar = "█" * round(h / mx * 40)
    print(f"  {d:%a %m-%d}  {h:5.2f}h  {bar}")
print()