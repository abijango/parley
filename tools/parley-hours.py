#!/usr/bin/env python3
"""Estimate total wall-clock time spent developing this app.

The app lived three lives — `transcribe` (abandoned Tauri prototype),
`macsribe` (the native Swift rewrite), `parley` (renamed) — and each era left
its own Claude Code project directory behind. Evidence streams merged here:

  1. Session transcripts   ~/.claude/projects/<era>/*.jsonl
  2. Subagent transcripts  ~/.claude/projects/<era>/*/subagents/*.jsonl
     (background agents keep working while the main session looks idle)
  3. Git author timestamps from repos still on disk (catches manual Xcode
     work committed without Claude running)

All timestamps merge into one stream and cluster into active sessions: a gap
longer than the idle threshold means you stepped away. Review/reading time
between events counts as work — that's the point. Still invisible: thinking
time away from the machine longer than the gap, or review on another device.
"""
import glob, json, os, subprocess, sys
from datetime import datetime, timedelta
from collections import defaultdict

HOME = os.path.expanduser("~")
ERAS = {  # claude-project-dir suffix -> repo path (None = folder renamed away)
    "transcribe": f"{HOME}/work/personal/transcribe",
    "macsribe": None,
    "parley": f"{HOME}/work/personal/parley",
}
GAPS_MIN = [15, 30, 60]   # idle-gap sensitivity; 30 is the headline
HEADLINE_GAP = 30

def jsonl_times(path):
    for line in open(path, errors="ignore"):
        try:
            t = json.loads(line).get("timestamp")
            if t:
                yield datetime.fromisoformat(t.replace("Z", "+00:00"))
        except Exception:
            pass

def git_times(repo):
    try:
        out = subprocess.run(["git", "-C", repo, "log", "--format=%aI"],
                             capture_output=True, text=True, check=True).stdout
        return [datetime.fromisoformat(l) for l in out.split() if l]
    except Exception:
        return []

# --- collect (timestamp, era) events + per-agent busy spans ----------------
events, agent_spans = [], []
for era, repo in ERAS.items():
    proj = f"{HOME}/.claude/projects/-Users-naufalmir-work-personal-{era}"
    for f in glob.glob(f"{proj}/*.jsonl"):
        events += [(t, era) for t in jsonl_times(f)]
    for f in glob.glob(f"{proj}/*/subagents/*.jsonl"):
        ts = sorted(jsonl_times(f))
        events += [(t, era) for t in ts]
        if len(ts) > 1:
            agent_spans.append(ts[-1] - ts[0])
    if repo and os.path.isdir(repo):
        events += [(t, era) for t in git_times(repo)]

if not events:
    sys.exit("No events found.")
events.sort()

# --- cluster into active sessions for a given idle gap ---------------------
def cluster(evts, gap_s):
    sessions, start, prev, cur = [], evts[0][0], evts[0][0], {evts[0][1]}
    for t, era in evts[1:]:
        if (t - prev).total_seconds() > gap_s:
            sessions.append((start, prev, frozenset(cur)))
            start, cur = t, set()
        prev = t
        cur.add(era)
    sessions.append((start, prev, frozenset(cur)))
    return sessions

print(f"\n  Total development time — transcribe + macsribe + parley")
print(f"  events: {len(events):,}   "
      f"span: {events[0][0].astimezone():%Y-%m-%d %H:%M} → {events[-1][0].astimezone():%Y-%m-%d %H:%M}\n")

# Sensitivity: how much the answer moves with the idle-gap assumption.
for gap_min in GAPS_MIN:
    sessions = cluster(events, gap_min * 60)
    raw = sum(((e - s) for s, e, _ in sessions), timedelta())
    # a tiny session still costs real attention; floor each at 5 minutes
    floored = sum((max(e - s, timedelta(minutes=5)) for s, e, _ in sessions), timedelta())
    mark = "   <-- headline" if gap_min == HEADLINE_GAP else ""
    print(f"  gap={gap_min:>2}m: {raw.total_seconds()/3600:6.1f} h raw,"
          f" {floored.total_seconds()/3600:6.1f} h floored"
          f"  ({len(sessions)} sessions){mark}")

sessions = cluster(events, HEADLINE_GAP * 60)
per_day, per_era = defaultdict(timedelta), defaultdict(timedelta)
for s, e, eras in sessions:
    d = max(e - s, timedelta(minutes=5))
    per_day[s.astimezone().date()] += d
    for era in eras:               # a session straddling a rename credits each
        per_era[era] += d / len(eras)

print(f"\n  Per day (gap={HEADLINE_GAP}m, floored):")
mx = max(td.total_seconds() for td in per_day.values()) / 3600
for day in sorted(per_day):
    h = per_day[day].total_seconds() / 3600
    print(f"  {day:%a %m-%d}  {h:5.2f}h  {'█' * round(h / mx * 40)}")

print(f"\n  Per era:")
for era in ERAS:
    h = per_era[era].total_seconds() / 3600
    if h:
        print(f"  {era:<11} {h:6.1f} h")

agent_busy = sum(agent_spans, timedelta()).total_seconds() / 3600
print(f"\n  Subagents: {len(agent_spans)} transcripts, {agent_busy:.1f} h cumulative busy time"
      f"\n  (parallel work — already inside the wall-clock totals above)\n")
