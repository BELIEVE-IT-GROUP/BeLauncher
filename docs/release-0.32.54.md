# BeLauncher 0.32.54

This release closes another concrete slice of the original Brain/Launcher plan: the local Brain now
turns more real Mac evidence into daily corpus material, manual imports are recoverable, and the
launcher has an explicit natural-language door into BeBrain.

## What changed

- Brain corpus: Mail, Messages and Apple Notes now enter the episode signal stream, not only the
  semantic search rows. That means they can shape the daily graph/corpus instead of being invisible
  to "what changed today".
- Corpus files: the corpus runner now publishes derived episode, entity and distilled-statement
  Markdown through the recoverable `CorpusFolder` staging contract.
- Imports and attachments: importing a readable file into the Brain now saves the inbox Markdown
  evidence and a local copy of the explicit attachment together through the Vault staging manifest.
  The original path is still preserved as provenance; the Brain does not crawl or duplicate the Mac.
- Inbox model: imported evidence records now carry both source provenance and the local attachment
  path, so UI surfaces can recover the file even when the original import source later disappears.
- Launcher language: explicit queries like `ask brain where did I see Acme?` and `pregúntale al
  cerebro qué hice con Acme` route straight to the live Brain question surface instead of opening
  the graph or depending on the last clipboard item.
- Hot path: the launcher input-needs gate now loads memories/traits for explicit Brain questions,
  while ordinary searches still avoid waking local sources or the vault.

## Verification

- `swift test` passed with 1163 tests in 150 suites.
- `swift test --filter 'VaultTests|QuickNoteTests|CorpusTests|CorpusRunnerTests|BrainQueryTests|LauncherInputNeedsTests|MCPToolsTests|MCPServerTests|MCPHealthTests|LocalSourceConnectorTests|BrowserHistoryTests'` passed with 208 tests in 18 suites.
- `swift test --filter LocalizationTests` passed.
- `git diff --check` passed.
- `.build/debug/BeLauncher --diagnose-sources` returned:
  - `full-disk-access=true`
  - `browsers-count=272`
  - `messages-count=1`
  - `conversations-files=2571`

## Known boundary

This release does not claim WhatsApp chat ingestion as complete. The current Mac exposes WhatsApp
containers, but no supported readable local chat database was verified. Mail, Messages, Notes,
browsers and conversation files have test and diagnostic coverage; WhatsApp remains an explicit
follow-up until there is a proven parser over a real local store.
