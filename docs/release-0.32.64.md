# BeLauncher 0.32.64

This release advances the Daily Brain slice from the original Brain plan. The overview still keeps
the three plain questions, but now answers them with more context instead of showing one isolated
item.

## What changed

- `What changed` now distinguishes today from older activity:
  - Counts Brain files created today.
  - Counts work threads active today.
  - If nothing changed today, it says that and points to the last known Brain file instead.
- `What matters` now explains the attention queue:
  - One Pulse item is shown as one thing needing attention.
  - Multiple Pulse items are counted and the top one is named.
  - If Pulse is empty, today's most active thread becomes the focus fallback.
- `What you can do now` is more actionable:
  - Pending voice transcriptions are counted and prioritised.
  - Inbox review items are counted and the first item is named.
  - If there is no Inbox but Pulse has attention, the card starts a Brain question for the next action.
- The old `3 meses` literal in the graph range selector is now localized as `90 days`.

## Verification

- `swift test --filter 'GraphCorrectionsTests|LocalizationTests'`
- `swift test`
- `git diff --check`

## Plan status

This does not complete the full original plan. It closes another bounded part of item 5:
Daily Brain should feel like a daily copilot, not a decorative graph summary.
