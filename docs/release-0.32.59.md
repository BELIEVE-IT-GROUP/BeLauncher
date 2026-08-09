# BeLauncher 0.32.59

This release closes a concrete checkpoint/recovery slice from the local sources and corpus plan.

## What changed

- Completed corpus runs now remove the persisted `corpus_checkpoint` setting instead of leaving a
  completed checkpoint behind.
- `corpus_ingestion_progress` remains available for UI/history, but `corpus_checkpoint` now means
  exactly one thing: there is unfinished ingestion work that can be resumed.
- `Store` now has an explicit `removeSetting(_:)` API, replacing ad hoc SQL when a durable marker
  stops being true.

## Verification

- `swift test --filter 'CorpusRunnerTests|StoreTests'`
- `swift test`

## Plan status

This does not claim all local sources are complete. It proves one recovery invariant required by
the original plan: a clean successful corpus pass must not look like an interrupted pass on the next
launch or in Settings.
