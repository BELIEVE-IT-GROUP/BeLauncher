# BeLauncher 0.32.36

## Ola 2: fuentes locales accionables

This release turns the first Reminders, Contacts and Photos source slices into executable local
workflows.

### Reminders

- `/reminder <text>` creates a reminder in EventKit after explicit confirmation.
- A selected reminder exposes `Complete reminder`.
- Create and complete are `r2` BEL actions, so every execution route requires confirmation.
- The local snapshot and Brain projection refresh after the operation.

### Contacts

- A selected contact exposes full local details and copy of its email or phone.
- `/contact add <name>` creates a contact through `CNSaveRequest` after confirmation.
- The original contact identifier is retained for lookup and the snapshot refreshes after creation.

### Photos

- The local metadata snapshot includes images and videos, dates, dimensions, media type and favorite
  state without downloading originals.
- `/photos` and the public action support deterministic date, favorite and video criteria.
- Results retain the Photos local identifier and open Photos rather than pretending it is a Finder
  path.

## Verification

- Full Swift suite: **1113 tests in 149 suites passed**.
- Remaining work: reminder editing, contact editing/sharing, Photos albums/editing/OCR, and the
  final Brain source projection audit.
