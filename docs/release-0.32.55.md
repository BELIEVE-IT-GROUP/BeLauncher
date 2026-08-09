# BeLauncher 0.32.55

This release closes a false-positive risk in the deep local sources plan: WhatsApp is now probed
and reported honestly instead of being a vague future source.

## What changed

- Added a local WhatsApp source probe for native macOS containers and WhatsApp Web IndexedDB stores.
- Added an explicit `unsupported` source state. This is different from `planned`: it means WhatsApp
  was detected on disk, but no supported readable local message store was found.
- Source Center now shows WhatsApp as "Detected, not supported" when the app or web store is present
  without a verified chat database.
- `--diagnose-sources` now reports:
  - `whatsapp-state`
  - `whatsapp-native-containers`
  - `whatsapp-web-stores`
  - `whatsapp-supported-stores`
  - `whatsapp-error` when relevant

## Verification

- `swift test` passed with 1167 tests in 150 suites.
- `swift test --filter 'LocalSourceConnectorTests|LocalizationTests'` passed with 23 tests in 2 suites.
- `.build/debug/BeLauncher --diagnose-sources` on this Mac reported WhatsApp as
  `detected-unsupported`, with 4 native containers, 1 web store and 0 supported stores.
- `.build/debug/BeLauncher --diagnose-mcp` verified Claude Desktop, Claude Code, Cursor, Windsurf,
  VS Code and Codex as "really connected".
- `git diff --check` passed.

## Known boundary

This is not a WhatsApp chat parser. It is the gate that prevents the product from pretending
WhatsApp is connected before a real local message store is verified and parsed.
