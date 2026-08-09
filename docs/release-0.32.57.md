# BeLauncher 0.32.57

This release closes a concrete Launcher natural-language slice from the original Brain/Launcher plan.

## What changed

- The launcher now understands explicit human phrases for searching the local Brain, not just the older `ask brain ...` command shape.
- Supported examples include:
  - `search my brain for Atlas pricing`
  - `find in my memory Acme`
  - `búscame en mi memoria la llamada de Atlas`
  - `qué sé de Acme`
- These phrases route to the live Brain question surface through the existing `brain-question` action, so pressing Return opens the real Brain conversation path.
- The empty/`brain` launchpad now starts “Ask your brain” with `search my brain for ` instead of duplicating the decision-specific prompt.
- The hot path stays protected: ordinary searches like `safari` still do not load the vault, and clipboard mode still does not wake Brain, graph, packs or process surfaces.
- Spanish localization covers the new visible completion phrase.

## Verification

- `swift test --filter 'BrainQueryTests|LauncherInputNeedsTests|LocalizationTests'`
- `swift test`

## Plan status

This does not claim all Launcher natural language is finished. It proves the next useful loop:
type a natural request to search your own memory, see an actionable Brain result, and press Return
without depending on the latest clipboard item or remembering a slash command.
