---
name: verify-parley
description: Drive the Parley macOS menu-bar transcriber through Accessibility and prove user-facing behavior. Use when verifying UI, recording transport, History, People, or Settings against a running /Applications/Parley.app.
---

# Verify Parley

Parley is a native macOS menu-bar + main-window app (`com.naufalmir.parley`). A user records mic + system audio, reviews transcripts in History, manages people, and configures the app in Settings. There is **no disposable data directory and no second instance**: Application Support, UserDefaults, Keychain, and the Obsidian vault are shared with whatever copy is already running.

This skill is for agents. Drive only an instance this run launched, or an already-running copy that `doctor` proves is **idle**. Never click **Start** against the user's real vault.

Harness: `control-parley`, a System Events / JXA driver. Cursor can already automate System Events; a separately compiled AX binary does not inherit that trust. Repo-relative invocations below assume cwd is the Parley checkout.

```bash
CONTROL=".cursor/skills/verify-parley/bin/control-parley"
ARTIFACTS=".cursor/skills/verify-parley/artifacts"
export PARLEY_VERIFY_STATE="${PARLEY_VERIFY_STATE:-/tmp/parley-verify-state}"
```

Read `features/README.md` and the matching feature file before driving. A proof that uses one convenient entry point is incomplete when the map lists others.

## Launch

Prefer the installed Release app. Do **not** run `tools/localrelease.sh` as part of verification: it quits a running Parley and replaces `/Applications/Parley.app`.

Ready when `control-parley doctor` prints `recording: idle` (or `unknown` only after you have inspected a snapshot and confirmed there is a **Start** button, not **Stop**).

```bash
"$CONTROL" launch
"$CONTROL" activate
"$CONTROL" doctor
```

- If `/Applications/Parley.app` is missing, stop and tell the user to install once with `tools/localrelease.sh` (not while they are recording).
- Launch writes `PARLEY_VERIFY_STATE`. `LAUNCHED_BY_US=1` means this run started the process; `0` means it attached to an existing one.
- Ready signal: an AX window exists. On Record, expect **System-wide** / **Title** / **No transcript yet**. The **Start** button is often missing from AX.
- If launch reports no AX windows, the main window is closed. Activate again, or the user must choose **Open Parley Window** from the menu-bar extra. Do not click the menu-bar **Start**.

Teardown is **Cleanup**, not a process-name kill.

## Doctor

Run this first whenever anything looks off. It is read-only aside from enabling AX on the target.

```bash
"$CONTROL" doctor
```

Require:

- `bundle: com.naufalmir.parley`
- a live pid whose path is `/Applications/Parley.app` (or say so if it is a different build)
- `ax: system-events`
- `recording: idle` — **exit 4 means a live recording; abort the run**
- at least one AX window after `activate`

If System Events cannot see Parley windows, grant **Automation** (Cursor → System Events) and, if prompted, Accessibility for Cursor under System Settings → Privacy & Security. A first click may show an Automation dialog; accept it, then retry.

## Drive

All clicks go through `control-parley`. Prefer AX **title**, **description**, and **placeholder** over coordinates.

```bash
"$CONTROL" click --name "History" --role AXButton
"$CONTROL" wait --contains "Needs you" --timeout 8
"$CONTROL" snapshot --path "$ARTIFACTS/history.ax.txt"
"$CONTROL" screenshot --path "$ARTIFACTS/history.png"
```

Stable handles from this app (SwiftUI via System Events). Matching uses name, title, description, **help**, and value (contains):

| Surface | Handle | Notes |
|---|---|---|
| Sidebar (collapsed) | help `Record`, `History`, `People`, `Settings` | Icon rail. Prefer this; expanded labels often have empty AX names. |
| Sidebar toggle | description `Split View Horizontally Left` | Toolbar. Click once if History/Record are missing from a snapshot. |
| Other audio | description `System-wide`, `Specific app` | `AXRadioButton` |
| Record chrome | values `Title`, `Filing`, `Attendees`, `No transcript yet` | The **Start** glass button is often **absent** from the AX tree. Do not invent a coordinate click. |
| History search | unlabeled `AXTextField` above the filter radios; search-in-contents toggle help `Also search inside transcript text (slower)` | Placeholder `Search meetings` is not exposed. |
| History filters | `All`, `Processing`, `Needs you`, `Done` | `Needs you` may include a count. |
| People search | `Search people` | After People is selected |
| Settings sections | `General`, `Transcription`, `Notes`, `Summary`, `Detection`, `Storage`, `Vault` | Settings window |
| Menu-bar extra | `Start` / `Stop`, `Open Parley Window`, `Quit` | only if the extra is open |

Do not type into fields with `cliclick` coordinates. Do not call `RecordingController` or write UserDefaults from the agent; those are not the user path.

**Start recording** is forbidden unless `doctor` is idle **and** Settings → General shows an Obsidian vault path under a verification-only folder (name contains `parley-verify`). There is no env-var override. If that path is the user's real vault, skip recording features and report the unmet precondition.

## Evidence

Store proof under `.cursor/skills/verify-parley/artifacts/` (survives cleanup). Use a subdirectory per feature (`artifacts/history/`, …).

Proof standards:

- Exercise the real UI path (sidebar, buttons, Settings window), not test targets or internal setters.
- Capture **action + result**: AX snapshot before/after a click, plus a screenshot of the Parley window when Screen Recording is granted to Cursor. If `screencapture` prints `could not create image from rect`, grant Screen Recording and retry; keep the AX snapshot as the textual proof.
- Side effects: a recording would create `~/Library/Application Support/Parley/Recordings/<session>/mic.caf` and `system.caf` and a vault markdown under `<vault>/Parley/Unprocessed/`. Do not assert those unless you actually started a recording under a verification vault.
- Mocks are not used. External CLIs (`claude`, `cursor agent`, `grok`) stay untouched unless the feature file is Notes/Summary generation.

Each artifact set must name the feature ID and entry point.

## Cleanup

```bash
"$CONTROL" quit --only-if-launched "$PARLEY_VERIFY_STATE"
```

Kill only the pid this run started (`LAUNCHED_BY_US=1`). If the run attached to an already-running Parley, leave it running and restore any UI you changed (sidebar back to Record, History filter back to its prior tab, Settings closed). Never `killall Parley`. Never delete Application Support, the vault, or artifacts.

## Helpers

```bash
.cursor/skills/verify-parley/bin/control-parley doctor
.cursor/skills/verify-parley/bin/control-parley launch
.cursor/skills/verify-parley/bin/control-parley activate
.cursor/skills/verify-parley/bin/control-parley snapshot [--path FILE]
.cursor/skills/verify-parley/bin/control-parley click --name NAME [--role ROLE]
.cursor/skills/verify-parley/bin/control-parley wait --contains TEXT [--timeout SECONDS]
.cursor/skills/verify-parley/bin/control-parley screenshot --path FILE
.cursor/skills/verify-parley/bin/control-parley quit --only-if-launched STATEFILE
.cursor/skills/verify-parley/bin/control-parley pid
```

`bin/control-parley` is a bash wrapper; `bin/control-parley.jxa.js` is the System Events walker. No compile step. Snapshots skip `AXList` / `AXScrollArea` so History's row list cannot hang the dump.
