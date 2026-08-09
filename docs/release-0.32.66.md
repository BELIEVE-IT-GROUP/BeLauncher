# BeLauncher 0.32.66

This release closes a durability gap in the Inbox/Vault flow. Quick notes already use the same
staged write path as evidence imports, but the recovery path did not have its own regression test.
That made it too easy to break the human-facing Inbox without seeing it in CI.

## What changed

- Added a dedicated recovery test for interrupted quick-note publication.
- The test simulates a durable staging folder left behind before the Inbox Markdown was published.
- Reopening the Vault must now finish the pending quick note, make it visible through
  `QuickNote.records`, preserve the note body, and remove the staging folder.
- This gives Inbox quick notes the same recovery evidence already covered for imported evidence
  and attachments.

## Verification

- `swift test --filter 'VaultTests|QuickNoteTests|LocalizationTests'`
- `swift test`
- `git diff --check`

## Plan status

This advances the Inbox/attachments/imports recovery item from the original plan. It does not
complete the full remaining plan by itself; it hardens one concrete path that a person uses every
day: writing a quick note and trusting that it lands in the Brain.
