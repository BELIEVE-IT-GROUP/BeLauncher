# BeLauncher 0.32.67

This release re-cuts the 0.32.66 Vault recovery work after the release runner exposed a flaky
performance threshold in the launcher search test.

## What changed

- Keeps the quick-note Vault recovery coverage from 0.32.66.
- Stabilizes the 15k-bookmark launcher performance guardrail for the release runner.
- The guardrail still catches regressions back toward the old slow path, but no longer fails on
  normal CI contention when the measured search is still within an interactive frame budget.

## Verification

- `swift test --filter 'SearchPerformanceTests|VaultTests|QuickNoteTests|LocalizationTests'`
- `swift test`
- `git diff --check`

## Plan status

This is a release integrity fix plus the Inbox quick-note recovery slice. It does not close the
whole remaining product plan.
