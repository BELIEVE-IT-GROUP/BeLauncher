# BeLauncher 0.32.63

This release closes a concrete launcher usability gap: quick notes can now be created from what
the person types, without relying on the last clipboard item and without being treated like a
generic answer.

## What changed

- The launcher recognises more natural note phrases:
  - `nota ...`
  - `crear nota ...`
  - `nueva nota ...`
  - `nota rapida ...`
  - `quick note ...`
  - `new note ...`
  - `write note ...`
  - `note to self ...`
- Pressing Return on one of those results writes a Markdown quick note straight to the Brain Inbox.
- `/nota texto` now saves the note directly. `/nota` still opens the multiline Markdown editor.
- The action panel for a typed note now shows note-specific actions:
  - Return saves the note.
  - A secondary action opens the Markdown note editor with the typed text.
- Slash-note arguments now preserve the user's original casing and accents.

## Why it matters

The launcher was too dependent on clipboard context. This gives it a direct human path:

1. Open launcher.
2. Type `crear nota llamar a Ana sobre contrato`.
3. Press Return.
4. The note lands in the Brain Inbox as Markdown.

That is a note, not a committed memory proposal. The memory path remains explicit through
`recordar ...`, where the person still confirms what becomes true in the Brain.

## Test verification

- `swift test --filter 'QuickNoteTests|BrainInLauncherTests|ActionPanelTests|LocalizationTests'`
- `swift test`
- `git diff --check`

## Plan status

This does not complete the full original plan. It closes one bounded piece of item 9:
launcher natural language actions must be useful from typed intent, not only from clipboard input.
