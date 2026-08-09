# BeLauncher 0.32.29

## Scope

This release implements the next two execution layers from Action Map v2:

1. N1: one native handler resolver with the required adapter order and the central execution gate.
2. A1: a complete runtime-facing language-model provider contract with real availability checks.

## N1: native action resolution

`BELActionRuntime` now owns an explicit resolution order:

1. First-party public API
2. BeLauncher App Intent
3. Shortcut
4. URL scheme
5. First-party AppleScript
6. Allowlisted shell

Only adapters that have a concrete handler are returned. Declaring an adapter in a catalog entry
does not create an implementation. App Intents remain an exposure surface until a stable BEL ID
is wired to an execution handler. URL and AppleScript are intentionally not inferred or silently
introduced by this release.

Every implemented native catalog definition is now tested through `BELActionRuntime.handler(for:)`
and must resolve to a handler with the same stable ID. Unavailable seeds continue to fail at the
runtime gate before any handler can run.

## A1: provider contract

`BELLanguageModelProvider` now exposes:

- `placement`: `onDevice`, `local`, or `cloud`;
- `capabilities`: chat, embeddings, or transcription;
- `contextWindow`: optional, with `nil` meaning no verified limit is known;
- `isAvailable()`: an async runtime check that must fail closed.

HTTP providers perform the real provider discovery request using the same injected transport used
by generation. Local providers require a non-empty model list. Direct-key providers require the
key and a successful provider response. A configured key or an installed app alone is not reported
as available. The local facade preserves the stable `bebrain.local.core` identity.

Generation and streaming check task cancellation before and after the provider call, so closing a
Brain interaction does not leave a request looking successful after cancellation.

## Verification

- `BELSystemCommandHandlerTests`: explicit adapter order, every implemented native definition has
  a matching handler, capability and confirmation gates, and every unavailable seed is blocked.
- `BELLanguageModelProviderTests`: typed request/response adaptation, local-core identity, placement,
  fail-closed context metadata, real local discovery probe, Foundation Models runtime honesty, and
  cancellation before network transport.
- Full suite: 1058 tests in 144 suites passed.
- No provider, model, context window, URL, AppleScript path, or native action is reported as ready
  merely because it exists in a catalogue.

## Still pending

This release does not claim completion of N3's remaining public actions, N4 Shortcut generation,
N5 natural-language action parsing, N6 broader App Intent exposure, A2 capability scoring, A3
health-aware routing integration, A4 token-budget retrieval, A5 cloud boundary redaction, A6
structured output, A7 model installation, A8 writeback, or the independent LiteRT-LM spikes.
