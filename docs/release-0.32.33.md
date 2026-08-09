# BeLauncher 0.32.33

## Scope

This release closes N6 and A6 from `docs/plan-action-map-v2.md` and records the N7 release audit.

## N7 audit: signed release boundary

N7 is **partial by design**. The current architecture reads local Mail, Messages, Notes and
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

The remaining N7 work is a separate architecture decision: migrate protected-source access to
security-scoped bookmarks or an approved helper, then re-evaluate sandboxing and notarization.

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

## Verification

- Curated catalog count, unique IDs, unknown-action rejection and deep-link round trip.
- Structured output: valid JSON, fences, schema mismatch, unknown fields, truncation, oversized
  input, depth, object, array and string limits.
- Full Swift suite: run `swift test` from the repository root before packaging.

## Deliberate limits

The 16 App Intents are discoverable and routeable, but only entries marked `implemented` are backed
by an existing command path. `reviewOnly` entries open a review command and do not report completion.
True background execution remains a separate adapter task and is not implied by this release.
