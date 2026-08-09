# BeLauncher 0.32.65

This release fixes the Brain window opening too small. The Brain is a workspace, not a compact
utility panel, and the navigation rail plus top controls need enough room to avoid overlapping.

## What changed

- The Brain now opens with an adaptive large workspace frame.
- On a normal Mac display it opens at `1360 × 852` points instead of the old `1120 × 720`.
- On smaller displays it caps itself to the visible screen instead of pushing the title bar or
  content off screen.
- The Brain has a real minimum size, so resizing cannot collapse the top controls into the content.
- Reopening an already-created Brain window grows it if it was previously left too small.

## Verification

- `swift test --filter 'BrainWindowSizingTests|GraphCorrectionsTests|LocalizationTests'`
- `swift test`
- `git diff --check`

## Plan status

This does not complete the full original plan. It fixes a concrete UX defect in the Brain surface:
the main Brain view should open large enough to be usable before deeper UI polish continues.
