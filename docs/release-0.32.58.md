# BeLauncher 0.32.58

This release closes another concrete slice of the Inbox/imports/attachments recovery work from the
original Brain plan.

## What changed

- Imported evidence attachments are now staged by file copy instead of `Data(contentsOf:)`.
- The inbox Markdown envelope and its attachment still publish through the same durable manifest,
  but large PDFs/audio/files no longer have to be loaded fully into memory before publication.
- Recovery now has an explicit multi-file test: if the app exits after staging an inbox note and
  attachment but before publication finishes, reopening the Vault publishes both together and
  removes the staging folder.

## Verification

- `swift test --filter VaultTests`
- `swift test`

## Plan status

This does not claim the whole Inbox pipeline is finished. It proves one important invariant for
manual imports and attachments: the Brain should not expose an inbox item without its local evidence
copy, and large attachments should not punish the launcher path by being loaded into memory.
