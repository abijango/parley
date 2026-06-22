---
name: people-join-arch
description: Person struct + PeopleJoin enum: location, engine-label mapping, voiceprint test fixture pattern for People screen
metadata:
  type: project
---

## Files created for People screen v1

- `Parley/UI/PeopleJoin.swift` — `Person` (Identifiable, displayName as id), `PeopleJoin.build()` (pure static), `engineLabel(for:)` top-level func
- `Parley/UI/PeopleView.swift` — HSplitView master-detail; `@EnvironmentObject vault: VaultDirectory` + `@ObservedObject voiceprintStore = RecordingController.shared.voiceprints`; manual TextField search (not .searchable); `EngineBadgeRow` public subview
- `ParleyTests/PeopleJoinTests.swift` — 12 XCTests covering all join quadrants (no @MainActor)
- `ParleyTests/PeopleViewModelTests.swift` — 8 additional XCTests targeting PeopleJoin.build, @MainActor style matching VoiceprintStoreTests; adds case-insensitive alias edge case not in PeopleJoinTests

## Engine-label mapping
`wespeaker_v2` -> "FluidAudio", `pyannote_v3` -> "WhisperKit", unknown -> nil

## Voiceprint test fixture pattern
`Voiceprint` is a plain struct with all-public stored properties: construct directly (no VoiceprintStore needed for pure logic tests). Use `Date(timeIntervalSinceReferenceDate:)` for deterministic createdAt ordering.

## Join algorithm notes
- Pass 1: walk contacts, collect matched VP IDs into consumed Set<UUID>
- Pass 2: group unconsumed VPs by trimmed+lowercased name -> voiceprint-only Persons
- anchorID = first VP sorted by createdAt (deterministic)
- Search uses manual `TextField` + computed filter (NOT `.searchable` -- breaks in HSplitView context)

**Why:** `.searchable` only renders inside NavigationStack/NavigationSplitView; Parley's outer sidebar is a plain HStack so HSplitView is used inside each pane.
