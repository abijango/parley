# Record tab

The Record tab is the live capture surface: start and stop a meeting, choose how far-side audio is captured, and set a title before or during the call.

## Sub-features

- `record-open` shows the Record tab from the main-window sidebar.
- `record-idle` shows **Start** and a Ready status when nothing is capturing.
- `record-capture-mode` exposes **System-wide** and **Specific app** while idle.
- `record-title` shows the **Meeting title** field.
- `record-start` starts capture (gated; see preconditions).

## How to get to it (user POV)

- Open the Parley main window (Dock, or menu-bar extra **Open Parley Window**) and choose **Record** in the sidebar.
- Choose **Start** / **Stop** on the Record tab.
- Choose **Start** / **Stop** in the menu-bar extra (same transport; do not use it while verifying the window).

## Driving it with control-parley

Preconditions:

- `control-parley doctor` reports `recording: idle`.
- The main window is frontmost.
- For `record-start` only: Settings → General **Obsidian vault** path contains `parley-verify`. If it does not, skip `record-start` and report the unmet precondition. Never start a recording into the user's vault.

- **Open Record.** Choose **Record**. Run `control-parley click --name "Record" --role AXButton`. The detail pane shows **Start** and **Ready to record** or status **Ready**.
- **Confirm idle chrome.** Snapshot the tree. Run `control-parley snapshot --path artifacts/record-tab/idle.ax.txt`. Expect `System-wide` / `Specific app`, `Title`, and usually `No transcript yet`. The **Start** glass button is often missing from the AX tree; do not click by coordinates. Treat `session.json` with `"status": "active"` under Application Support Recordings as recording, even if Stop is not in the tree.
- **Capture mode.** The segmented control includes **System-wide** and **Specific app**. Run `control-parley wait --contains "System-wide"`. Choosing **Specific app** reveals an **App** picker; restore **System-wide** before leaving.
- **Title field.** The Record inspector includes a text field whose placeholder is `Meeting title`. Run `control-parley wait --contains "Meeting title"`.
- **Start (gated).** Only if the vault path contains `parley-verify`: Run `control-parley click --name "Start" --role AXButton`. Wait until the snapshot contains `title="Stop"` or `Recording`. Then Stop. Proof includes new files under `~/Library/Application Support/Parley/Recordings/` for this run **and** a markdown file under `<vault>/Parley/Unprocessed/` if stop completed. If the vault gate fails, do not click Start.
- **Proof.** Run `control-parley screenshot --path artifacts/record-tab/idle.png` on the idle Record tab. The screenshot shows Parley, **Start**, and the capture-mode control.

## Gotchas

- **Start** in the menu-bar extra is the same recording as the window. Clicking it while attached to the user's instance writes into their vault and Application Support.
- While `Preparing…` or `Stopping…` the transport is disabled. Wait for **Start** or **Stop**, not a fixed sleep.
- A first recording may prompt for Microphone and Audio Recording (system audio). That dialog is OS-owned; do not click through it as proof of Parley.
- Crash-recovery or assign-speakers sheets can cover the Record tab on launch. Dismiss only if the sheet was created by this run; otherwise abort.
- Capture mode is disabled while recording. Change it only when idle.
