# BeLauncher 0.32.60

This release closes another concrete recovery slice from the local corpus plan.

## What changed

- The nightly Brain distillation no longer marks a day as `distilled_day` before the model has
  actually produced cited statements.
- If the selected model fails during distillation, the day stays due and
  `distillation_last_problem` records the real failure so a later healthy run can recover it.
- Quiet days with too little material are still marked complete, because retrying an empty day
  forever adds no value.
- Successful distillation now clears the last problem only after cited statements have been written
  to the Markdown corpus and indexed for retrieval.

## Verification

- `swift test --filter CorpusRunnerTests`
- `swift test`
- `git diff --check`

## Plan status

This does not claim the full original plan is complete. It removes a false-positive condition in
the Smart Wave 2 corpus pipeline: failed nightly learning must stay visible and retryable instead
of disappearing behind a completed marker.
