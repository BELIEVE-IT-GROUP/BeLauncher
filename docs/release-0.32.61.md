# BeLauncher 0.32.61

This release closes a usability gap in the local sources part of the Brain plan.

## What changed

- `Sync all` in Sources now refreshes the visible status of each deep local source instead of
  leaving the person with only one global sentence.
- Browser history, AI conversations, Apple Mail, Messages and Apple Notes each show their own
  latest count or attention state after a full sync.
- A source that failed now gets a visible `Needs attention` state with a warning icon, while sources
  that succeeded stay normal.
- Sources paused by the person are left paused and are not overwritten by the result of a bulk sync.

## Verification

- `swift test --filter ProviderSettingsTests`
- `swift test`
- `git diff --check`

## Plan status

This does not claim all Sentient-style local sources are complete. It makes the existing source
center more honest and actionable: when a deep source fails or needs permission, the affected row
shows it directly instead of hiding behind an aggregate result.
