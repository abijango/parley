# Parley verification map

This directory is the maintained source for verifying the user-facing behavior of Parley. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- `/Applications/Parley.app` is installed (Release via `tools/localrelease.sh`, done outside this run).
- Accessibility is granted to the process that runs `control-parley` (Cursor and/or Terminal).
- `PARLEY_VERIFY_STATE` is set (default `/tmp/parley-verify-state`).
- `control-parley doctor` reports `recording: idle` and at least one AX window.
- Never drive an instance that is recording. Never start a second Parley.
- Treat the running app as a shared singleton: Application Support, UserDefaults, and the vault are the user's real data unless a feature's preconditions say a verification vault is selected.

## Driving conventions

- Start every recipe from the Record tab of the main window unless preconditions say otherwise.
- Prefer AX title / description / placeholder over coordinates.
- Treat every command as literal. Keep quoted names and flags unchanged.
- Run UI actions through `.cursor/skills/verify-parley/bin/control-parley`.
- Restore navigation (Record tab, close Settings) after a mutation-free recipe. Do not remove proof artifacts during cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof includes an AX snapshot and a screenshot with Parley visible.
- Mutation proof (recording, vault writes) includes a second read of the files on disk.
- Record the feature ID and entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with control-parley` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Record tab](./record-tab.md) covers the live Record surface: transport, capture mode, title field. Starting a recording is gated.
- [History](./history.md) covers browsing, filtering, and searching past transcripts.
- [People](./people.md) covers the People directory and search.
- [Settings](./settings.md) covers opening Settings and switching the seven sidebar sections.
