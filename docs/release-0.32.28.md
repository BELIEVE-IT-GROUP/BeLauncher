# BeLauncher 0.32.28

## What shipped

This release closes the action-inventory gap identified in the Action Map v2 audit.

- The catalogue now contains the complete native inventory from the specification: 156 stable definitions.
- The catalogue now contains the complete AI inventory from the specification: 120 stable definitions.
- Every definition has a typed contract: stable ID, aliases, arguments, output schema, risk, and availability.
- Definitions without a real adapter are explicit `unavailable` seeds. They are visible to tooling and future UI work, but they are not presented as executable actions.
- The app runtime now has a regression test that executes every unavailable seed and verifies the central `.unavailable` gate blocks it.

This is inventory coverage, not a claim that 276 adapters already exist. Existing implemented actions keep their concrete handlers; seed entries use `adapter: none` and cannot bypass the runtime gate.

## Verification

- `BELActionCatalogTests`: full inventory, unique IDs, Codable round trip, validation, and legacy AI ID bridging.
- `BELSystemCommandHandlerTests`: concrete adapters, capability gates, confirmation gates, and all unavailable-seed execution gates.
- `LocalizationTests`: stable action IDs are treated as contract data, not visible UI copy.
- Full suite: 1053 tests in 144 suites passed.

The full-suite search benchmark has an explicit scheduler-contention allowance; isolated focused runs remain the strict performance signal.

## Still intentionally pending

The audit items that require new engines or external integrations remain separate work: full native adapter implementation, full AI verb execution, LiteRT-LM/Gemma runtime work, prefix/KV caching, MTP, Metal fused attention, and provider-specific connectors such as Zoom, Meet, and Teams.
