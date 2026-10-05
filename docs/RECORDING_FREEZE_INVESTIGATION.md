# Recording freeze investigation — Aug 3–7 2026

> **Status: ROOT CAUSE IDENTIFIED (Aug 7).** The main thread is **not blocked** — it is
> burning a core inside a combinatorial SwiftUI layout pass: `_FlexFrameLayout.sizeThatFits`
> ↔ `StackLayout.placeChildren`, **9 nested stack levels, 232 frames deep**, rooted at the
> window's `RootGeometry`. One layout pass never completes, so the main actor never reaches
> the next runloop turn and every main-actor timer starves.
>
> `MainActorWatchdog` — built Aug 4, installed Aug 6 15:43 — produced the capture on its
> first exposure. Three prior occurrences could not be diagnosed; this one took minutes.
>
> **Outstanding:** the *mechanism* is known, the *specific view* is not — SwiftUI inlines
> view bodies, so no Parley symbol survives into the stack. Next step is a structural audit
> of the nesting between the window root and `LiveTranscriptView`. See *Aug 7 2026 — fourth
> occurrence* at the end.
>
> Sections below preceding Aug 7 are kept as the investigation record. Where they conclude
> "blocked, not spinning", **they are superseded** — read the Aug 7 section first.

Three calls have now become unresponsive mid-recording (Aug 3, Aug 4, Aug 6). This documents
what the evidence shows, what was lost (nothing, in the final notes), and what to instrument
so the next occurrence is diagnosable.

## Verdict up front

- The app **blocked** — it did not slow down and it did not crash. Every main-actor
  timer stopped output in the same instant, and there is no crash report. Fully
  evidenced for Aug 4; the Aug 3 force-quit is consistent but not confirmed to be the
  same failure (see below). *Qualified by Aug 6:* that occurrence burned a full core and
  tripped a Core Audio real-time overload, which looks like starvation rather than a park —
  see the Aug 6 section.
- **Audio capture kept running** through all three freezes. The mic/system CAF writers live
  on the Core Audio tap thread and an off-main archiver, so they were unaffected.
- **Live transcription stopped** at the freeze (11m45s of live transcript on Aug 4).
- **No conversation was lost from the final notes.** The offline re-pass re-transcribed
  the complete concatenated audio, verified below.
- The root cause of the block is **not identified**, and cannot be from the artefacts that
  exist. One `sample` capture during the next freeze settles it — see *Make the next one
  diagnosable*. The candidates below are ranked by plausibility, not evidence.

## Timeline, reconstructed

Sources: `~/Library/Logs/Parley/parley.log`, APFS birth times on the segment CAFs,
`session.json`, and `/Library/Logs/DiagnosticReports/Parley_*.diag`.

### Aug 4 — session `2026-08-04-110420` ("Intellias <> DBX")

| Wall clock | Event |
|---|---|
| 11:04:20 | Recording starts. `mic.caf` created. |
| 11:08:20.270 | `[record] FluidAudio fed ~239s of audio to ASR` — **last log line of the process.** |
| 11:08:20 → 11:20:02 | **Frozen.** No log output at all: no `[detect] heartbeat` (every ~31s), no ASR feed line (every ~5s). Audio continues to disk. |
| 11:20:02 | Process dies. `mic.caf` holds 942.17s of audio — right up to death. |
| 11:20:05 | Fresh launch. Recovery offers the crashed session. |
| 11:20:07 | Resume → `mic.2.caf` created, offset 942s, 21 prior segments restored. |
| ~12:03:57 | Normal stop. `mic.full.caf` written (concatenation). |

Freeze began **4m00s** into the recording. The frozen process stayed alive, wedged, for
**11m45s** until it was killed.

Corroborating signal, independent of the log: the resume restored **21 prior segments**.
Twenty-one transcript segments is consistent with live ASR stopping at 4:00, not with it
running to 11:20:02 — 15m42s of speech would have produced far more. Two unrelated sources
agree the live transcript died at the freeze, not at process death.

### Aug 3 — session `2026-08-03-140506` — *not confirmed to be the same failure*

| Wall clock | Event |
|---|---|
| 14:05:07 | Recording starts. |
| 14:14:55.433 | `[record] FluidAudio fed ~588s of audio to ASR` — last log line. |
| ~14:15:33 | Process dies (*inferred*: 14:05:07 + 625.83s of `mic.caf`). |
| 14:15:34.9 | Fresh launch. |
| 14:15:38 | Resume → `mic.2.caf`, offset 625s, 10 prior segments. |
| ~14:37:43 | Normal stop. |

Treat this one as unconfirmed, for two reasons:

- **38s of silence is inside the noise floor.** `AppLog.log` enqueues asynchronously on a
  serial queue (`AppLog.swift:27`); on SIGKILL anything still queued is lost. So the last
  log line is a *lower bound* on death time, not the moment the freeze started. Aug 4's
  11m45s cannot be explained that way; Aug 3's 38s can.
- **The death→relaunch gap is implausibly short.** Inferred death 14:15:33 → new process
  logging voiceprints at 14:15:34.9 is 1.9s (Aug 4: ~3s). A user noticing a hang,
  force-quitting, and the replacement process reaching voiceprint load inside 2s doesn't
  happen — so either the death-time inference from audio duration is off (the archiver
  silence-pads outage gaps, `MicCapture.swift:20–21`, so frames written map to wall clock
  only loosely) or Aug 3 ended some other way.

**Confirmed freeze sample is therefore n=1.** Don't read timing patterns across the two.
What both share is only that the last line before the gap is a routine ASR feed line —
no distinctive preceding event in either.

## Why "blocked", not "spinning"

Three independent signals:

1. **All logging stops at once, from unrelated execution contexts.** The `[detect]`
   heartbeat is a main-thread `Timer`. The `FluidAudio fed ~Ns` line comes from a
   `Task.detached` mixer loop (`FluidAudioEngine.swift:444`). Both go silent in the same
   second. The mixer loop is not independent of the main actor — it does
   `await self?.applyStreamingTokenTimings(timings)` (`FluidAudioEngine.swift:455`) and
   `FluidAudioEngine` is `@MainActor` (`FluidAudioEngine.swift:30`). One blocked main
   actor stalls the detached loop at that await. This is why the live transcript dies
   with the UI.

2. **No CPU-pressure report covers either freeze window.** macOS files a
   `cpu_resource.diag` at 50% CPU sustained over 180s. An 11m45s main-thread spin would
   have tripped it several times over. Nothing was filed for 11:08–11:20 on Aug 4, or
   around 14:15 on Aug 3.

   > **Weakened by the Aug 6 occurrence.** During that freeze `ps` showed the process
   > burning a full core, and *still* no report was filed — because the CPU monitor fires
   > roughly once per process and PID 760 had already spent its report on Aug 5. So the
   > absence of a `.diag` is not evidence against a spin. See the Aug 6 section; signals
   > 1 and 3 stand unchanged.

3. **No crash report.** No `.ips` for Parley. Consistent with SIGKILL from a force quit,
   not a crash.

So the main thread was parked on something — a lock, a `.sync`, or an await that never
resumed — not burning cycles.

### Candidates, ranked

**1. `AXIsProcessTrusted()` called from a SwiftUI view body.** The only main-thread
synchronous system call reachable from a hot body path. Unproven as the cause, and a
wasteful call regardless.

`MainWindowView.swift:526` calls `PermissionManager.accessibilityAuthorized()`
(`PermissionManager.swift:97–99` → `AXIsProcessTrusted()`) inside `advisoryRows`
(`:501`), which is mounted unconditionally in the inspector rail (`:382`) — so it is live
during recording. Reachability confirmed rather than assumed: Swift short-circuits the
`if`, but `metadataDiscoveryEnabled` is on and `parley.axBannerDismissed` is **unset** in
`com.naufalmir.parley` (so `false`), meaning the third clause is evaluated every time.
With `trusted=true` (255 log lines) it always returns `true`, does no useful work, and
still makes the call — at minimum 5×/second for the whole meeting, given the re-render
rate below.

Weigh it honestly: `AXIsProcessTrusted()` is a local TCC trust lookup, not IPC into the
conferencing app, so an 11-minute park is a stretch. It is ranked first because it is the
only candidate of its kind that survives, not because the evidence points at it. Fix it
either way (cache the value; refresh on window activation).

**2. `MicCapture.stop()`'s cross-queue sync — real hazard, but not this.**
`rebuildQueue.sync { tearDownEngine() }` (`MicCapture.swift:131`) is called from the main
thread, and that same queue runs the 1s silence watchdog and the
`AVAudioEngineConfigurationChange` rebuild. A rebuild blocking inside `AVAudioEngine`
would park the caller indefinitely. Verified that the only callers are `stop()`
(`RecordingController.swift:961`) and `teardownForQuit()` (`:2036`) — there is no
mid-session path, and neither freeze was preceded by a stop. Fix as a latent hang risk.

**Eliminated: synchronous Accessibility IPC into the conferencing app.** This looked like
the best fit — an AX call into a wedged Webex/Teams helper parks the caller, and no
`AXUIElementSetMessagingTimeout` is set anywhere in the codebase. But the tree walk is
correctly off the main actor: `MeetingMetadataResolver` dispatches via
`axQueue.async` (`:104`) onto `nonisolated static` workers (`:152`, `:209`, `:214`), there
are no `.sync` hops anywhere in `Parley/Detection/`, and the results return via
`Task { @MainActor in … }` (`:106`) — an await, which yields rather than blocks. A hung AX
call would stall metadata discovery, not the main thread. Worth noting the missing
messaging timeout separately: a wedged target app leaks that utility queue permanently.

## Nothing was lost from the final notes

The concern about missing conversation does not hold for the delivered transcript:

- `mic.full.caf` = 3571.27s = 942.17 (segment 1) + 2629.10 (segment 2), **exactly**.
  `mixed.caf` = 3571.30s. No audio dropped at the seam.
- `session.json`: `offlineStatus: done`, `offlineAttempts: 1` — the offline pass ran once
  and completed over the full mix.
- `2026-08-04-1120 - Intellias -- DBX.md` carries continuous speaker turns from
  `[00:00:00]` to `[00:59:27]`, with every minute of the freeze window (recording minutes
  4:00–15:42) populated.

What *was* lost is the **live** transcript during the freeze — the on-screen stream the
user was watching stopped. The final note is rebuilt from audio by the offline re-pass, so
that loss never reached disk. The only true gap is the ~5s of wall-clock between process
death and resume, which is silence-padded and sample-aligned.

## Separate finding: a recurring main-thread CPU burn

Distinct from the freezes, and the app survives it — do not conflate the two.

`cpu_resource` reports for Parley on Jul 28, Jul 30 (×2), Jul 31, Aug 3 15:15, Aug 4 11:50.
Each is ~90s of CPU over ~175s (~52% of one core) on the **main thread**, with an
identical profile:

```
display cycle → NSView layoutSubtree (×6 nested) → NSAnimationContext runAnimationGroup
  → SwiftUI ViewGraph.updateOutputs → StaticBody.updateValue
    → ObservationCenter.invalidate → ObservationTracking cancel / _installTracking
      → ObservationRegistrar under _ManagedCriticalState.withCriticalRegion
```

That is view bodies re-evaluating at display rate, with the cost landing in Observation
tracking teardown/reinstall. The Aug 4 report fired while the user was idle and the app
was frontmost — so it is self-sustaining, not driven by interaction. Two supportable
drivers, both cheap to fix:

1. **`RecordingController.swift:886`** — `live.micSeemsSilent = …` is assigned
   unconditionally on every 200ms meter tick. `@Published` does not dedupe, so that is
   5 `objectWillChange` per second on `RecordingLiveState` for the whole meeting, and
   `RecordDetailView` observes it (`MainWindowView.swift:199`). Gate on inequality. Same
   for the unconditional assignments in `stopTimers()`.

2. **`LiveTranscriptView.swift:81`** — `scheduleScroll` fires on every change to
   `segments.last?.text`. With streaming ASR revising the tail every ~560ms and
   `Theme.Motion.gentle` running 0.2s, the animated `scrollTo` restarts before it
   settles, keeping the scroll view in near-continuous animated relayout. Coalesce it
   (throttle, or only animate on row insert, not on tail revision).

Not recommended on this evidence: reworking `ThemeStore` token reads
(`Theme.swift:115–196`) into the Environment. Every token read on a global `@Observable`
singleton does register a tracking per body evaluation, which is why Observation frames
dominate — but "the registrar is growing unboundedly" is over-read from ~10 microstackshot
samples (29 and 94 samples lost respectively), and the footprint evidence contradicts it
(Aug 3 grew +1.4MB, Aug 4 grew +33MB). Fix the two re-render drivers above first and
re-measure.

## Make the next one diagnosable

The freeze cannot be root-caused from what exists. One capture settles it.

**Next time the app goes unresponsive, before force-quitting:**

```sh
sample Parley 10 -file /tmp/parley-hang.txt     # 10s of stacks, all threads
# or, richer:
spindump Parley 10 -file /tmp/parley-spin.txt
```

Either shows exactly what the main thread is parked on. A `sample` of a blocked process
is the whole diagnosis.

**Worth adding to the app** (so it self-reports instead of relying on the user reacting in
time): a main-actor liveness watchdog. A `DispatchSourceTimer` on a background queue
compares a date stamped by the main actor each tick; when the stamp goes stale by >5s, it
spawns `/usr/bin/sample <own pid> 5 -file /tmp/parley-hang-<ts>.txt` and logs the path.
That converts the next freeze into an automatic capture. The `[detect]` heartbeat already
proves after the fact *that* a freeze happened; it can never say why.

Note that the log itself is not a reliable liveness signal — `AppLog` writes through an
async serial queue, so a SIGKILL discards whatever is queued. Any watchdog should write its
findings synchronously.

**To attempt a repro** without waiting for a real call: start a recording, leave it 15+
minutes, and watch `ps -o %cpu -p $(pgrep Parley)`. Flat CPU that stops logging reproduces
the freeze; climbing CPU reproduces the separate render-loop issue.

## What was applied

All four landed together; full suite green (426 tests).

**`MainActorWatchdog`** (`Parley/App/MainActorWatchdog.swift`, new) — the diagnostic above,
automated. Runs only while recording: started in `launchCapture`, the shared path for both
a fresh start and a resume, and stopped in `stop()` only *after* `micCapture?.stop()` /
`systemCapture?.stop()` have returned — that teardown contains the `rebuildQueue.sync`
of candidate #2, so disarming before it would leave the one named suspect uncovered.
A 1s timer on a utility queue
pings the main queue and measures the round-trip; past 5s it runs
`/usr/bin/sample <pid> 5` and writes both the finding and the capture path to
`~/Library/Logs/Parley/freeze.log`, then reports the total stall on recovery. Captures are
rate-limited to one per 120s so a long freeze writes a couple of samples, not hundreds.

Two things worth knowing about it:

- The durable write is a **synchronous** `FileHandle` append, deliberately not `AppLog` —
  `AppLog` enqueues on a serial queue and a SIGKILL discards the backlog, which is how
  every one of these sessions ended.
- `sample` runs synchronously on the watchdog's own queue, so no tick (including the one
  that reports recovery) lands until it returns. Harmless in production; it's why the
  tests poll rather than sleep.
- **Reading `freeze.log`:** a `stalled` line with no following `stack capture written` line
  means `sample` itself didn't come back — which happens if the main thread is blocked
  inside a syscall holding a task-level lock. That *is* diagnostic information, not a bug
  in the watchdog: `waitUntilExit()` has no timeout, so the watchdog queue simply parks
  (silently, and without affecting the app) until the process ends.

`MainActorWatchdogTests` covers the real mechanism rather than a stubbed clock: XCTest runs
on the main thread, so the tests wedge the main queue with `Thread.sleep` and assert the
watchdog notices from its background queue, that the capture contains real stacks, that a
healthy main queue is never reported, and that the cooldown holds a 3s block to one capture.

**The two re-render drivers**, as described above:
`RecordingController.evaluateMicSilence` now assigns `micSeemsSilent` only on change (and
`stopTimers` likewise), killing 5 `objectWillChange`/sec on `RecordingLiveState`; and
`LiveTranscriptView.scheduleScroll` now animates only on row insert, with tail revisions
jumping instead and throttled to 0.5s.

**`AXIsProcessTrusted()` out of the body path** — `RecordDetailView` caches AX trust in
`@State` (mirroring what `SettingsView` already did) and refreshes it on appear and on
`NSApplication.didBecomeActiveNotification`, the only moment it can go stale. This removes
a synchronous system call that ran on the main thread on every body evaluation of the
always-mounted inspector rail. It is also candidate #1 for the freeze, so if the block
recurs with this in place, that candidate is eliminated and the watchdog's capture will say
what the real one is.

---

# Aug 6 2026 — third occurrence

**The mitigations above were never built.** `/Applications/Parley.app/Contents/MacOS/Parley`
was dated **Jul 30 16:48**; every file in *What was applied* was written **Aug 4 16:12–16:17**
and is still uncommitted. So this freeze ran on code with none of the four fixes and, most
costly, without `MainActorWatchdog` — the instrument built specifically to capture it.

That is the certain answer to "what went wrong." The technical root cause remains
unidentified, for the third time, because nothing was armed to record it.

## Timeline — session `2026-08-06-133337` ("AI Network Blast Radius")

Man Group / Agentic Identity. Manual start (`startedByDetection: false`), attendees
Nate Tombs + Naufal Mir.

| Wall clock | Event |
|---|---|
| 13:33:37 | Recording starts. `mic.caf` + `system.caf` created. |
| 13:36:37.206 | `[record] FluidAudio fed ~179s of audio to ASR` — last ASR line. |
| 13:36:37.586 | `[detect] heartbeat` — last heartbeat. **Freeze, 3m00s in.** |
| 13:36:37 | `session.json` `lastHeartbeat` stops at `12:36:37Z`. |
| 14:01:19 | `mic watchdog: no buffer for 3.3s — triggering rebuild` → recovered, padded 3.30s. |
| 14:02:53 | `no buffer for 94.2s` → recovered, padded 94.21s. |
| 14:02:57 | `no buffer for 3.9s` → recovered, padded 3.93s. |
| ~14:40 | `ps`: PID 760, **100.0% CPU**, 270:16 cumulative CPU time. |
| 14:44:11 | Audio stops (`mic.caf` = 4234.51s from 13:33:37). Process dies. |
| 14:44:50 | `sample 760` — *"no longer appears to be running."* Capture missed by seconds. |

Frozen and alive for **67m34s**. Three independent sources — the ASR feed line, the
`[detect]` heartbeat, and the manifest's `lastHeartbeat` — stop inside the same second,
which is the Aug 4 signature exactly.

Two earlier sessions the same day (`09:31`, `11:32`) recorded and finalised normally in
this same process instance, including a full offline re-pass and summary. The freeze is not
simply "process has been up too long", though this instance had ~30.7h of uptime.

## What is new, and what it does not prove

**A core was burning during the freeze.** `ps` reported 100.0% CPU. This is genuinely new —
Aug 4 had no live observation at all. But `ps` %CPU is a **process-level** figure: on a
12-core machine it means *one thread* was spinning and cannot say which. A parked main
thread alongside one spinning background thread reads identically. It does **not** overturn
the "blocked, not spinning" verdict; it adds a fact that verdict was reached without.

**The off-main machinery was alive 25 minutes in.** The 14:01–14:02 mic-watchdog lines
prove `MicCapture`'s `rebuildQueue` and `AppLog`'s serial queue were both running and
draining. Both are off-main, so this is *consistent with* a main-thread park rather than
evidence against one. The 94.2s mic outage is itself notable: the audio engine went
unserviced for a minute and a half, which points to real scheduling starvation.

**No automatic capture exists for this occurrence.** Verified, not assumed:

- No `.ips`, `.hang`, `.spin`, or `.diag` for Parley dated Aug 6 in either
  `/Library/Logs/DiagnosticReports` or `~/Library/Logs/DiagnosticReports`. The most recent
  is `Parley_2026-08-05-132847_hijarna.cpu_resource.diag`.
- No `~/Library/Logs/Parley/freeze.log`, because the watchdog was not in the build.
- No `hangtracer`, `spindump`, or `ReportCrash` entry for Parley anywhere in the window.
  macOS never flagged the app unresponsive — plausibly because it lost focus 45s in (see
  below), and hang reporting concentrates on the frontmost app.

> **Tooling trap, worth remembering.** In `zsh`, `log` is a **shell builtin**, so
> `log show …` silently returns nothing. Every such query has to be run as
> `/usr/bin/log show …`. A first pass here concluded "the log store is empty for that
> window"; run properly, the same window holds 349,080 rows. Nothing below would have been
> found otherwise.

## What the unified log adds

Run via `/usr/bin/log show --predicate 'process == "Parley"'` over 13:34–14:50. Thread
`0x1ca6` is the main thread — it is what emits the `[detect]` heartbeat.

| Time | Entry |
|---|---|
| 13:36:37.599 | Last app-level entry (heartbeat, main thread `0x1ca6`). |
| **13:41:42.018** | `CoreAudio` **Error**: `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload` |
| 13:37:22.660 | `runningboardd` invalidates Parley's WindowServer assertion; role → `UserInteractiveNonFocal`. |
| 14:01:13–14:01:16 | `RunningBoardServices didChangeInheritances`, then CoreAudio `PauseIO`/`ResumeIO`. |
| 14:01:19.529 | Mic watchdog fires (first of three). |
| 14:03:01 | Post-rebuild churn: repeated `CoreAudio throwing -10877`, TCC access requests. |
| 14:06 → 14:39 | Nothing but `RunningBoardServices` activities. The app never recovers. |
| 14:44:12–13 | `xpc_connection_cancel()`, then `CoreAnalytics: Entering exit handler`. Process exits. |

Three things follow.

**The audio stack was being starved of CPU, 5 minutes into the freeze.** `IOWorkLoop:
skipping cycle due to overload` at 13:41:42 is Core Audio reporting it missed its real-time
deadline. That is what CPU starvation looks like from inside the audio stack, and it is the
strongest evidence yet that something was *burning* the machine rather than quietly parked.
It also explains the 94.2s mic outage 20 minutes later as a consequence, not a cause.

**No app-level logging after 13:36:37.599 — but off-main system frameworks kept emitting.**
`AppLog` output stops dead while CoreAudio, RunningBoardServices and XPC keep logging from
other threads. The wedge is specific to the app's own main-actor work, not process-wide.

**The exit was a self-attributed `SIGTERM`, not a `SIGKILL`.** `launchd` records it exactly:

```
14:44:13.229  launchd: [gui/502/application.com.naufalmir.parley…[760]:]
              exited due to SIGTERM | sent by Parley[760], ran for 53669238ms
```

The user confirms this was a Force Quit. A Dock / Force-Quit-panel `SIGKILL` would be logged
as `SIGKILL` attributed to the killer and would skip `atexit` — neither matches. What the
trace shows is a RunningBoard-mediated termination delivered **in-process** (`runningboardd`
had been managing Parley's assertions throughout) which then ran the normal shutdown path:
XPC cancel at 14:44:12.017 → `CoreAnalytics: Entering exit handler` at 14:44:13.102 →
`launchd` logging the exit at 14:44:13.229.

The app has **no** self-termination code: every `terminate()` under `Parley/` targets a
spawned child `Process` (the `claude` CLI and friends), never `getpid()`. So the signal is
the force quit being delivered, not the app killing itself.

`ran for 53669238ms` is 14.9h against ~30.1h of wall clock since the 08:36 launch — the gap
is overnight sleep, which the monotonic clock excludes. Consistent, not a contradiction.

> **Correction — an earlier reading of this evidence was wrong.** A first pass argued the
> exit path discriminated deadlock from starvation: `atexit` running implied `exit()`,
> implying `[NSApp terminate:]` on a live main thread. That does not hold. The exit handler
> ran on thread `0x14086f`, **not** the main thread `0x1ca6`, and a signal-triggered shutdown
> needs no main-thread participation whatsoever. **The exit path says nothing about
> main-thread liveness** — do not use it as a discriminator.

The starvation case therefore rests entirely on the **Core Audio real-time overload at
13:41:42** plus the same-instance `cpu_resource.diag` stack — not on how the process died.

## The two findings may be one bug — promoted to leading candidate

The doc above says of the render-loop CPU burn: *"Distinct from the freezes… do not
conflate the two."* This occurrence is the first evidence for conflating them.

`Parley_2026-08-05-132847_hijarna.cpu_resource.diag` is **PID 760** — the same process
instance that froze on Aug 6. It records `Num threads: 1`, single-threaded, main thread,
in:

```
NSView layoutSubtree (×6 nested) → NSAnimationContext runAnimationGroup
  → ViewGraph.updateOutputs → StaticBody.updateValue
    → ObservationCenter.invalidate → ObservationTracking.cancel
      → ObservationRegistrar under _ManagedCriticalState.withCriticalRegion
```

Same-instance is confirmed, not inferred from the PID: `parley.log` has one
`[app] Launch warmup` line at **2026-08-05 08:36:11** and no further launch line before the
freeze, so PID 760 ran continuously for ~30h across both the Aug 5 report and the Aug 6
freeze.

A render/Observation feedback loop that stops converging produces precisely the observed
triple: one core pegged, every main-actor timer starved, UI unresponsive — and now also the
Core Audio real-time overload at 13:41:42, which wants a CPU hog to explain it.

Do **not** read the 270 minutes of cumulative CPU as corroboration. Ten sessions across
Aug 5–6 each ran live ASR plus an offline re-pass — one of which is logged at 243.8s of
diarization alone — and the freeze itself contributed 67 minutes at a full core. Those
plausibly account for the whole figure with nothing left over to attribute to a chronic
render loop. The same-instance `cpu_resource.diag` stack carries this argument on its own.

Stated honestly: this is a **candidate promoted by today's data**, not a settled cause. The
two re-render drivers already fixed in the working tree (the unconditional
`micSeemsSilent` assignment at 5/sec, and `scheduleScroll` restarting an animation every
~560ms) are exactly the kind of input that could tip a converging render loop into a
non-converging one. If the freeze survives those two fixes, this candidate weakens sharply.

## Nothing was lost from the audio

Both tracks recorded through the entire freeze, to the moment of death:

- `system.caf` = **4132.95s** (68m53s) — real captured audio.
- `mic.caf` = **4234.51s**, of which **101.44s** is silence padding (3.30 + 94.21 + 3.93
  from the three watchdog rebuilds). The 101.56s excess over `system.caf` matches that
  padding to 0.12s, so the accounting closes.
- 13:33:37 + 4234.51s = **14:44:11**, matching the file mtime.

What was lost is the **live** transcript: `segments.jsonl` holds 31 segments and
`transcript.partial.md` ends at `[00:02:58]` — three minutes of a ~69-minute meeting.

### Recovering it — the exact sequence

`session.json` still reads `status: active`, and `SessionStore.crashedSessions()` filters on
nothing but `status == .active` — no age or staleness cutoff — so this session **will** appear
in `RecoveryView` on next launch, however long it sits. It also has no `callBundleID`
(`startedByDetection: false`), so `matchingLiveRecovery`'s auto-resume cannot pick it up and
splice it into an unrelated call.

The sheet offers four actions, and **only one of them is right here**. Unlike Aug 4 — where
the meeting was still in progress and *Resume* was correct — this meeting is over, so the
path is **Recover**, not Resume:

| Action | What it does | Use here? |
|---|---|---|
| **Resume** | Continues recording into the same note (`resume(_:)`). | **No** — the call has ended. |
| **Recover ▸ Re-transcribe full audio (complete)** | `recover(_:reTranscribe: true)` → `reTranscribeSession` runs the model over every track, writes the note, then enqueues the normal offline pass (diarization + attributed rewrite). | **Yes — this one.** |
| **Recover ▸ Recover from saved text (instant)** | Reads `segments.jsonl` only — the 31 segments. | **No** — yields the 3 minutes, discards the other 66. |
| **Discard** | `FileManager.removeItem(at: session.dir)` — **deletes the directory and both CAFs.** | **Never.** |

> **Footgun.** *Discard* destroys 69 minutes of irreplaceable audio immediately. In
> `RecoveryView` it sits in the same button row as *Recover*, styled `role: .destructive`
> but with **no confirmation alert**. Worth adding one — this is the first session where a
> misclick would have cost real conversation.

`recover` is gated on `live.state == .idle`, so handle the recovery **before** starting any
new recording. *Later* is safe: the session stays pending.

As on Aug 4, once the re-transcribe completes the loss never reaches the final note.

## Next time — order matters

`sample` was attempted **second**, after reading logs, and the process died in between. The
capture is the whole diagnosis; take it first.

```sh
sample Parley 10 -file /tmp/parley-hang.txt      # do this BEFORE anything else
spindump Parley 10 -file /tmp/parley-spin.txt    # richer, needs sudo
```

Once a build carrying `MainActorWatchdog` is installed this becomes automatic and the
race disappears.

---

# Aug 7 2026 — fourth occurrence: **root cause identified**

The watchdog worked. First freeze with instrumentation armed, and it produced the capture
that three previous occurrences could not.

```
10:03:47.169  main actor stalled 5.0s   — sampling stacks to freeze-2026-08-07-100347.txt
10:03:58.869  stack capture written
10:05:48.168  main actor stalled 126.0s — sampling stacks to freeze-2026-08-07-100548.txt
10:07:48.169  main actor stalled 246.0s — sampling stacks to freeze-2026-08-07-100748.txt
```

Session `2026-08-07-100011`, a live Teams call. Recording started 10:00:11; last ASR feed
10:03:37.763; last `[detect]` heartbeat 10:03:39.158. **Freeze began ~3m30s in** — matching
Aug 4 (4m00s) and Aug 6 (3m00s).

## The main thread is not blocked. It is computing.

From the sample (7119/7119 samples on `com.apple.main-thread`), the stack is one
self-similar layout cascade, rooted at the window's `RootGeometry`:

```
RootGeometry.value.getter
  → _FlexFrameLayout.sizeThatFits(in:context:child:)
    → LayoutProxy.size(in:) → ViewLayoutEngine.sizeThatFits(_:)
      → StackLayout.UnmanagedImplementation.placeChildren(in:)
        → …sizeChildrenGenerallyWithConcreteMajorProposal(in:minorProposalForChild:)
          → StackLayout.UnmanagedImplementation.prioritize(_:proposedSize:)
            → LayoutEngineBox.lengthThatFits(_:in:)
              → _FlexFrameLayout.sizeThatFits(…)          ← cycle repeats
```

Measured on the deepest root-to-leaf path: **232 frames, 9 nested `StackLayout` levels.**
Sample counts halve at each level — 6189 → 3115 → 1026 → 626 → … — which is the signature of
**combinatorial re-querying**, not a loop that fails to terminate.

Each stack level asks each child for its size several times per pass (`prioritize`,
`sizeChildrenGenerally`, `resize`, and again during `placement`). Nine nested levels of
stacks wrapped in flexible frames (`.frame(maxWidth:.infinity)` and friends) multiplies those
queries out to a layout pass that cannot complete in any useful time. One pass never returns;
the main actor never reaches the next runloop turn; every main-actor timer starves.

This settles three open questions from the earlier sections:

1. **"Blocked, not spinning" was wrong** — for this occurrence, definitively. The main thread
   holds no lock and awaits nothing. It is burning a core inside SwiftUI layout. The
   Aug-3/Aug-4 candidate list (`AXIsProcessTrusted`, `rebuildQueue.sync`) is not what this is.
2. **The "two findings are one bug" hypothesis is confirmed.** The Aug-5 `cpu_resource.diag`
   render-loop stack and the freeze are the same pathology at different intensities —
   `ObservationCenter.invalidate` there, `StackLayout`/`_FlexFrameLayout` here, both under
   `ViewGraph.updateOutputs` on the main thread.
3. **The Aug-6 Core Audio overload at 13:41:42 is explained.** A main thread pinned at 100%
   starves the audio stack's real-time deadline. Effect, not cause.

## What the capture does *not* say

No Parley symbol appears anywhere in the layout stack — SwiftUI specializes and inlines view
bodies, so the view *types* do not survive into the frames. The only Parley frames in the
whole sample are healthy audio threads (`SystemAudioCapture`, `AudioArchiver`,
`AudioResampler`, `MicCapture`).

So the mechanism is identified but **the specific view is not**. `LiveTranscriptView` is
structurally implicated by timing (it grows during recording, and the freeze lands 3–4
minutes in every time) but its own tree is shallow — a `LazyVStack` of `HStack` rows — so the
9 nested levels come from the surrounding chrome it is embedded in, not from the row list.

## Next step: find the nesting, not more stacks

Further samples will keep showing the same cascade. What is needed now is the view tree:

- Audit the ancestry from the window root down to `LiveTranscriptView` in `MainWindowView`
  (the inspector rail / split layout) and count actual nested `VStack`/`HStack` levels that
  carry a flexible `.frame`. Nine is the number to find.
- The cheap structural fixes are the usual ones: collapse redundant nesting, replace
  `.frame(maxWidth: .infinity)` chains with a single one at the outermost level, give the
  transcript rows a fixed or explicitly-proposed width so `Text` sizing stops being
  re-negotiated, and consider `.fixedSize(horizontal:false, vertical:true)` at the row level
  to cut the re-query loop.
- `Spacer(minLength: 0)` inside every `TranscriptRow` combined with an outer
  `.frame(maxWidth: .infinity, alignment: .leading)` is exactly the ambiguous-flexibility
  pattern that defeats SwiftUI's sizing cache. Worth testing first.

Recording is unaffected while wedged: `mic.caf` and `system.caf` both kept growing through
this freeze, as in every prior occurrence.

## Recovering a freeze that happens *mid-call*

Different from Aug 6, where the meeting had ended and *Recover* was correct. With the call
still live: force quit, relaunch, and use **Resume** — `isCallLive(_:)` matches the session's
`callBundleID` against the running conferencing app and tints the button green. Resume
continues into the same note with a new `mic.2.caf` at the correct offset, so the meeting
carries on with only the force-quit gap (silence-padded) missing.

## Aug 10 2026 — the watchdog caught one; freeze class identified

The watchdog did its job. Freeze on 2026-08-10, recording started 15:33:26, main actor wedged
from ~15:38 (≈4m36s in) and still wedged 845s later when sampled; `%CPU 100.1`, `STAT R`.

**This is a spin, not the Aug-4 block.** CPU pinned, and the ASR mixer loop kept running
throughout (`FluidAudio fed ~1125s` at 15:52). Distinct from Aug 4, where the mixer stopped
too. The captured stack names it: a combinatorial SwiftUI layout pass —
`RootGeometry.value.getter → LayoutEngineBox.sizeThatFits`, then `_FlexFrameLayout ↔
StackLayout.placeChildren` recursing 468 frames deep, 2840 `placeChildren` nodes in one pass.
See `LAYOUT_EXPLOSION_AUDIT.md` for the view ancestry and `Where the time actually goes` for
the self-time profile.

That leaves the Aug-4 block still unexplained and now clearly a *different* failure — the
`AXIsProcessTrusted()` candidate has since been fixed, and the mixer-stall signature has not
recurred.

**Nothing was lost.** Audio ran to the moment of the force quit: `mic.caf` = 1387.008s,
`mixed.caf` = 1387.008s, `system.caf` = 1386.923s against a 1387s wall clock (15:33:26 →
15:56:33). Journal recovery restored 18 segments, the offline pass completed
(`offlineStatus: done`, `offlineAttempts: 1`), and the note covers `[00:00:00]`–`[00:22:51]`
continuously. As before, the loss is confined to the *live* on-screen stream —
`transcript.partial.md` and `segments.jsonl` both stop at 15:37, one minute before the freeze.

### Watchdog fix — capture volume was unbounded

The Aug-7 freeze ran ~98 minutes and wrote **~50 captures at ~22 MB each**; the log directory
reached **1.3 GB across 62 files**. The 120s cooldown bounds capture *rate* but nothing bounded
the total, and a wedged main thread does not change its mind — the first few samples say
everything.

Now bounded two ways: `maxCapturesPerFreeze = 3` (announced once in `freeze.log`, then silent)
and `retainedCaptures = 8`, pruned newest-N after each write. Both limits are covered by
deterministic tests — `captureDecision` is a pure function and `pruneCaptures` runs against
fixture files, because driving them end-to-end depended on `sample`'s symbolization time
(seconds of variance) and was flaky. Existing captures self-prune on the next freeze; to
reclaim the space immediately:

```sh
ls -t ~/Library/Logs/Parley/freeze-*.txt | tail -n +9 | tr '\n' '\0' | xargs -0 rm
```
