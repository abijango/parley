# Swift Builder Agent Memory

- [Parley architecture overview](parley-arch.md) — key file locations, session lifecycle, concurrency patterns
- [Edit tool curly-quote hazard](edit-curly-quote-hazard.md) — Edit tool injects U+201C/U+201D into string literals; use Python for exact replacements when fixing
- [RecordingController finalize race fix](recording-controller-finalize-race.md) — finalize() durability race fix implemented 2026-06-10
- [Rolodex schema + parser details](rolodex-schema.md) — Contact/Side shape, parser state machine, near-dup fix, normalize name collision, real-file preview stats
- [PeopleJoin architecture](people-join-arch.md) — Person struct + PeopleJoin enum location, engine-label map, voiceprint test fixture pattern
- [strippedTitle test setup](feedback-stripped-title-test-setup.md) — bare-company test must use named company section, not ## Other (which sets company=nil)
- [MergeService patterns](merge-service-patterns.md) — API symbols, file-ordering pitfalls, C2 manifest must be .finalized, Task.detached for concat, OfflineJob flags
