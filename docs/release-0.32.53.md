# BeLauncher 0.32.53

This release closes the Wave 2 / Wave 3 execution program recorded under `.foreman/`.

## What changed

- Launcher UX: clipboard cards now keep the full Quick Preview open reliably, including after selection changes.
- Launcher UX: the footer has full, compact and minimal layouts so quick actions do not overflow when the selected item adds actions.
- Brain UX: notes, Inbox, Markdown reader/editing, graph inspection and Brain questions are covered as a single human workflow instead of separate disconnected surfaces.
- Native macOS actions: Contacts sharing, Shortcuts, App Intents and release permission gates have focused verification.
- AI routing: local providers fail closed unless a real discovered model is available; protected work does not silently fall back to cloud.
- AI safety: structured output, writeback, cloud-boundary redaction and multiline secret handling are verified.
- Apple Silicon spikes: LiteRT-LM X1/X2, prefix/KV cache, adaptive MTP scheduler and the X5 Metal blocker are documented as gated decisions, with no production LiteRT/Metal provider exposed.

## Verification

- `swift test` passed with 1157 tests in 150 suites.
- `git diff --check` passed.
- Foreman program `P-20260809-wave2` is terminal: 17/17 original items verified, 0 remaining.

## Known boundary

This release is code/test complete. The notarized DMG still needs the normal MacBook visual pass after the self-hosted runner publishes it.
