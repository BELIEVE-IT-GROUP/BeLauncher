# BeLauncher 0.32.33

## Scope

This release closes N6, A6, A7 and A8 from `docs/plan-action-map-v2.md` and records the N7 release audit.

## N7: signed release boundary

N7 is complete for the current non-sandbox architecture boundary. The current architecture reads local Mail, Messages, Notes and
Safari stores by path after the user grants Full Disk Access. The repository has no
security-scoped bookmark flow and no privileged/helper process. App Sandbox is therefore not
compatible with the current source connectors: Full Disk Access is a TCC authorization and does
not remove the separate sandbox file/container restrictions. This release does not add
`com.apple.security.app-sandbox` and must not claim that it does.

The release script now verifies the signed artifact, not just source files:

- `com.apple.security.automation.apple-events` and audio input are present;
- `com.apple.security.app-sandbox` is absent, failing closed if it is signed in;
- the executable contains both `arm64` and `x86_64` slices;
- the bundle carries microphone, audio capture, calendar and Apple Events usage descriptions.

Enabling App Sandbox remains a separate architecture decision, not a hidden follow-up: migrate
protected-source access to security-scoped bookmarks or an approved helper, then re-evaluate
sandboxing and notarization. That migration is intentionally outside N7's current acceptance
because enabling it now would break the existing source connectors.

## N6: curated App Intents and deep links

BeLauncher now exposes a stable catalog of 16 curated App Intents through Shortcuts and Spotlight.
The IDs are owned by `BELAppIntentCatalog`, so display text can change without breaking saved
automation. The surface covers clipboard work, file review, email drafting, planning, meetings,
Brain save/recall and a generic command entry point.

Every curated intent is explicitly foreground today. That is intentional: the current app bridge
opens the command bar and lets the person review the command. It does not claim that a model action,
file rename or email write completed in the background. Catalog entries also carry `implemented` or
`reviewOnly` status so a future background adapter cannot silently promote an unimplemented seed.

Deep links use the registered `belauncher://intent/<actionID>?q=<query>` scheme. Unknown action IDs,
wrong schemes and empty generic commands are ignored. Valid links route into the existing command bar
through `AppDelegate`, keeping App Intents, Shortcuts and internal navigation on one entry path.

The previous notification-based intents remain source-compatible for existing app integrations;
the 16 discoverable shortcuts now use the curated contract.

## A6: bounded structured output

`BELStructuredOutputValidator` now treats model JSON as an untrusted input boundary, including local
providers. The default limits are:

- 128,000 UTF-8 bytes;
- 12 nesting levels;
- 64 object fields;
- 256 array items;
- 32,000 characters per string.

Callers can pass a stricter `BELStructuredOutputLimits` profile per tool. Oversized, deeply nested,
wide, long-string and malformed/truncated values fail closed with typed errors before writeback.
Unknown schema fields, wrong types, unknown tools and invalid tool arguments remain rejected.

Repair is bounded to one complete Markdown fence. Prose, an open fence, trailing output and a
truncated tool envelope are not guessed around. No prompt text is interpreted by the validator as
an instruction; it is validated only as the declared JSON field value and remains subject to the
same size limit.

## A7: local model discovery and routing

Local Ollama and LM Studio model discovery now trims and deduplicates names, rejects unhealthy
endpoints, and selects only an installed chat-capable model. A saved embedding model or stale model
name is not sent to chat. When a usable local model exists, it is the default route unless the user
explicitly selected a cloud provider; cloud remains an explicit fallback rather than a silent
startup choice.

## A8: confirmed writeback and forgetting

AI output enters the vault only as an extracted proposal. `confirm` is the sole path that promotes it
to committed memory; `discard` records the decision without creating an object. Evidence and project
updates remain ordinary Inbox/proposal flows, and each AI control-plane transition is appended to the
local audit JSONL without storing prompts or model output.

`forget` is two-step: preview reports the exact counts, then confirmation removes source rows,
passages and vectors, graph nodes/edges and action-log entries in the selected period. The contract
tests verify that a vectorized passage is no longer searchable after confirmation.

## Verification

- Curated catalog count, unique IDs, unknown-action rejection and deep-link round trip.
- Structured output: valid JSON, fences, schema mismatch, unknown fields, truncation, oversized
  input, depth, object, array and string limits.
- Local model routing: Ollama/LM Studio discovery, stale saved-model rejection, embedding-model
  rejection and offline endpoint handling.
- Writeback: proposal-only writes, explicit confirm/discard, project proposal, audited evidence,
  and two-step forgetting with index/vector deletion.
- Full Swift suite: run `swift test` from the repository root before packaging.

## Deliberate limits

The 16 App Intents are discoverable and routeable, but only entries marked `implemented` are backed
by an existing command path. `reviewOnly` entries open a review command and do not report completion.
True background execution remains a separate adapter task and is not implied by this release.
