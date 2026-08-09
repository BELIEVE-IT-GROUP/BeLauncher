# BeLauncher 0.32.30

## Scope

This release closes two plan points with executable behavior and production checks:

- **N3:** first public native action batch.
- **A2:** machine capability detection used by model routing.

It also hardens the N4 Shortcut foundation without claiming that macOS can create arbitrary
Shortcuts through its public CLI.

## N3: first public native batch

The following stable IDs now have concrete handlers and are resolved by the central runtime:

- `files.choose` through `NSOpenPanel`;
- `files.extract_pdf_text` through PDFKit;
- `screen.read_context` and `screen.ocr` through the existing screen capture path;
- `calendar.upcoming` through EventKit.

`files.choose` returns selected paths as the action result and distinguishes user cancellation
with `FileActionError.selectionCancelled`. The panel is injected in tests, so CI never opens a
real window and production still uses the system panel.

Reminders, Contacts, and Photos entries remain explicitly `unavailable`. Their presence in the
catalogue is not treated as an entitlement or API guarantee.

## A2: capability snapshot

`MacCapabilitySnapshot` now preserves:

- architecture;
- exact physical memory bytes plus the existing GB profile;
- thermal state and VM memory pressure;
- low-power mode and optional battery state;
- optional network reachability;
- optional runtime availability of Apple Foundation Models.

Unknown battery, network, and Foundation Models states remain `nil`. The detector never turns a
failed probe into a positive capability. Model routing can therefore prefer a small local model
on 8 GB, memory pressure, thermal pressure, or low power without assuming that a provider is
healthy.

## N4 foundation hardening

Shortcut mappings now migrate the foreground requirement safely, validate stable IDs and reject
control characters. A single bridge owns `shortcuts list` and `shortcuts run`, captures bounded
stdout/stderr, preserves real exit codes, sanitizes control bytes, and distinguishes missing tool,
missing shortcut, failed process, and foreground-required states.

The macOS `shortcuts` CLI has no public create/import command, so this release does not pretend to
install arbitrary BEL shortcuts silently. N4's creation/distribution path remains pending; only
user-created mappings are executable.

## Verification

- Focused native/capability/shortcut tests: 25 tests in 3 suites passed.
- Full suite: 1065 tests in 145 suites passed.
- Localization scan passes for the new public action title.
- Release runner must still pass test, build, signing, notarization, GitHub Release, and R2 stages.
