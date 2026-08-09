# BeLauncher 0.32.34

## Scope

This increment adds two public native actions to the shared BEL catalogue and runtime:

- `system.open_app`: opens an application by bundle identifier or existing absolute path;
- `system.open_system_setting`: opens a constrained set of System Settings panes.

Both actions use AppKit directly, pass through the existing capability/risk/confirmation executor,
and reject empty, oversized or malformed input. System Settings accepts only known pane identifiers;
it never turns a user string into an arbitrary URL.

## Verification

- Stable catalogue IDs are unique and marked `implemented` only with a concrete handler.
- Runtime lookup resolves both public actions through the `.publicAPI` adapter.
- Tests inject the AppKit open operation, so CI does not launch an app or System Settings.
- Invalid settings URLs are rejected before any open call.
- Full Swift suite: **1098 tests in 148 suites passed**.

The remaining Reminders, Contacts and Photos seeds stay `unavailable` until their permission and
SDK contracts have dedicated handlers and integration tests.
