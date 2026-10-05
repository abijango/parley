# History

History lists transcripts from the app-owned vault folder, lets the user filter by pipeline stage, search by title/attendees/filing, and open a note for review.

## Sub-features

- `history-open` shows the History list from the sidebar.
- `history-filter` switches **All**, **Processing**, **Needs you**, and **Done**.
- `history-search` filters the list from **Search meetings**.
- `history-empty` shows **No transcripts yet**, **Nothing here**, or **No results** when the list is empty.
- `history-select` opens a row's note in the detail pane when at least one transcript exists.

## How to get to it (user POV)

- Choose **History** in the main-window sidebar.
- Use the segmented filter above the list.
- Type in **Search meetings**.

## Driving it with control-parley

Preconditions:

- `control-parley doctor` reports `recording: idle`.
- The main window is frontmost.
- Do not rename, refile, delete, combine, or press Summarize. Those mutate the user's vault.

- **Ensure sidebar handles.** If a snapshot lacks `help="History"`, collapse the sidebar. Run `control-parley click --name "Split View Horizontally Left"`. Icon-rail buttons expose help `Record`, `History`, `People`, `Settings`. Expanded text labels are often missing from System Events.
- **Open History.** Choose **History**. Run `control-parley click --name "History" --role AXButton`. The History split appears with filter radios **All**, **Processing**, **Needs you**, **Done**.
- **Wait for list chrome.** Run `control-parley wait --contains "Needs you" --timeout 8`. Expect `Nothing selected` in the detail pane when no row is chosen. The search field is an unlabeled `AXTextField` above the radios (placeholder `Search meetings` is not in the AX tree).
- **Filter All.** Choose **All**. Run `control-parley click --name "All"`. The list shows rows, or the empty title **No transcripts yet**.
- **Filter Needs you.** Choose **Needs you**. Run `control-parley click --name "Needs you"`. Either rows remain or the empty detail **No needs you transcripts.** appears (the visible label may include a count, e.g. `Needs you (3)`).
- **Search miss.** Focus is not required if AX exposes the field; type only if you can fill without clobbering another field. Prefer proving the empty-search copy by snapshot after the field value changes. If you cannot set the field reliably, snapshot the idle History chrome and report `history-search` as unreachable rather than inventing a click path.
- **Select a row (optional).** If a transcript title is visible in the snapshot, click that title. The detail pane shows the note, not the empty state.
- **Restore.** Click **Needs you** if that was the prior filter (it is the default), then click **Record**.
- **Proof.** Run `control-parley snapshot --path artifacts/history/list.ax.txt` and `control-parley screenshot --path artifacts/history/list.png` after History is open. The snapshot shows the History filter radios and `Nothing selected` or a note preview. Record whether the list was empty or populated.

## Gotchas

- Default filter is **Needs you**, so a vault full of filed notes looks empty until you choose **All**.
- Filter labels gain counts (`Needs you (2)`). Match with `wait --contains "Needs you"` rather than an exact title.
- **Review**, **Summarize**, **Detect speakers**, delete, and combine are user mutations. Skip them unless the feature under test is that mutation and the item was created by this run.
- Snapshots skip `AXScrollArea` / `AXList`. History rows will not appear in the AX dump; prove chrome (filters, detail empty state) instead of enumerating meetings.
- Search-in-contents is a toggle whose help is `Also search inside transcript text (slower)`.
- Window screenshots need Screen Recording for Cursor. `could not create image from rect` means that grant is missing, not that History failed.
