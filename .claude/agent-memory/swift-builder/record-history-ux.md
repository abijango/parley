# Record / History UX (2026-09-02)

- `AppActivity` + `idleDrainRemaining` live on `RecordingController`; menu bar + Record badge read `appActivity.statusText`.
- Idle debounce: `armIdleDrain()` after stop/park; `canDrain` gates both `OfflineProcessingService` and `SummaryService`. Start cancels via `cancelIdleDrain()`.
- Queue protocol extended: `move`, `hold`, `releaseHold`, `isHeld`. Offline `JobUIState` adds `.paused` (live park) and `.held`. Manifest fields: `offlineHeld`, `summaryHeld`.
- `clearIsBusy` no longer includes `summaryService.runningID`. Public `clearForNextMeeting()` + Record footer "Ready for next" resets via `modeResetForNextMeeting`.
- Auto-summarize after offline always enqueues; `SpeakerGuessResolver` + `SummaryPromptBuilder` SPEAKER HINTS block.
- Repair summaries: `SummaryService.enqueueRepair` with `defaultSummaryRepairPrompt`; voiceprint `recordCorrection` on override.
