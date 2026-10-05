# People

People is the directory of known contacts and voiceprints: search by name/company/title, inspect a person, and (separately) export or import voiceprints.

## Sub-features

- `people-open` shows the People split view from the sidebar.
- `people-search` filters from **Search people**.
- `people-select` shows a person's detail when a row is chosen.
- `people-empty` still shows the search field when the directory is empty.

## How to get to it (user POV)

- Choose **People** in the main-window sidebar.
- Type in **Search people**.
- Choose a person in the list.

## Driving it with control-parley

Preconditions:

- `control-parley doctor` reports `recording: idle`.
- The main window is frontmost.
- Do not Delete people, enroll voiceprints, or run Export/Import JSON. Those mutate biometric and Rolodex data.

- **Ensure sidebar handles.** If a snapshot lacks `help="People"`, run `control-parley click --name "Split View Horizontally Left"` to collapse the sidebar.
- **Open People.** Choose **People**. Run `control-parley click --name "People" --role AXButton`. A field with placeholder `Search people` appears.
- **Wait for chrome.** Run `control-parley wait --contains "Search people" --timeout 8`.
- **List or empty.** Snapshot the tree. A populated directory shows person names as rows; an empty one still has **Search people**.
- **Select (optional).** If a person name is in the snapshot, click that name. Detail appears in the trailing pane. Do not click **Delete**.
- **Restore.** Click **Record**.
- **Proof.** Run `control-parley snapshot --path artifacts/people/list.ax.txt` and `control-parley screenshot --path artifacts/people/list.png`. Both identify the People surface via `Search people`.

## Gotchas

- Voiceprints are biometric data. Export/import sheets write files the user did not ask this run to create. Skip them.
- Bulk-select / Delete removes Rolodex records. Never prove deletion against the user's directory.
- Search matching company/title is case-insensitive; assert the filtered names, not the query string alone.
