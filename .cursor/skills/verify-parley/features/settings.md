# Settings

Settings is a separate window with a sidebar of seven sections. The user opens it from the main-window sidebar or the menu-bar extra, then inspects General (vault path, theme, capture default) and the other panes without having to record.

## Sub-features

- `settings-open` opens the Settings window from the main-window **Settings** control.
- `settings-general` shows **Obsidian vault**, theme, and default capture.
- `settings-sections` can switch **Transcription**, **Notes**, **Summary**, **Detection**, **Storage**, and **Vault**.
- `settings-vault-path` exposes the vault path string used to gate recording verification.

## How to get to it (user POV)

- Choose **Settings** at the bottom of the main-window sidebar.
- Choose **Settings** in the menu-bar extra footer.
- Choose a section in the Settings sidebar.

## Driving it with control-parley

Preconditions:

- `control-parley doctor` reports `recording: idle`.
- Do not edit the vault path, Clear logs, Delete sessions, download/delete models, or Import/Export knowledge. Those mutate the user's machine.

- **Ensure sidebar handles.** If a snapshot lacks `help="Settings"`, run `control-parley click --name "Split View Horizontally Left"` to collapse the sidebar.
- **Open Settings.** Choose **Settings**. Run `control-parley click --name "Settings" --role AXButton`. A Settings window appears with sidebar titles **General**, **Transcription**, **Notes**, **Summary**, **Detection**, **Storage**, **Vault**.
- **General.** If General is not selected, click **General**. Run `control-parley wait --contains "Obsidian vault" --timeout 8`. The **Obsidian vault** field shows the current path (placeholder `path to your vault` if empty).
- **Read vault path.** Snapshot Settings. Run `control-parley snapshot --path artifacts/settings/general.ax.txt`. Copy the vault path value from the snapshot. If it does not contain `parley-verify`, recording features stay skipped.
- **Other sections (spot-check).** Click **Transcription** and wait for transcription copy (engine / model language). Click **Storage** only to confirm the section title; do not delete recordings.
- **Close.** Close the Settings window (window close button) so the next recipe starts on the main window. Do not Quit Parley.
- **Proof.** Screenshot General: `control-parley screenshot --path artifacts/settings/general.png`. The image shows the Settings window and **Obsidian vault**.

## Gotchas

- Two **Settings** hits can exist (sidebar vs menu-bar extra). Drive the main window's sidebar while that window is focused.
- Settings is a second AX window. Snapshots dump every Parley window; prefer the one whose tree contains **Obsidian vault**.
- Changing Theme is immediate and persisted. Do not switch themes to "prove" General unless you switch back in the same run.
- **Detection** may prompt to open System Settings for Accessibility. Cancel OS dialogs; they are not Parley UI.
- Storage **Delete** moves audio to Trash. Never use it on the user's sessions.
